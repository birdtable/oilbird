import Foundation
import OilbirdCore
import OilbirdModel

/// Sending a scan off, and coming back to it.
///
/// ⚠ **The half that did not exist.** You could start a scan and watch it, or
/// start one and lose it: `scan` ran in the foreground and died with the
/// terminal it was started from. Now there are both: keep reading and
/// waiting, or send the job off with a handle to check later — and start
/// watching again at any point.
///
/// The handle is the project key and the log is a file — between them,
/// every one of those is the same operation on `Paths.State.scans` from a
/// different process.
extension Oilbird {
    /// Every scan this machine has run, most recent first, running ones
    /// first of all.
    ///
    /// Answers from disk and starts nothing. "Did that finish?" is the
    /// question asked most often here, and making it cost a fifteen-second,
    /// 1.6 GB engine start is the idle cost Oilbird exists to refuse.
    public static func scans() -> [Scans.Entry] { Scans.all() }

    public static func scan(named key: String) -> Scans.Entry? { Scans.entry(key) }

    /// Starts a scan in the background and returns as soon as it has really
    /// started.
    ///
    /// ⚠ The child holds the idle attachment itself, and nothing here is
    /// what does that. It is another process running the same
    /// `Oilbird.scan` path, which takes an `Idle.Attachment` for the
    /// duration — so the watchdog cannot stop the engine underneath it. That
    /// is the whole reason this is a re-exec of the CLI rather than a
    /// detached `Task`: a `Task` dies with the process that made it, and
    /// this must outlive the terminal.
    public static func detach(path: URL) async throws -> Scans.Entry {
        guard let binary = cliBinary() else {
            throw Error(
                .verifyFailed,
                "Oilbird cannot find its own command line tool, so it cannot run a scan in "
                    + "the background.",
                recovery: .reportIssue("Report an issue"),
                underlying: "no cliBinary() beside \(Bundle.main.executableURL?.path ?? "?")")
        }
        let key = Project.key(for: path)
        // Refused, not queued: both record under one key and the second
        // truncates the log the first is streaming into. The answer to "scan
        // this" is the scan already running.
        if let existing = Scans.entry(key), existing.state == .running {
            throw Error(
                .clusterHeldByAnother, "\(key) is already being scanned.",
                recovery: .chooseAlternative("Follow it"),
                underlying: "pid \(existing.pid), started \(existing.started)")
        }
        guard let child = Scans.childLogPath(for: key) else {
            throw Error(
                .verifyFailed, "Oilbird cannot record a scan of that folder.",
                recovery: .chooseAlternative("Scan it in the foreground"),
                underlying: "no usable scans directory for key '\(key)'")
        }
        let output = URL(filePath: child)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        // `--json` deliberately: the child's stdout is not the log a person
        // follows, which `Oilbird.scan` writes. `child.log` holds the receipt,
        // or why a process died before reaching our code.
        let pid = try Child.detach(
            binary, ["scan", path.path, "--json"], environment: ownEnvironment(), output: output)

        // Waited for, not assumed: printing a handle for a process that exited
        // on launch hands someone a key `follow` refuses. The child records
        // itself before starting the engine, so this is milliseconds.
        for _ in 0..<100 {
            if let entry = Scans.entry(key), entry.pid == pid { return entry }
            if kill(pid, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw Error(
            .verifyFailed, "The scan did not start.",
            recovery: .retry("Show log"),
            underlying: "pid \(pid) recorded nothing. \(child): "
                + ((try? String(contentsOf: output, encoding: .utf8))?.suffix(2000).description
                    ?? "empty"))
    }

    /// Attaches to a scan from the beginning of its log.
    ///
    /// Re-attachable any number of times and by any number of readers at
    /// once — the log is a file, so every follower reads it for itself and
    /// none of them consumes it. On a scan that has already finished it
    /// prints the run and returns, rather than waiting for a process that
    /// is not there.
    public static func follow(
        key: String, onLine: @Sendable (String) -> Void
    ) async throws -> Scans.Entry {
        try await Scans.follow(key: key, onLine: onLine)
    }

    /// A scan's output as it stands right now, without waiting for it.
    ///
    /// ⚠ **`follow` BLOCKS until the scan ends, and that is right for a
    /// terminal and wrong for a tool call.** Built on it, `oilbird_follow`
    /// waited out the whole scan and then reported `running` — the state
    /// having been read before the wait — which is the opposite of both
    /// things it was added to do. A question asked repeatedly has to return
    /// repeatedly.
    ///
    /// Re-readable any number of times by any number of callers: the log is
    /// a file and nothing here consumes it.
    public static func scanOutput(key: String) -> [String] {
        guard let path = scanLogPath(for: key),
            let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return Array(
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .drop { $0.isEmpty }
                .reversed().drop { $0.isEmpty }.reversed())
    }

    /// Ends a running scan.
    ///
    /// Whatever it had already uploaded stays: the compute engine has it and
    /// SonarQube has processed it. That is worth saying out loud, because
    /// the alternative assumption — "stopping it undid it" — is what stops
    /// people from stopping a scan they no longer need.
    @discardableResult
    public static func stopScan(key: String) throws -> (entry: Scans.Entry, ended: Bool) {
        try Scans.stop(key)
    }

    /// Where a scan's log is kept, so a client can say where to look.
    public static func scanLogPath(for key: String) -> String? { Scans.logPath(for: key) }

    // MARK: - Saying how long

    /// ISO-8601, because a timestamp in a machine surface is read by
    /// something that has to parse it. `"started":752198400.5` is a number
    /// whose epoch the reader has to guess.
    public static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// "18s", "1m 12s", "2h 5m" — two units, never three.
    ///
    /// Elapsed time is read at a glance to answer "is this stuck?", and
    /// `1h 4m 13s` makes that question harder rather than easier.
    public static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// "just now", "12m ago", "7h ago", "3d ago".
    ///
    /// - Parameter now: injected, so a test of the boundaries is not a race
    ///   with the clock.
    public static func humanAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

/// One scan, as something that is not a person reads it.
///
/// ⚠ Assembled once, here, rather than in each client. A machine surface
/// carries `state`, `started`, `pid` and `key` — four keys that
/// were otherwise going to be written out four times in the CLI alone
/// (`scans`, `follow`, `--detach`, `--stop`), which is four chances for one
/// of them to drift and for a CI step polling it to read `null` on a
/// Tuesday.
extension Scans.Entry {
    public var fields: [String: Any] {
        var row: [String: Any] = [
            "key": key,
            "state": state.rawValue,
            "started": Oilbird.stamp(started),
            "pid": Int(pid),
            "path": path,
            "verdict": verdict,
            "elapsed": Int(elapsed.rounded()),
            "detached": detached,
        ]
        if let phase { row["phase"] = phase.rawValue }
        if let finished { row["finished"] = Oilbird.stamp(finished) }
        switch outcome {
        case .completed(let done):
            row["files"] = done.files
            row["lines"] = done.lines
            row["degraded"] = done.degraded
            row["gate"] = done.gate ?? NSNull()
            row["judgedNothing"] = done.judgedNothing
        case .readNothing:
            row["files"] = 0
            row["lines"] = 0
            row["readNothing"] = true
        case .failed(let why):
            row["error"] = why
        case .stopped, nil:
            break
        }
        return row
    }
}
