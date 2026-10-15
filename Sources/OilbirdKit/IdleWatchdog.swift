import Foundation
import OilbirdCore
import OilbirdModel

/// The idle watchdog: when the engine stops itself, and what holds it open.
///
/// ⚠ An extension in its own file, not a separate type. `Oilbird` is
/// the one barrel a client imports and that is deliberate; what was not
/// deliberate is all of it living in one 1,877-line file. Splitting the
/// FILE changes nothing a caller can see.
extension Oilbird {
    /// The `oilbird` binary — the CLI, wherever this process is running from.
    ///
    /// ⚠ **Not `CommandLine.arguments[0]`, and this trap has now caught the
    /// codebase three times.** From the GUI that argument is
    /// `Oilbird.app/Contents/MacOS/Oilbird`: re-execing it as a watchdog
    /// starts a second copy of the application, windows and all, and
    /// symlinking it onto the PATH makes `oilbird status` open a window.
    /// `Bundled.swift` records the same shape for resources and
    /// `Oilbird.build` for the `Info.plist`; this is the third reading of
    /// one fact, so it is written once and called from all of them.
    ///
    /// Resolved from the RUNNING EXECUTABLE, symlinks first: `cli-install`
    /// puts a symlink on the PATH, and unresolved it makes the executable
    /// look like it lives in `/usr/local/bin`, two directories from
    /// anything Oilbird shipped.
    public static func cliBinary() -> URL? {
        let manager = FileManager.default
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let directory = executable.deletingLastPathComponent()
        let candidates = [
            // Contents/MacOS/Oilbird and Contents/Helpers/oilbird are both
            // one level under Contents, so both reach the same helper —
            // and the path is `CommandLineTool`'s to name, not ours.
            directory
                .deletingLastPathComponent()  // Contents
                .deletingLastPathComponent()  // Oilbird.app
                .appending(path: CommandLineTool.bundleRelativePath),
            // `swift run`, and the test runner: no bundle, and the CLI is
            // the sibling of whatever is running.
            directory.appending(path: cliExecutableName),
        ]
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

    /// Last component of `Contents/Helpers/oilbird` — the CLI's own name,
    /// taken from the one place that names it.
    static var cliExecutableName: String {
        URL(filePath: CommandLineTool.bundleRelativePath).lastPathComponent
    }

    /// The environment for a re-exec of Oilbird's own CLI.
    ///
    /// ⚠ `Resolver.childEnvironment` CONSTRUCTS rather than inherits, which
    /// is the right default and loses the one variable that must survive the
    /// trip. `OILBIRD_HOME` names the container this process is using, and a
    /// child that does not get it reads and writes the real one — so a
    /// watchdog spawned from the clean-machine gate or from a suite
    /// supervised the developer's own engine, and a detached scan would have
    /// scanned into their installation while believing it was sandboxed.
    /// `Paths` already warns that relocating `HOME` does not achieve this;
    /// this is the other half of the same fact.
    static func ownEnvironment(adding extras: [String: String] = [:]) -> [String: String] {
        var extras = extras
        let environment = ProcessInfo.processInfo.environment
        if let container = environment[Paths.containerRootVariable], !container.isEmpty {
            extras[Paths.containerRootVariable] = container
        }
        return Resolver.childEnvironment(adding: extras)
    }

    static var watchdogLock: URL { Paths.State.run.appending(path: "watchdog.lock") }

    /// Starts a watchdog for the engine, unless one is already running.
    ///
    /// Called from every path that touches the engine rather than only from
    /// `up`. Without launchd there is no supervisor for the supervisor, so a
    /// watchdog that dies can only be replaced by the next thing the user
    /// does — which makes adoption the recovery, and a failure with no
    /// recovery is a dead end. It also adopts an engine started before this code shipped.
    public static func ensureWatching() {
        guard status() != nil else { return }
        guard Preferences.load().idleTimeout.seconds != nil else {
            // "Never" needs no watchdog at all — the cheapest possible
            // implementation of the user's explicit choice to keep the
            // engine warm.
            return
        }
        // A cheap, racy pre-check. The real exclusion is the lock the
        // watchdog itself takes; this only avoids spawning a process that
        // would immediately exit.
        if let existing = try? String(contentsOf: watchdogLock, encoding: .utf8),
            let pid = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
            kill(pid, 0) == 0
        {
            return
        }
        guard let binary = cliBinary() else {
            Log.warn("no oilbird binary to run the idle watchdog; the engine will not stop")
            return
        }
        do {
            _ = try Child.spawn(binary, ["watch"], environment: ownEnvironment())
            Log.info("idle watchdog started")
        } catch {
            Log.warn("could not start the idle watchdog: \(error)")
        }
    }

    /// The watchdog's own body. Runs until the engine stops.
    public static func runWatchdog() async {
        let descriptor = open(
            watchdogLock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            Log.debug("another watchdog holds the lock; exiting")
            return
        }
        defer { close(descriptor) }
        ftruncate(descriptor, 0)
        _ = Data("\(getpid())\n".utf8).withUnsafeBytes {
            write(descriptor, $0.baseAddress, $0.count)
        }

        // Test hooks, and ONLY inside a sandboxed container: a stray
        // environment variable must never be able to shorten a real user's
        // timeout, and `OILBIRD_HOME` is what the suites already set.
        let sandboxed = ProcessInfo.processInfo.environment[Paths.containerRootVariable] != nil
        let limit: Duration? =
            sandboxed
            ? ProcessInfo.processInfo.environment["OILBIRD_IDLE_SECONDS"]
                .flatMap(Int.init).map { .seconds($0) }
                ?? Preferences.load().idleTimeout.seconds.map { .seconds($0) }
            : Preferences.load().idleTimeout.seconds.map { .seconds($0) }
        let poll: Duration =
            sandboxed
            ? ProcessInfo.processInfo.environment["OILBIRD_POLL_MS"]
                .flatMap(Int.init).map { .milliseconds($0) } ?? .seconds(30)
            : .seconds(30)

        await Idle.watch(
            limit: limit, poll: poll,
            engineRunning: { status() != nil },
            // ⚠ `force`, and not a shortcut: `stopIfUnattached` already holds
            // the attachment lock, and `flock` conflicts within a process, so
            // an un-forced `down` sees its own lock and refuses.
            stop: { _ = await down(force: true) })
    }

    /// Stops the engine.
    ///
    /// - Parameter force: stop even while clients are using it. The user
    ///   asking directly may; a client repairing what it believes is a dead
    ///   engine may not.
    ///
    /// ⚠ This ignored attachments entirely, so any client that
    /// decided the engine was unhealthy could stop it out from under a
    /// running scan. The lock that answers "is anything using this" already
    /// existed — it was built against the idle watchdog and never consulted
    /// here. Same question, different asker.
    @discardableResult
    public static func down(force: Bool = false) async -> Bool {
        if !force, Idle.attached() {
            Log.warn("refusing to stop the engine: something is using it")
            return false
        }
        await Supervise.stop()
        try? await Cluster.stop()
        try? FileManager.default.removeItem(at: runningFile)
        // No `Owner.release()`. Releasing is in-process by design, and the
        // process that started the services has almost always exited — so
        // this was a no-op that read like cleanup and hid `up`'s leak.
        return true
    }

    /// The engine's state as a person or an agent should hear it.
    ///
    /// "Paused" and "stopped" are the same on disk and are not the same to
    /// read. The engine stopping because nobody used it for half an hour is
    /// the product working; a `Never scanned` machine has simply not started
    /// yet. Saying "stopped" for both makes a normal state look like a fault,
    /// which is what the paused overlay exists to prevent.
    public enum EngineState: Sendable, Equatable {
        case running(Running)
        /// Installed and previously used, currently not running.
        case paused
        /// Nothing installed yet — the first-run path, not a stop.
        case notInstalled
        /// Somebody is starting or restarting it right now.
        ///
        /// A restart removes the record before writing the new one, so
        /// without this a client asking during that window is told the
        /// engine is not running when it is fifteen seconds from being up.
        case starting
        /// Recorded as running and not answering — a crash, a `kill -9`, a
        /// machine that slept badly. Named, because "running" and "paused"
        /// are both lies here and the recovery is different from either.
        case unresponsive(Running)

        public var isRunning: Bool { if case .running = self { return true }; return false }
    }

    /// Is anything, anywhere, using the engine?
    ///
    /// Cross-process, because that is the question worth asking: a scan
    /// running in another terminal counts. `Idle.attachmentStats` counts
    /// only this process, which is why `down` once refused to stop the
    /// engine and reported "in use by 0 task(s)" in the same breath.
    public static func inUse() -> Bool { Idle.attached() }

    /// Whether the engine is actually answering, not merely recorded.
    ///
    /// ⚠ `status()` is bookkeeping — what `running.json` says — and it can be
    /// confidently wrong. Kill the engine and it still reports a port, exit 0.
    /// That state is worse than a failure because it is indistinguishable
    /// from success and it is self-reinforcing: the obvious recovery, `up`,
    /// used to agree and change nothing. Every script's first line is "is it
    /// up, or must I start it?", and that was the question answered wrongly.
    public static func isAnswering() async -> Bool {
        guard let running = status() else { return false }
        return await SonarAPI.systemStatus(base: base(running.webPort))?.status == .up
    }

    /// Whether the engine is gone, as opposed to merely slow.
    ///
    /// ⚠ The health probe allows four seconds, and a SonarQube
    /// ingesting a 12 MB report from a 111k-line project does not always
    /// answer in four — so a BUSY engine looked exactly like a DEAD one, and
    /// the repair path then tore it down with another client's scan
    /// attached. Measured: two scans succeeded out of eight attempts, and
    /// the log carries nine stop/start cycles in twenty-four minutes.
    ///
    /// The asymmetry decides how many tries: being wrong this way costs the
    /// caller a few seconds' wait, and being wrong the other way destroys
    /// twenty minutes of somebody else's analysis.
    public static func isGone(attempts: Int = 3, gap: Duration = .seconds(2)) async -> Bool {
        guard status() != nil else { return true }
        for attempt in 1...max(1, attempts) {
            if await isAnswering() { return false }
            if attempt < attempts { try? await Task.sleep(for: gap) }
        }
        return true
    }

    /// The engine's state, probed rather than assumed.
    public static func engineState() async -> EngineState {
        if let running = status() {
            if await isAnswering() { return .running(running) }
            // Recorded but not answering. Not "paused" — paused is a state
            // Oilbird chose and can explain; this is a wedge.
            return .unresponsive(running)
        }
        if Owner.transitionInProgress() { return .starting }
        return survey().contains(where: \.needsInstall) ? .notInstalled : .paused
    }

    /// Starts the engine if it is not already running, and returns where it
    /// is.
    ///
    /// This is what lets a client be useful while the engine is paused. An
    /// agent asking for a scan means "scan this", not "tell me the server is
    /// off" — and MCP being reachable while the engine sleeps is the whole
    /// point of separating their lifetimes.
    @discardableResult
    public static func ensureRunning() async throws -> Running {
        try await ensureRunning(onPhase: { _ in })
    }

    /// The same, reporting the phases it passes through.
    ///
    /// ⚠ **The most common wait in the product and nothing showed it.** A warm
    /// start is about fifteen seconds and a cold one was measured at 124 on a
    /// thrashing machine, and the phase that takes most of it is the search
    /// index — worth naming rather than leaving as a silent minute, because a
    /// tool that looks hung gets killed.
    ///
    /// ⚠ A separate function and not a defaulted parameter, for the reason
    /// `doctor(reporting:)` carries: a default argument changes the mangled
    /// symbol of the function it is added to, and `swift build` does not
    /// reliably rebuild the test target afterwards.
    @discardableResult
    public static func ensureRunning(
        onPhase: @Sendable @escaping (Phase) -> Void
    ) async throws -> Running {
        // ⚠ Probed, not assumed: short-circuiting on `status()` alone returns a
        // port and exit 0 against a registered-but-dead engine, and the caller
        // fails on the next call with no idea why.
        if let already = status(), await isAnswering() { return already }
        if status() != nil {
            // Patient, and only then. A single timed-out probe against a
            // busy engine used to be enough to restart it underneath
            // whoever was keeping it busy.
            guard await isGone() else {
                Log.info("the engine is slow, not gone; waiting for it")
                for _ in 0..<60 {
                    try? await Task.sleep(for: .seconds(2))
                    if let running = status(), await isAnswering() { return running }
                }
                if let running = status() { return running }
                throw OilbirdError(
                    .serverUnhealthy, "The server is not answering.",
                    recovery: .retry("Show log"), underlying: "busy past the wait")
            }
            Log.warn("the engine is recorded but gone; restarting it")
            await down()
        }
        do {
            return try await up(onPhase: onPhase)
        } catch let error as OilbirdError where error.cause == .clusterHeldByAnother {
            // ⚠ Someone else is starting the very engine we want, so failing is
            // absurd: wait for the holder and use what they started.

            // Two clients starting at once is the DEFAULT: a window, an agent
            // on MCP and a terminal scan is ordinary use, and refusing sends a
            // script a recovery written for a human.

            // The lock is held only across the transition, so this is a short
            // wait or a real failure.
            Log.info("another client is starting the engine; waiting for it")
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let started = status() { return started }
            }
            throw error
        }
    }
}
