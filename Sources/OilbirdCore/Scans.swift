import Foundation
import OilbirdModel

/// What is running, what has run, and the log that lets you come back to it.
///
/// ⚠ **The log is a file, not a pipe, and that is the whole of what makes
/// coming back work.** A pipe has one reader and no beginning: arriving late
/// would show whatever happens to be passing, arriving twice would split the
/// stream between two readers, and arriving after the end would have nothing
/// to attach to at all. All three are what a detached scan is for, and none
/// of them is a property of the following code — they are properties of the
/// file.
///
/// One directory per PROJECT KEY rather than per run. The key is
/// computable from the path before the scanner starts, it is the string every
/// other verb already takes, and `Owner.serialised` already refuses two scans
/// of one project — so it cannot collide with itself. The previous run of a
/// project is replaced by its next one, which is also the question people
/// actually ask: "how did storefront get on?", never "how did run 41 get on?".
public enum Scans {
    // MARK: - What is written down

    /// Everything a later process needs to judge a pid it did not start.
    public struct Record: Sendable, Codable, Equatable {
        public let key: String
        public let path: String
        public let pid: Int32
        /// The process group the scan runs in.
        ///
        /// Recorded because stopping a scan has to reach the scanner's JVM
        /// and not only the `oilbird` that launched it. Whether it is safe
        /// to signal is `stop`'s question, and `stop` answers it from this.
        public let group: Int32
        public let started: Date
        /// When this machine last booted, as the recording process saw it.
        ///
        /// ⚠ The pid-identity rule, applied to scans as well: a
        /// pid recorded before the last restart names somebody else's
        /// process now. Without this a scan the machine was rebooted out
        /// from under reads as *still running*, for ever, and `--stop` sends
        /// SIGTERM to a stranger.
        public let booted: Date?
        /// The executable the pid was running when the record was written.
        ///
        /// The boot check narrows pid recycling to one uptime; this closes
        /// it. ⚠ `Paths.isInsideContainer` is the sibling check in
        /// `reapOrphans` and is the WRONG tool here: the pid is `oilbird`
        /// itself, which lives on the PATH (by opt-in) or in the app bundle and
        /// never under the container — so that test would refuse to believe
        /// in any scan at all. Verified: `Supervise.Kernel.executablePath` of
        /// a running detached scan is the CLI in `.build`, and
        /// `isInsideContainer` says false.
        public let executable: String?
        /// Started by `scan --detach`, and therefore in a session of its own
        /// with no terminal to lose.
        public let detached: Bool
        public var finished: Date?
        public var outcome: Outcome?

        /// Public so the suite can write one.
        ///
        /// The interesting states of this type are ones no test can reach by
        /// running a scan: a record from before the last boot, a pid that
        /// belongs to somebody else now. A record a suite cannot construct is
        /// a safety rule that can only be checked by rebooting the machine.
        public init(
            key: String, path: String, pid: Int32, group: Int32, started: Date, booted: Date?,
            executable: String?, detached: Bool, finished: Date? = nil, outcome: Outcome? = nil
        ) {
            self.key = key
            self.path = path
            self.pid = pid
            self.group = group
            self.started = started
            self.booted = booted
            self.executable = executable
            self.detached = detached
            self.finished = finished
            self.outcome = outcome
        }
    }

    /// How a scan ended.
    public enum Outcome: Sendable, Codable, Equatable {
        case completed(Finished)
        /// The scanner ran and read no source. Never an error, never a pass.
        case readNothing
        case failed(String)
        case stopped
    }

    public struct Finished: Sendable, Codable, Equatable {
        public let files: Int
        public let lines: Int
        public let degraded: Bool
        /// SonarQube's own verdict, as it stood when the scan ended.
        ///
        /// ⚠ Recorded at the end of the scan rather than asked when the list
        /// is drawn, and that is not an optimisation. `scans` answers "did
        /// that finish?" — the most commonly asked question here —
        /// and answering it must not start 1.6 GB of engine, which is
        /// exactly the idle cost Oilbird refuses. The engine is up and the
        /// analysis is processed at the moment the scan ends; it is the one
        /// cheap time to ask.
        public let gate: String?
        /// The gate evaluated no conditions. Not a pass, and must never be
        /// rendered as one — a first analysis has no baseline to judge.
        public let judgedNothing: Bool

        public init(files: Int, lines: Int, degraded: Bool, gate: String?, judgedNothing: Bool) {
            self.files = files
            self.lines = lines
            self.degraded = degraded
            self.gate = gate
            self.judgedNothing = judgedNothing
        }
    }

