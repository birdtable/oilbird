import Foundation
import OilbirdModel

/// Exactly one process owns the cluster.
///
/// Three clients over one core makes concurrent the DEFAULT, not an edge case
/// — a GUI open, an agent on the MCP server and a terminal scan is ordinary
/// use. Two processes running `initdb` on one data directory is silent
/// corruption that exits 0.
///
/// Two mechanisms, not one. A lock file alone fails *within* a process: a
/// second attempt finds a lock naming its own live PID, concludes it is the
/// holder, and proceeds.
public enum Owner {
    /// The in-process half.
    nonisolated(unsafe) private static var heldInProcess = false
    private static let gate = NSLock()

    public struct Holder: Sendable, Codable {
        public let pid: Int32
        public let host: String
        public let started: Date
        public let argv: String
    }

    /// Is some live process in the middle of starting or stopping the
    /// engine right now?
    ///
    /// ⚠ A restart deletes `running.json` before writing a new one, so for
    /// fifteen seconds another client's `status` answered "not running"
    /// about an engine that was on its way up. No new state is needed to
    /// say so: whoever holds this lock is by definition mid-transition, and
    /// the lock is released the moment they finish.
    public static func transitionInProgress() -> Bool {
        guard let holder = readHolder(Paths.State.clusterLock.path) else { return false }
        return holder.pid > 0 && kill(holder.pid, 0) == 0
    }

    /// Runs `body` with no other process running it for the same name.
    ///
    /// ⚠ Two scans of the same project used to fail — **both of them**.
    /// SonarQube refuses a concurrent analysis of one project, so the two
    /// scanners collided and each came back "The scan did not finish", with
    /// nothing saying they had raced. An agent scanning while a watcher
    /// scans, or a pre-commit hook firing twice, lost both results.
    ///
    /// Queued rather than refused: the second caller wanted a scan, and
    /// waiting a few seconds gives it one. Refusing would be honest but
    /// would push the retry loop into every caller.
    ///
    /// `flock` rather than a pidfile, for the reason `Idle` gives: the
    /// kernel releases it when the holder dies, including on `SIGKILL`, so
    /// a crashed scan cannot wedge every later one.
    public static func serialised<T: Sendable>(
        named name: String, timeout: TimeInterval = 900, _ body: () async throws -> T
    ) async throws -> T {
        try FileManager.default.createDirectory(
            at: Paths.State.run, withIntermediateDirectories: true)
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let path = Paths.State.run.appending(path: "lock-\(String(safe))").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return try await body() }
        defer { close(descriptor) }

        let deadline = Date().addingTimeInterval(timeout)
        var waited = false
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                throw OilbirdError(
                    .clusterHeldByAnother, "Another scan of this project is still running.",
                    recovery: .retry("Try again"),
                    underlying: "waited \(Int(timeout))s for lock-\(String(safe))")
            }
            if !waited {
                Log.info("another scan of \(name) is running; waiting for it")
                waited = true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }

    /// Takes the lock, or throws naming who holds it.
    public static func acquire() throws {
        gate.lock()
        defer { gate.unlock() }
        guard !heldInProcess else {
            throw OilbirdError(
                .clusterHeldByAnother,
                "Oilbird is already working on the database in this window.",
                recovery: .waitForHolder(pid: currentPID, since: Date()),
                underlying: "in-process owner already held")
        }

        try FileManager.default.createDirectory(
            at: Paths.State.run, withIntermediateDirectories: true)
        let path = Paths.State.clusterLock.path

        // O_CREAT|O_EXCL is atomic. Testing for absence and then creating is a
        // race with a window wide enough to lose, and losing it is corruption
        // rather than an error.
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if descriptor < 0 {
            if let stale = try reclaimIfStale(path) {
                throw stale
            }
            let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else {
                throw OilbirdError(
                    .clusterHeldByAnother,
                    "Another copy of Oilbird is using the database.",
                    recovery: .waitForHolder(pid: readHolder(path)?.pid ?? 0, since: Date()),
                    underlying: "lock held at \(path)")
            }
            try writeHolder(to: descriptor)
        } else {
            try writeHolder(to: descriptor)
        }
        heldInProcess = true
    }

    public static func release() {
        gate.lock()
        defer { gate.unlock() }
        guard heldInProcess else { return }
        try? FileManager.default.removeItem(at: Paths.State.clusterLock)
        heldInProcess = false
    }

    public static func readHolder(_ path: String) -> Holder? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? decoder.decode(Holder.self, from: data)
    }

    /// ISO-8601 rather than the default float. The lock file is a diagnostic
    /// surface — someone asking "who is holding this?" reads it with `cat`,
    /// and `"started":752198400.5` answers nothing.
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

    /// A lock left by a dead process is reclaimed; one held by a live process
    /// never is. The PID alone is not enough — PIDs are recycled, so a live
    /// unrelated process must not look like the holder.
    private static func reclaimIfStale(_ path: String) throws -> OilbirdError? {
        guard let holder = readHolder(path) else {
            // Unreadable lock: refuse rather than guess. Deleting a lock we
            // cannot read is how two processes end up in one cluster.
            return OilbirdError(
                .clusterCorrupt,
                "Oilbird could not tell whether the database is in use.",
                recovery: .reportIssue("Report an issue"),
                underlying: "unreadable lock at \(path)")
        }
        if kill(holder.pid, 0) == 0 {
            return OilbirdError(
                .clusterHeldByAnother,
                "Another copy of Oilbird is using the database.",
                recovery: .waitForHolder(pid: holder.pid, since: holder.started),
                underlying: "live holder pid \(holder.pid) on \(holder.host)")
        }
        Log.warn("reclaiming a lock left by dead pid \(holder.pid)")
        try? FileManager.default.removeItem(atPath: path)
        return nil
    }

    private static func writeHolder(to descriptor: Int32) throws {
        defer { close(descriptor) }
        let holder = Holder(
            pid: currentPID,
            host: machineName(),
            started: Date(),
            argv: ProcessInfo.processInfo.arguments.joined(separator: " "))
        let data = try encoder.encode(holder)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    private static var currentPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// This machine's name, asked of the kernel rather than of the network.
    ///
    /// ⚠ This was `ProcessInfo.processInfo.hostName`, and on Darwin that is
    /// not a `gethostname` wrapper — it resolves the name through
    /// CFHost/Bonjour, issuing about twenty multicast DNS-SD queries. macOS
    /// classifies that as local-network access, so a clean Mac met "Allow
    /// 'Oilbird' to find devices on local networks?" during first run, in
    /// Apple's most alarming wording, for a machine name that never leaves
    /// the disk.
    ///
    /// The prompt was not the expensive part. `hostName` BLOCKS until the
    /// user answers it: measured at 35.01 seconds of stalled main thread
    /// against an unanswered prompt: the main thread blocked on network I/O,
    /// reached from a diagnostic string in a lock file.
    ///
    /// `gethostname(2)` returns the same value, does not touch the network,
    /// and raises nothing. Verified both ways on a clean macOS 26 VM: the
    /// prompt disappears entirely and the value is unchanged.
    static func machineName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "unknown-host" }
        // Truncated at the terminator ourselves: `gethostname` does not
        // promise one if the name fills the buffer, and decoding the whole
        // array would append 256 bytes of NUL to the name in the lock file.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
