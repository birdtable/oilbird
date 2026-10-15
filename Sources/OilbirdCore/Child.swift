import Foundation
import OilbirdModel

/// The only place a child process is constructed.
///
/// No other domain may build one. Without that rule you get orphaned
/// postmasters, no single kill-on-quit, and — worse — a bare-name launch that
/// works in a terminal and fails from Finder.
///
/// Blocking work stays on GCD deliberately: `Process` + `waitUntilExit()`
/// blocks its thread, and the cooperative pool has roughly one thread per core
/// and must never be blocked on work that is not already running. The
/// `withCheckedContinuation` bridge below is the supported way across.
public enum Child {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        /// The signal that killed the child, or `nil` for an ordinary exit.
        ///
        /// Carried because `status` cannot express one. A shell reports a
        /// killed child as 128 plus the signal; `Process.terminationStatus`
        /// reports the signal itself, so 9 and "exited 9" are the same value
        /// and a caller cannot tell them apart from the number alone.
        public let signal: Int32?

        /// Killed by `SIGKILL`. A fact, not a diagnosis.
        ///
        /// What it MEANS belongs to the caller: on a binary Oilbird
        /// downloaded and has not yet run, it is Gatekeeper and nothing else,
        /// and the kill is silent — so "exited 9" is every word the user
        /// would otherwise get.
        ///
        /// ⚠ This used to be written `status == 137` at the one call site
        /// that names a quarantine kill. 137 is a shell's spelling — 128 plus
        /// the signal — and `terminationStatus` never returns it. The branch
        /// could not be reached, so the failure `Install.stripQuarantine`
        /// documents costing a silent install arrived as `postgres exited 9`.
        public var killedBySIGKILL: Bool { signal == SIGKILL }
    }

    private static let queue = DispatchQueue(
        label: "io.birdtable.oilbird.child", qos: .userInitiated, attributes: .concurrent)

    /// Runs an executable to completion.
    ///
    /// - Parameter onLine: called with each line of stdout AS IT ARRIVES.
    ///
    /// ⚠ **Live, not buffered.** Reading with `readDataToEndOfFile()` returns
    /// only when the child exits, so replaying the buffer through `onLine`
    /// afterwards prints nothing and then everything at once — measured on a
    /// ONE-FILE project: silence for 11.4 seconds, then 125 lines in the same
    /// millisecond. On a real repository that is minutes of a cursor sitting
    /// still, and in the window a progress line that stays empty for the
    /// whole analysis and then flashes the entire scanner log past.
    public static func run(
        _ executable: URL, _ argv: [String],
        environment: [String: String] = Resolver.childEnvironment(),
        currentDirectory: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(
                        returning: try runBlocking(
                            executable, argv, environment, currentDirectory, onLine))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Spawns and returns immediately, for a service Oilbird supervises.
    ///
    /// ⚠ The child is NOT put in its own process group: Foundation's `Process`
    /// does not expose that, and it would need `posix_spawn` directly. So
    /// signalling the group is not available, and `Supervise` must
    /// record the descendant PIDs instead — which it has to do anyway, because
    /// SonarQube's Elasticsearch is a GRANDCHILD and walking direct children
    /// misses it.
    public static func spawn(
        _ executable: URL, _ argv: [String],
        environment: [String: String] = Resolver.childEnvironment()
    ) throws -> Process {
        let process = try configured(executable, argv, environment, nil)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Run a program that owns the terminal, and wait for it.
    ///
    /// ⚠ Nothing is piped. Every other child here has its streams captured
    /// because Oilbird reads what they say; this one is a program the READER
    /// is talking to — an editor — and capturing its output would leave them
    /// typing into something they cannot see.
    ///
    /// ⚠ And it gets the user's OWN environment, not `Resolver
    /// .childEnvironment`. That environment exists to stop Oilbird reaching
    /// for a runtime it did not install; an editor is not a runtime
    /// Oilbird depends on, it is the program this person has chosen, and
    /// handing it a stripped `PATH` and no `TERM` is how it comes up unable
    /// to find its own plugins or draw its own screen.
    @discardableResult
    public static func inheritingTerminal(_ executable: URL, _ argv: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = argv
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Spawns something meant to outlive this process, with its output in a
    /// file.
    ///
    /// ⚠ **`spawn` is not this, and reusing it would break a detached scan
    /// two ways.** It sends stdout and stderr to `/dev/null`, which is right
    /// for a service whose log is its own and wrong for a scan somebody
    /// means to read later; and Foundation's `Process` cannot put a child in
    /// its own session, which is what a scan needs to survive the terminal
    /// it was started from — closing that terminal sends `SIGHUP` to every
    /// process group in its session, and the scan would die with the window.
    ///
    /// So `posix_spawn` directly: `POSIX_SPAWN_SETSID` makes the child a
    /// session leader with no controlling terminal, and the file actions put
    /// both its streams in one file. Being a session leader also makes it a
    /// process-group leader, which is what lets `Scans.stop` signal the
    /// group and reach the scanner's JVM rather than only the process that
    /// launched it.
    ///
    /// - Returns: the child's pid, which is also its process group.
    public static func detach(
        _ executable: URL, _ argv: [String],
        environment: [String: String] = Resolver.childEnvironment(),
        output: URL
    ) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OilbirdError(
                .verifyFailed, "A program Oilbird needs is missing.",
                recovery: .reportIssue("Report an issue"),
                underlying: "not executable: \(executable.path)")
        }
        Log.subprocess(executable, argv: argv)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // A child that asks a question waits forever for an answer nobody
        // can type — and this one has no terminal to type into at all.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &actions, 1, output.path, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        // stderr onto the same file rather than a second `addopen`: two
        // descriptors on one file have two offsets, and one stream in order is
        // what the reader is owed.
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        // `strdup` copies, so the Swift strings need not outlive this call —
        // and the copies must be freed, including the `nil` terminator each
        // vector needs, which `free` accepts and ignores.
        let arguments = [executable.path] + argv
        let pairs = environment.map { "\($0.key)=\($0.value)" }
        let argvC: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envC: [UnsafeMutablePointer<CChar>?] = pairs.map { strdup($0) } + [nil]
        defer { for pointer in argvC + envC { free(pointer) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argvC, envC)
        guard status == 0, pid > 0 else {
            throw OilbirdError(
                .verifyFailed, "Oilbird could not start that in the background.",
                recovery: .retry("Try again"),
                underlying: "posix_spawn \(executable.path) returned \(status)")
        }
        return pid
    }

    // MARK: -

    private static func configured(
        _ executable: URL, _ argv: [String], _ environment: [String: String],
        _ currentDirectory: URL?
    ) throws -> Process {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OilbirdError(
                .verifyFailed,
                "A program Oilbird needs is missing.",
                recovery: .reportIssue("Report an issue"),
                underlying: "not executable: \(executable.path)")
        }
        // Logged BEFORE it runs, with the resolved absolute path: the first
        // line to read in any provisioning bug, safe verbatim only because the
        // token travels by environment and never by argv.
        Log.subprocess(executable, argv: argv)

        let process = Process()
        process.executableURL = executable
        process.arguments = argv
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        // A child that asks a question waits forever for an answer nobody can
        // type, with no window to type it into.
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private static func runBlocking(
        _ executable: URL, _ argv: [String], _ environment: [String: String],
        _ currentDirectory: URL?, _ onLine: (@Sendable (String) -> Void)? = nil
    ) throws -> Result {
        let process = try configured(executable, argv, environment, currentDirectory)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // ⚠ Both pipes drained CONCURRENTLY: reading one to the end then the
        // other deadlocks once the unread pipe fills its 64 KB buffer, one
        // noisy stderr away from a silent hang.
        let collected = Drain(), collectedErr = Drain()
        let group = DispatchGroup()
        queue.async(group: group) {
            collected.consume(out.fileHandleForReading, emitting: onLine)
        }
        queue.async(group: group) {
            collectedErr.consume(err.fileHandleForReading, emitting: nil)
        }
        group.wait()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: collected.text(), stderr: collectedErr.text(),
            signal: process.terminationReason == .uncaughtSignal
                ? process.terminationStatus : nil)
    }

    /// Reads a pipe to the end, handing over whole lines as they arrive.
    ///
    /// A class with a lock rather than a local, because two of these run on
    /// the concurrent queue at once and `Result` still wants the whole text
    /// at the end — so the bytes have to outlive the closure that read them.
    private final class Drain: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func consume(_ handle: FileHandle, emitting onLine: (@Sendable (String) -> Void)?) {
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                data.append(chunk)
                lock.unlock()
                guard let onLine else { continue }
                pending.append(chunk)
                // Only whole lines. A chunk boundary lands mid-line more
                // often than not, and half a line delivered as a line is a
                // progress display that stutters.
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending = pending[pending.index(after: newline)...]
                    onLine(String(decoding: line, as: UTF8.self))
                }
            }
            if let onLine, !pending.isEmpty {
                // ⚠ The last line has no newline after it, and dropping it
                // is how `Log` lost its final entry once already.
                onLine(String(decoding: pending, as: UTF8.self))
            }
        }

        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