    // MARK: - What is read back

    public enum State: String, Sendable, Equatable {
        case running
        case finished
        /// Recorded as running, and the process is gone. A reboot, a
        /// `kill -9`, a crash. Never resumed and never reaped — the pid is
        /// somebody else's now.
        case interrupted
    }

    /// How far along a running scan is.
    ///
    /// Derived from whether the log has anything in it rather than written
    /// down, so it costs no extra write per line and cannot go stale. The
    /// engine start is most of the wait on a cold machine, and it happens
    /// before the scanner says a word.
    public enum Phase: String, Sendable, Equatable {
        case starting
        case analysing

        public var label: String { rawValue }
    }

    /// One row of `oilbird scans`, and everything `follow` needs to close on.
    public struct Entry: Sendable, Equatable {
        public let record: Record
        public let state: State
        /// Only while it is running.
        public let phase: Phase?
        /// How long it ran, or has been running.
        public let elapsed: TimeInterval

        public var key: String { record.key }
        public var path: String { record.path }
        public var pid: Int32 { record.pid }
        public var started: Date { record.started }
        public var finished: Date? { record.finished }
        public var outcome: Outcome? { record.outcome }
        public var detached: Bool { record.detached }

        /// One word for what happened, in the vocabulary the design settled
        /// on: `OK`, `FAILED`, `read nothing`.
        ///
        /// A gate that failed and a scan that did not finish are different
        /// things and are said differently — both would otherwise read
        /// `FAILED`, and only one of them has a codebase to fix.
        public var verdict: String {
            switch state {
            case .running: phase?.label ?? "running"
            case .interrupted: "interrupted"
            case .finished:
                switch outcome {
                case .completed(let done):
                    if done.judgedNothing {
                        "not judged"
                    } else if done.gate == "ERROR" {
                        "FAILED"
                    } else {
                        done.gate ?? "scanned"
                    }
                case .readNothing: "read nothing"
                case .failed: "did not finish"
                case .stopped: "stopped"
                case nil: "finished"
                }
            }
        }

        /// What the analysis read — or, when it did not get that far, why.
        ///
        /// One column rather than two: a table with a `read` column and a
        /// `reason` column has one of them empty on every row, and the
        /// question behind both is the same one — what came of this?
        public var read: String {
            switch outcome {
            case .completed(let done):
                "\(counted(done.files, "file")), \(counted(done.lines, "line"))"
            case .readNothing: "0 files"
            case .failed(let why): why
            case .stopped, nil: "—"
            }
        }

        /// True when the analysis ran without coverage.
        public var degraded: Bool {
            if case .completed(let done) = outcome { return done.degraded }
            return false
        }

        private func counted(_ n: Int, _ singular: String) -> String {
            "\(n) \(singular)\(n == 1 ? "" : "s")"
        }
    }

    // MARK: - Writing

    /// Opens a scan's record and its log, replacing whatever the previous run
    /// of this project left there.
    ///
    /// Returns the sink the caller streams into, or `nil` when this run must
    /// not be recorded — which is not a failure of the scan. Bookkeeping that
    /// cannot be written is a diagnostic loss; a scan that refused to run
    /// because of it would be a product loss.
    public static func begin(key: String, path: URL, detached: Bool? = nil) -> Sink? {
        guard let directory = directory(for: key) else {
            Log.warn("not recording a scan under an unusable key '\(key)'")
            return nil
        }
        // ⚠ A live scan is NOT overwritten: `Owner.serialised` queues a second
        // scan rather than refusing it, so the queued one reaches this line
        // while the first is still writing and truncates its log.
        if let existing = read(key), state(of: existing) == .running, existing.pid != getpid() {
            Log.warn("\(key) is already being scanned by pid \(existing.pid); not recording this one")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pid = getpid()
            let record = Record(
                key: key, path: path.path, pid: pid, group: getpgrp(), started: Date(),
                booted: Supervise.Kernel.bootTime(),
                executable: Supervise.Kernel.executablePath(of: pid),
                // A process that leads its own session was started by
                // something that meant it to outlive a terminal, and
                // `Child.detach` is the only thing here that does that.
                detached: detached ?? (getsid(0) == pid),
                finished: nil, outcome: nil)
            try write(record)
            return Sink(logging: directory.appending(path: logName))
        } catch {
            Log.warn("could not record the scan of \(key): \(error)")
            return nil
        }
    }

