import Foundation

/// The log, and it is a product surface rather than a debug artefact: every
/// failure state offers "Show log", so a person filing an
/// issue reads this.
///
/// Two of Oilbird's failures are uninterpretable without it — a quarantined
/// binary is `SIGKILL`/137 with no message, and `pg_ctl` prints only "could
/// not start server" while the real cause sits in a file it never shows.
///
/// Under `cache`, because a log is rederivable: clearing caches costs
/// diagnostics, never history.
public enum Log {
    /// Rotated so a crash-looping supervisor cannot fill the disk it is
    /// reporting on.
    static let rotateAtBytes: Int64 = 5 * 1024 * 1024
    static let generationsKept = 2

    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO "
        case warn = "WARN "
        case error = "ERROR"
    }

    public static func debug(_ message: String) { write(.debug, message) }
    public static func info(_ message: String) { write(.info, message) }
    public static func warn(_ message: String) { write(.warn, message) }
    public static func error(_ message: String) { write(.error, message) }

    /// A named provisioning step, so a log reads as a sequence rather than a
    /// stream.
    public static func phase(_ name: String) { write(.info, "── \(name)") }

    /// Every child launch, with its **resolved absolute path** and argv,
    /// written before it runs.
    ///
    /// This single line is what makes a bare-name launch or a wrong-runtime
    /// failure diagnosable at all, and it is the first thing to read in any
    /// provisioning bug. It is safe to log verbatim only because the analysis
    /// token travels by environment and never by argv — that ordering is what makes redaction
    /// structural rather than a filter.
    public static func subprocess(_ executable: URL, argv: [String]) {
        write(.info, "exec \(executable.path) \(argv.joined(separator: " "))")
    }

    /// Blocks until everything queued has been written.
    ///
    /// Writes are queued so that logging never stalls a caller, which is right
    /// until the caller is about to `exit`. A process that logs why it failed
    /// and then exits loses exactly that line — the queue is drained by a
    /// thread that no longer exists. The whole failure path was invisible in
    /// the file this log exists to fill, and the symptom is worse than a
    /// missing line: the log ends mid-sequence, which reads like a hang.
    ///
    /// The queue is serial, so this waits for everything ahead of it too.
    public static func flush() { queue.sync {} }

    // MARK: -

    private static let queue = DispatchQueue(label: "io.birdtable.oilbird.log")

    private static func write(_ level: Level, _ message: String) {
        let line = "\(stamp()) \(level.rawValue) \(message)\n"
        queue.async {
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            let url = Paths.Cache.log
            try? FileManager.default.createDirectory(
                at: Paths.Cache.logs, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func rotateIfNeeded() {
        let url = Paths.Cache.log
        let manager = FileManager.default
        guard
            let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int64,
            size >= rotateAtBytes
        else { return }
        for generation in stride(from: generationsKept, through: 1, by: -1) {
            let older = url.appendingPathExtension("\(generation)")
            let newer =
                generation == 1 ? url : url.appendingPathExtension("\(generation - 1)")
            try? manager.removeItem(at: older)
            try? manager.moveItem(at: newer, to: older)
        }
    }

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
