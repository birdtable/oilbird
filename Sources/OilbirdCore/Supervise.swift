import Darwin
import Foundation
import OilbirdModel

/// Owns one running SonarQube's lifetime.
///
/// SonarQube is four JVMs plus a thin launcher, and **Elasticsearch is a
/// grandchild**, not a direct child — walking direct children misses it.
///
/// ⚠ `SIGKILL` on the supervisor leaves every child running and reparented to
/// PID 1, still serving `UP`. The documented recovery does not work either:
/// `sonar-shutdowner` exits 0 and does nothing, because it pokes a
/// shared-memory flag whose only reader lives inside the JVM that was killed.
/// So the PID set is recorded on disk, and orphans are reaped on the next
/// launch rather than trusted to a tool that cannot see them.
public enum Supervise {
    public struct Descendants: Sendable, Codable {
        public let app: Int32
        public let others: [Int32]
        public let recorded: Date

        /// The App's process group.
        ///
        /// ⚠ This is what actually reaches Elasticsearch. `others` has been
        /// `[]` in every record ever written — `record(app:)` is the only
        /// call site — so the recorded PID set the orphan trap
        /// relies on has always been empty, and a
        /// `SIGKILL`ed App left four JVMs that `reapOrphans` could not see.
        ///
        /// Measured on a live stack: the App, the ES launcher, Elasticsearch
        /// (a GRANDCHILD, ppid 60347), the Web server and the Compute Engine
        /// all share pgid 60346. One `killpg` reaches every one of them,
        /// without walking a process tree, which is easy to walk wrongly.
        ///
        /// Optional because a record written by an older build has none, and
        /// a stack from before this change must still be stoppable.
        public let group: Int32?
    }

    public static var pidfile: URL { Paths.State.run.appending(path: "sonarqube.pids") }