    /// Records how a scan ended.
    ///
    /// Ignores a record this process does not own: a second scan of one
    /// project that was refused a sink above must not close the record the
    /// first one is still using.
    public static func finish(key: String, outcome: Outcome, by pid: Int32 = getpid()) {
        guard var record = read(key), record.pid == pid, record.finished == nil else { return }
        record.finished = Date()
        record.outcome = outcome
        try? write(record)
    }

    /// Where a scan's log lives, so a caller can hand the path to a person.
    public static func logPath(for key: String) -> String? {
        directory(for: key)?.appending(path: logName).path
    }

    /// Writes a record as another process would have left it.
    ///
    /// Public only for the suite, exactly as `Supervise.recordForTesting`
    /// is: the interesting states here are ones no test can reach by running
    /// a scan — a record from before the last boot, a pid that belongs to
    /// somebody else now — and a safety rule that can only be checked by
    /// rebooting the machine is a rule nobody checks.
    public static func recordForTesting(_ record: Record) throws { try write(record) }

    /// Where a detached child's own stdout and stderr land.
    ///
    /// ⚠ Not `/dev/null`, which is what `Child.spawn` gives a service and is
    /// why that primitive cannot be reused here. Separate from the log the
    /// scan streams into, because the two have different authors: the log is
    /// written by whoever is running the scan, in any client, and this is
    /// written by the kernel on behalf of a process that may die before it
    /// reaches any of our code. When a detached scan vanishes without a
    /// verdict, this file is the only thing that can say why.
    public static func childLogPath(for key: String) -> String? {
        directory(for: key)?.appending(path: "child.log").path
    }

    /// Drops everything recorded for a project.
    public static func forget(key: String) {
        guard let directory = directory(for: key) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// An open, append-only handle on one scan's log.
    ///
    /// A class with a lock because lines arrive on `Child`'s drain thread
    /// while the scan is awaited elsewhere, and because the descriptor has to
    /// outlive the closure that writes to it. Unbuffered: a follower in
    /// another process reads this file as it grows, and a buffer would make
    /// "live" mean "whenever 4 KB accumulates".
    public final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32

        init?(logging file: URL) {
            let fd = open(file.path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return nil }
            descriptor = fd
        }

        public func write(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { return }
            let bytes = Data((line + "\n").utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        }

        public func close() {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }

        deinit { close() }
    }

    // MARK: - Reading

    public static func read(_ key: String) -> Record? {
        guard let directory = directory(for: key),
            let data = FileManager.default.contents(atPath: directory.appending(path: recordName).path),
            let record = try? decoder.decode(Record.self, from: data)
        else { return nil }
        // The directory name is the key reduced to what a filename may hold, so
        // two keys could share one. The record carries the real key, and a
        // mismatch means this is not the scan asked for.
        return record.key == key ? record : nil
    }

    public static func entry(_ key: String) -> Entry? {
        read(key).map(entry(for:))
    }

    /// Every scan on this machine: running first, then most recent.
    public static func all() -> [Entry] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: Paths.State.scans.path)) ?? []
        let entries = names.compactMap { name -> Entry? in
            guard
                let data = manager.contents(
                    atPath: Paths.State.scans.appending(path: name).appending(path: recordName).path),
                let record = try? decoder.decode(Record.self, from: data)
            else { return nil }
            return entry(for: record)
        }
        return entries.sorted { left, right in
            if (left.state == .running) != (right.state == .running) { return left.state == .running }
            return left.started > right.started
        }
    }

    public static func entry(for record: Record) -> Entry {
        let state = state(of: record)
        let ended = record.finished ?? Date()
        return Entry(
            record: record, state: state,
            phase: state == .running ? phase(of: record) : nil,
            elapsed: max(0, ended.timeIntervalSince(record.started)))
    }

    /// Running, finished, or interrupted — asked of the kernel, not of the
    /// record alone.
    public static func state(of record: Record) -> State {
        guard record.finished == nil else { return .finished }
        return isAlive(record) ? .running : .interrupted
    }

    /// Is the process this record names still the process it named?
    ///
    /// Three questions, all of which have to be yes. `kill(pid, 0)` alone
    /// answers only the weakest of them — that *a* process has that number.
    static func isAlive(_ record: Record) -> Bool {
        if let boot = Supervise.Kernel.bootTime() {
            if let booted = record.booted {
                // A second of slack: `KERN_BOOTTIME` is adjusted by a few
                // microseconds as the clock settles, so an exact comparison
                // would report every scan on the machine as interrupted.
                guard abs(booted.timeIntervalSince(boot)) < 1 else { return false }
            } else if record.started < boot {
                return false
            }
        }
        guard record.pid > 0, kill(record.pid, 0) == 0 else { return false }
        guard let executable = record.executable else { return true }
        return Supervise.Kernel.executablePath(of: record.pid) == executable
    }

    static func phase(of record: Record) -> Phase {
        guard let path = logPath(for: record.key),
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber,
            size.intValue > 0
        else { return .starting }
        return .analysing
    }

    // MARK: - Following

    /// Replays a scan's log from the beginning, and keeps reading until it
    /// ends.
    ///
    /// Re-attachable any number of times and by any number of readers at
    /// once, because every follower opens the file for itself and nothing
    /// here consumes anything. Returns the scan as it finally stood, so the
    /// caller can print a verdict rather than guessing one.
    public static func follow(
        key: String, poll: Duration = .milliseconds(150),
        onLine: @Sendable (String) -> Void
    ) async throws -> Entry {
        guard var record = read(key) else { throw noSuchScan(key) }
        let handle = logPath(for: key).flatMap { FileHandle(forReadingAtPath: $0) }
        defer { try? handle?.close() }
        var pending = Data()

        while true {
            // ⚠ Sampled BEFORE the drain, acted on after. The other way round,
            // a scan finishing between the two ends the loop with its last
            // bytes still in the file.
            let stillRunning = state(of: record) == .running
            while let chunk = try? handle?.read(upToCount: 64 * 1024), !chunk.isEmpty {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending = pending[pending.index(after: newline)...]
                }
            }
            if !stillRunning { break }
            try? await Task.sleep(for: poll)
            if Task.isCancelled { break }
            record = read(key) ?? record
        }
        // The last line of a killed scan has no newline after it, and
        // dropping it is how `Log` lost its final entry once already.
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        return entry(for: read(key) ?? record)
    }

    // MARK: - Stopping

    /// Ends a running scan.
    ///
    /// - Returns: the scan as it now stands, and whether this call is what
    ///   ended it. Both, because "it had already finished" is an answer and
    ///   not an error.
    public static func stop(_ key: String) throws -> (entry: Entry, ended: Bool) {
        guard let record = read(key) else { throw noSuchScan(key) }
        guard state(of: record) == .running else { return (entry(for: record), false) }

        // ⚠ The GROUP, and only when the scan LEADS it. Signalling the group
        // reaches the scanner's JVM, which would otherwise carry on analysing
        // after the scan was stopped.

        // But a foreground scan shares its group with whatever the shell put
        // there, so `kill(-pgid)` would signal the user's other jobs. A scan
        // leading its own group holds nothing that is not this scan.
        if record.group > 0 && record.group == record.pid {
            kill(-record.group, SIGTERM)
        } else {
            kill(record.pid, SIGTERM)
        }
        Log.info("stopped the scan of \(key) (pid \(record.pid))")
        finish(key: key, outcome: .stopped, by: record.pid)
        return (entry(for: read(key) ?? record), true)
    }

    public static func noSuchScan(_ key: String) -> OilbirdError {
        OilbirdError(
            .verifyFailed, "There is no scan called '\(key)'.",
            recovery: .chooseAlternative("List scans"),
            underlying: "no record under \(Paths.State.scans.path)")
    }

    // MARK: -

    static let recordName = "record.json"
    static let logName = "log"

    /// The directory this key's scan is kept in, or `nil` if the key is not
    /// one we will touch.
    ///
    /// ⚠ `follow` and `--stop` take their key from whoever typed it, so this
    /// is the boundary where a key becomes a path. A key is reduced to the
    /// characters `Project.key` can produce; anything else is replaced, and a
    /// key that is empty or all separators is refused outright rather than
    /// resolving to the scans directory itself. `oilbird follow ../../..` has
    /// to be a sentence, not a delete.
    static func directory(for key: String) -> URL? {
        let safe = String(
            key.map { character in
                guard character.isASCII else { return "-" as Character }
                return character.isLetter || character.isNumber || character == "-"
                    || character == "_" || character == "." ? character : "-"
            })
        guard !safe.isEmpty, safe.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return Paths.State.scans.appending(path: safe)
    }

    static func write(_ record: Record) throws {
        guard let directory = directory(for: record.key) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: directory.appending(path: recordName), options: .atomic)
    }

    /// ISO-8601 rather than the default float, for the reason `Owner` gives:
    /// this file is a diagnostic surface, and `"started":752198400.5`
    /// answers nothing to someone reading it with `cat`.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