    /// Writes `conf/sonar.properties`.
    ///
    /// SonarQube has no `--config` flag, so this goes inside the install
    /// directory — which is why that directory cannot be read-only.
    ///
    /// The password is written here rather than passed in the environment: a
    /// child's environment is readable, and a properties file can be `0600`.
    /// - Parameter webJavaOpts: the web process's JVM options, or `nil` to
    ///   leave SonarQube's own default in place. Injected rather than read,
    ///   because this domain may not see `Prefs` — the same shape the
    ///   database password and the ports arrive in.
    public static func writeConfiguration(
        databasePort: UInt16, databasePassword: String, webPort: UInt16, searchPort: UInt16,
        webJavaOpts: String? = nil
    ) throws {
        let conf = Paths.Cache.sonarqube.appending(path: "conf/sonar.properties")
        let properties = """
            # Written by Oilbird. Edits are overwritten on every start.
            sonar.jdbc.url=jdbc:postgresql://127.0.0.1:\(databasePort)/\(Cluster.database)
            sonar.jdbc.username=\(Cluster.role)
            sonar.jdbc.password=\(databasePassword)

            # Loopback only. The default is 0.0.0.0, which on a café network is
            # an unauthenticated foothold the user never opted into.
            sonar.web.host=127.0.0.1
            sonar.web.port=\(webPort)
            sonar.search.host=127.0.0.1
            sonar.search.port=\(searchPort)
            # Pinned. Left unset this is random per boot, and a moving listener
            # invites a firewall prompt every time.
            sonar.es.port=\(searchPort &+ 1)

            # Elasticsearch refuses to allocate a shard once the disk passes
            # its high watermark, which is a percentage — 90% by default. On
            # an ordinary laptop disk that fires with tens of GiB still free,
            # and a local index needs megabytes. SonarQube then cannot
            # read `metadatas/dbVendor`, the Web server dies with
            # `no_shard_available_action_exception`, and Oilbird reports "The
            # server did not start in time" — with nothing wrong and no way to
            # act on it short of deleting tens of GiB.
            #
            # The setting is written for a fleet: over the watermark, shards
            # relocate to another node. There is no other node here and never
            # will be, so the check can only ever refuse work. Off.
            #
            # It reaches Elasticsearch by this route because SonarQube owns
            # `elasticsearch.yml` — it regenerates it on every start, header
            # DO NOT EDIT. `sonar.search.javaAdditionalOpts` is the passthrough
            # SonarQube itself provides: `EsSettings` looks for exactly this
            # substring and writes the corresponding key into the file it
            # generates. It is not a JVM flag despite the `-D`, and the
            # spelling has to match to the character.
            sonar.search.javaAdditionalOpts=-Dcluster.routing.allocation.disk.threshold_enabled=false

            sonar.path.data=\(Paths.Cache.sonarData.path)
            sonar.path.logs=\(Paths.Cache.logs.path)
            sonar.path.temp=\(Paths.Cache.temp.path)

            # Defaults to true and phones home. Not acceptable unasked in a
            # local tool.
            sonar.telemetry.enable=false
            sonar.updatecenter.activate=false

            # Left false deliberately: an upgrade stops at DB_MIGRATION_NEEDED
            # and `awaitReady` drives the migration itself through
            # `SonarAPI.migrate`, reporting each poll. Schema migration on a
            # large instance is slow, and a spinner is not an answer.
            sonar.autoDatabaseUpgrade=false
            """
        // Appended, never interpolated with an empty fallback: an empty
        // `sonar.web.javaOpts=` is a web process with no options at all, which
        // takes away the heap dump the default asks for.
        let full =
            webJavaOpts.map {
                properties + """


                    # The web process's heap. Absent unless the user has chosen
                    # one, so SonarQube's own default stands by default.
                    sonar.web.javaOpts=\($0)
                    """
            } ?? properties
        try FileManager.default.createDirectory(
            at: conf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(full.utf8).write(to: conf, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: conf.path)
    }

    /// Elasticsearch's bootstrap checks are on because the JDBC URL is not H2.
    /// On macOS the one that bites is file descriptors, and it is the **hard**
    /// limit that matters: HotSpot raises soft to hard at JVM init, so a low
    /// soft limit starts fine and a low hard limit fails with exit 78.
    public static func assertFileDescriptorHeadroom() throws {
        let limits = SonarQubeDependency.fileDescriptorLimit()
        guard limits.hard >= SonarQubeDependency.requiredFileDescriptors else {
            throw OilbirdError(
                .serverUnhealthy,
                "This Mac allows too few open files for the search index.",
                recovery: .reportIssue("Report an issue"),
                underlying: """
                    RLIMIT_NOFILE hard is \(limits.hard), Elasticsearch needs \
                    \(SonarQubeDependency.requiredFileDescriptors). It would exit 78.
                    """)
        }
    }

    public static func start(webPort: UInt16) async throws -> Process {
        guard let java = Resolver.executable(.java) else {
            throw OilbirdError(
                .serverUnhealthy, "Java is not installed.",
                recovery: .reinstall(.jdk), underlying: "no java in the container")
        }
        try assertFileDescriptorHeadroom()
        let version = try Manifest.bundled().entry(.sonarqube).version
        let jar = SonarQubeDependency().applicationJar(version: version)

        Log.phase("start the server on port \(webPort)")
        // Launched by jar, never `sonar.sh`: that writes its pidfile into the
        // install directory, depends on relative paths, and its own command
        // line is this one.

        // `-Dsonar.log.console` goes AFTER `-jar`, being an application
        // argument rather than a JVM flag.

        // The JDK propagates for free: SonarQube derives every child JVM's
        // java binary from this one's `java.home`, so no `JAVA_HOME` is
        // needed.
        let process = try Child.spawn(java, ["-jar", jar.path, "-Dsonar.log.console=true"])
        // The group, read back from the kernel rather than assumed. Foundation
        // puts a spawned child in its own process group — `Child`'s docstring
        // says the opposite, and the opposite is what was measured.
        let group = getpgid(process.processIdentifier)
        try record(
            app: process.processIdentifier, group: group > 0 ? group : nil)
        return process
    }

    /// Polls until the server is up, or until it is provably not coming up —
    /// upgrading the schema on the way if the new jar needs it.
    ///
    /// ⚠ `DB_MIGRATION_NEEDED` is handled **before** the terminal check, and
    /// that ordering is the whole of the fix. It used to fall straight
    /// through to the throw, so a bumped SonarQube against an existing
    /// database produced "The database needs upgrading before the server can
    /// start." with a Show log button, `Oilbird.up` tore the engine down, and
    /// the next `up` reproduced it exactly. The state is not terminal for
    /// anyone who can act on it; it was terminal only because nothing did.
    ///
    /// `Status.isTerminal` still reports it as terminal and that is still
    /// right: it says *polling* will not turn it into `UP`, which is why
    /// this drives the migration rather than waiting.
    public static func awaitReady(
        webPort: UInt16, timeout: TimeInterval = 180,
        onState: @Sendable (SonarAPI.Status?, TimeInterval) -> Void = { _, _ in },
        onMigration: @Sendable (SonarAPI.Migration, TimeInterval) -> Void = { _, _ in }
    ) async throws -> SonarAPI.SystemStatus {
        let base = Loopback.url(port: webPort)
        // ⚠ From the first poll, not from the phase change. What the reader
        // is timing is "how long have I been staring at this", and that
        // starts when the waiting starts.
        let began = Date()
        var deadline = Date().addingTimeInterval(timeout)
        var upgraded = false
        while Date() < deadline {
            let status = await SonarAPI.systemStatus(base: base)
            onState(status?.status, Date().timeIntervalSince(began))
            if let status {
                if status.status == .up { return status }
                if status.status == .migrationNeeded, !upgraded {
                    Log.phase("upgrade the database schema")
                    let began = Date()
                    try await SonarAPI.migrate(base: base) { migration in
                        onMigration(migration, Date().timeIntervalSince(began))
                    }
                    upgraded = true
                    // The migration's wait is not this one's: it runs for
                    // minutes and the server still has its whole normal start
                    // to do, so the readiness budget begins again.
                    deadline = Date().addingTimeInterval(timeout)
                    continue
                }
                if status.status?.isTerminal == true {
                    // Reached only when a migration this function ran, and was
                    // told had SUCCEEDED, leaves the server still asking. A
                    // second attempt is the loop, so the recovery is the log.
                    let stuck = status.status == .migrationNeeded
                    throw OilbirdError(
                        .serverUnhealthy,
                        stuck
                            ? "The database still needs upgrading after Oilbird upgraded it."
                            : "The server started but could not come up.",
                        recovery: stuck
                            ? .chooseAlternative("Show log") : .retry("Show log"),
                        underlying: "status \(status.state), upgraded: \(upgraded)")
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw OilbirdError(
            .serverUnhealthy, "The server did not start in time.",
            recovery: .retry("Show log"),
            underlying: "no UP within \(Int(timeout))s on port \(webPort)")
    }

    /// `SIGTERM` to the supervisor, then escalate.
    ///
    /// A live supervisor stops all four JVMs in about a second through shared
    /// memory. If it is already dead, that path does not exist — which is what
    /// the recorded PID set is for.
    public static func stop(gracePeriod: TimeInterval = 8) async {
        guard let recorded = readRecord() else { return }
        Log.phase("stop the server")
        kill(recorded.app, SIGTERM)

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline, isAlive(recorded.app) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // The group first, then any pid still standing. `killpg` is what
        // reaches Elasticsearch, a grandchild that otherwise survives
        // reparented to PID 1 holding its port and half a gigabyte.

        // ⚠ NOT for postgres: every postmaster child has its own process
        // group, so a `killpg` reaches one process and abandons the rest.
        // Postgres stops through `pg_ctl -m fast`, which is `Cluster`'s job.

        // ⚠ Expanded to members rather than `killpg`, like `reapOrphans`: the
        // record is fresh within one run, but "fresh" is not a reason to send
        // SIGKILL to a number nobody verified.
        var candidates = [recorded.app] + recorded.others
        if let group = recorded.group, group > 0 {
            candidates += Kernel.members(ofGroup: group)
        }
        for pid in Set(candidates).sorted() where pid > 0 && isAlive(pid) {
            guard let path = Kernel.executablePath(of: pid), Paths.isInsideContainer(path) else {
                continue
            }
            Log.warn("escalating to SIGKILL for pid \(pid)")
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidfile)
    }

    /// Reaps anything left by a previous run — and nothing else.
    ///
    /// A surviving Web server holding the port would otherwise present as an
    /// inexplicable bind failure on the next launch.
    ///
    /// ⚠ **This used to kill processes that had nothing to do with Oilbird.**
    /// The only test before signalling was `killpg(group, 0) == 0`, which
    /// proves a group with that number EXISTS, not that it is ours.
    /// `run/sonarqube.pids` survives a reboot verbatim and pids restart low
    /// after one, so the recorded group number is very likely to belong to
    /// something else by the next launch — and the next launch is any
    /// `oilbird up`, any `oilbird install`, or opening the app. Reproduced
    /// after a reboot: an unrelated process group was terminated, and the
    /// only trace was one line reading `reaping orphaned process group <n>
    /// from a previous run`. Someone's build, editor or shell job, killed by
    /// a code-quality tool starting up.
    ///
    /// So: three conditions, all needed, the same shape as
    /// `Cluster.alreadyRunning()`. The record must post-date the last boot,
    /// because nothing recorded before it can still be the process it named.
    /// Each pid is checked individually — no `killpg`, which cannot ask who
    /// it is about to signal. And each must be running an executable inside
    /// Oilbird's own container, which is the only claim that actually
    /// distinguishes our JVM from anybody else's.
    @discardableResult
    public static func reapOrphans() -> Int {
        guard let recorded = readRecord() else { return 0 }
        defer { try? FileManager.default.removeItem(at: pidfile) }

        if let boot = Kernel.bootTime(), recorded.recorded < boot {
            Log.warn(
                "ignoring a process record from before the last restart "
                    + "(recorded \(recorded.recorded), booted \(boot)) — its pids are "
                    + "somebody else's now")
            return 0
        }

        // The group is expanded to its members rather than signalled whole:
        // Elasticsearch is a grandchild and only the group reaches it, but a
        // group cannot be interrogated and a pid can.
        var candidates = [recorded.app] + recorded.others
        if let group = recorded.group, group > 0 {
            candidates += Kernel.members(ofGroup: group)
        }

        var reaped = 0
        for pid in Set(candidates) where pid > 0 && isAlive(pid) {
            guard let path = Kernel.executablePath(of: pid), Paths.isInsideContainer(path) else {
                Log.warn(
                    "NOT reaping pid \(pid): it is not running anything Oilbird installed "
                        + "(\(Kernel.executablePath(of: pid) ?? "path unreadable"))")
                continue
            }
            Log.warn("reaping orphaned pid \(pid) (\(path)) from a previous run")
            kill(pid, SIGTERM)
            reaped += 1
        }
        return reaped
    }

    /// Asking the kernel who a pid actually is.
    ///
    /// Its own type because these are facts about the machine rather than
    /// about supervision, and because the identity check is the whole
    /// difference between reaping our orphans and killing a stranger's work.
    ///
    /// Named `Kernel` rather than the obvious `Process`, which is
    /// Foundation's — a nested type of that name shadows it for the whole
    /// file, and `Supervise` returns a Foundation `Process`.
    public enum Kernel {
        /// The executable a pid is running, or nil if it cannot be read —
        /// which includes every process belonging to another user.
        public static func executablePath(of pid: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let path = String(decoding: bytes, as: UTF8.self)
            return path.isEmpty ? nil : path
        }

        /// Every pid in a process group, so each can be judged on its own.
        public static func members(ofGroup group: Int32) -> [Int32] {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var entries = [kinfo_proc](
                repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            guard sysctl(&mib, 4, &entries, &size, nil, 0) == 0 else { return [] }
            return entries.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }
        }

        /// When this machine last booted. A pid recorded before it is a
        /// number that has since been handed to somebody else.
        public static func bootTime() -> Date? {
            var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
            var boot = timeval()
            var size = MemoryLayout<timeval>.stride
            guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
            return Date(
                timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
        }
    }

    // MARK: -

    public static func record(app: Int32, others: [Int32] = [], group: Int32? = nil) throws {
        try write(Descendants(app: app, others: others, recorded: Date(), group: group))
    }

    /// A record with a chosen timestamp, so the pre-boot guard is testable.
    ///
    /// Public only for the suite: the guard cannot be exercised otherwise
    /// without rebooting the machine, and an untested guard on a code path
    /// that sends signals is not a guard.
    public static func recordForTesting(app: Int32, group: Int32?, at recorded: Date) throws {
        try write(Descendants(app: app, others: [], recorded: recorded, group: group))
    }

    private static func write(_ record: Descendants) throws {
        try FileManager.default.createDirectory(
            at: Paths.State.run, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: pidfile, options: .atomic)
    }

    public static func readRecord() -> Descendants? {
        guard let data = FileManager.default.contents(atPath: pidfile.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Descendants.self, from: data)
    }

    public static func isAlive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }
}
