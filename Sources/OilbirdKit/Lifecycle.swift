import Foundation
import OilbirdCore

/// Starting the engine, stopping it, and saying which it is.
///
/// ⚠ An extension in its own file, not a separate type. `Oilbird` is
/// the one barrel a client imports and that is deliberate; what was not
/// deliberate is all of it living in one 1,877-line file. Splitting the
/// FILE changes nothing a caller can see.
extension Oilbird {
    public struct Running: Sendable, Codable, Equatable {
        public let webPort: UInt16
        public let databasePort: UInt16

        /// Public so a test can name a running engine.
        ///
        /// The state vocabulary every surface renders is keyed on
        /// `EngineState`, and `.running` is the case with a payload — a
        /// suite that cannot construct one cannot assert that Pause is
        /// offered from it and Resume is not, which is the disagreement
        /// this vocabulary exists to prevent.
        public init(webPort: UInt16, databasePort: UInt16) {
            self.webPort = webPort
            self.databasePort = databasePort
        }
    }

    static var runningFile: URL { Paths.State.run.appending(path: "running.json") }

    /// Service state read from disk, never from memory — the CLI, the GUI and
    /// an agent may each have started it, and none of them owns the lifetime.
    public static func status() -> Running? {
        guard let data = FileManager.default.contents(atPath: runningFile.path) else { return nil }
        return try? JSONDecoder().decode(Running.self, from: data)
    }

    /// What `up` is doing, for a client that shows it.
    ///
    /// A twenty-five second wait with one static sentence is indistinguishable
    /// from a hang. These are the real steps, in order, and the slow one says
    /// so — the search index is most of the wait on every start.
    public enum Phase: Sendable, Equatable {
        case preparingDatabase
        case startingDatabase
        case startingServer
        /// SonarQube's own reported status while it comes up.
        /// ⚠ Carries the ELAPSED seconds as well as SonarQube's own status
        /// word, for the reason `migratingDatabase` already carried them and
        /// this did not: the status sits on `starting` for the whole wait, so
        /// with nothing moving there is no way to tell a slow start from a
        /// dead one. The window showed a static "about 25 seconds"
        /// for two minutes, which is worse than saying nothing — it is a
        /// claim the reader can watch being wrong.
        case waitingForServer(status: String, elapsed: TimeInterval)
        /// A schema upgrade, which happens only after a SonarQube bump. The
        /// elapsed seconds are the point: the state string sits on
        /// `MIGRATION_RUNNING` for the whole of it, so without a number
        /// moving there is no way to tell a long migration from a dead one.
        case migratingDatabase(status: String, elapsed: TimeInterval)
        case signingIn

        public var label: String {
            switch self {
            case .preparingDatabase: "Preparing the database"
            case .startingDatabase: "Starting the database"
            case .startingServer: "Starting the server"
            case .waitingForServer: "Warming up the search index"
            case .migratingDatabase: "Upgrading the database"
            case .signingIn: "Signing in"
            }
        }

        /// What the search index usually costs, said once rather than in
        /// three strings that can disagree.
        static let usualIndexSeconds = 25

        public var detail: String {
            switch self {
            case .preparingDatabase: "First run only — this happens once."
            case .startingDatabase: "A moment."
            case .startingServer: "Launching SonarQube."
            case .waitingForServer(let status, let elapsed):
                // Past the estimate the estimate stops being said. A number
                // that keeps counting is honest; "about 25 seconds" on the
                // ninetieth second is not.
                Int(elapsed) <= Self.usualIndexSeconds
                    ? "Usually about \(Self.usualIndexSeconds) seconds. \(Int(elapsed))s so far "
                        + "— SonarQube says: \(status.lowercased())."
                    : "\(Int(elapsed))s so far, which is longer than usual — SonarQube says: "
                        + "\(status.lowercased()). `oilbird log` has the detail."
            case .migratingDatabase(let status, let elapsed):
                "This version of Oilbird needs a newer database schema. "
                    + "\(Int(elapsed))s so far — SonarQube says: \(status.lowercased())."
            case .signingIn: "Almost there."
            }
        }
    }

    /// A dependency whose installed version is not the one this build pins.
    ///
    /// Read from `Paths.State.installedManifest`, which is written as each
    /// artefact is placed. It is the only thing that can tell a *downgrade*
    /// — this build older than the install — from a bump, because both look
    /// identical from the disk alone.
    public struct VersionChange: Sendable, Equatable {
        public let id: DependencyID
        public let installed: String
        public let expected: String

        public init(id: DependencyID, installed: String, expected: String) {
            self.id = id
            self.installed = installed
            self.expected = expected
        }

        public var summary: String {
            "\(id.rawValue) \(installed) → \(expected)"
        }
    }

    /// Every dependency the container records at a version this build does
    /// not pin.
    ///
    /// Empty on a machine that has never installed anything, and empty on
    /// one installed before the record existed — absence of a record is not
    /// evidence of a change, and reporting one would be a false alarm on
    /// every install that predates it.
    public static func versionChanges() -> [VersionChange] {
        guard let pinned = try? Manifest.bundled() else { return [] }
        return DependencyID.allCases.compactMap { id in
            guard let installed = Install.installedEntry(id),
                let expected = try? pinned.entry(id),
                installed.version != expected.version
            else { return nil }
            return VersionChange(
                id: id, installed: installed.version, expected: expected.version)
        }
    }

    public static func up(
        onPhase: @Sendable @escaping (Phase) -> Void = { _ in }
    ) async throws -> Running {
        if let already = status(),
            await SonarAPI.systemStatus(base: base(already.webPort))?.status == .up
        {
            return already
        }
        // ⚠ Released when the start FINISHES: the lock protects the state
        // transition, not the running lifetime, which no process is alive to
        // hold. Holding it leaves a stale lock after every `up`.
        try Owner.acquire()
        defer { Owner.release() }
        Supervise.reapOrphans()

        var secrets =
            Secrets.load()
            ?? Secrets.Stored(
                databasePassword: Secrets.generatePassword(),
                adminPassword: Secrets.generatePassword(), analysisToken: nil)
        if Secrets.load() == nil { try Secrets.save(secrets) }

        if !Cluster.isInitialised() {
            onPhase(.preparingDatabase)
            try await Cluster.initialise(password: secrets.databasePassword)
        }
        onPhase(.startingDatabase)
        // The ports this engine used last time, so a restart is invisible to
        // anything already talking to it. In preferences, since
        // `running.json` is deleted by the stop these must survive.
        let preferences = Preferences.load()
        let remembered = preferences.lastPorts
        let cluster = try await Cluster.start()

        // Until `running.json` is written a started database is recorded
        // nowhere, so `status` cannot see it and the next `up` is refused by
        // its own pidfile. A start completes or leaves nothing behind.
        do {
            // A pinned port beats a remembered one: it was pinned because
            // something outside Oilbird has the URL written down, and "where
            // it landed last time" is exactly what is not good enough.
            let wanted = preferences.pinnedWebPort ?? remembered?.web
            let webPort = try Ports.preferring(wanted)
            if let pinned = preferences.pinnedWebPort, pinned != webPort {
                Log.warn(
                    "port \(pinned) is pinned but taken; the dashboard is on \(webPort)")
            }
            let searchPort = try Ports.preferring(remembered?.search)
            try Supervise.writeConfiguration(
                databasePort: cluster.port, databasePassword: secrets.databasePassword,
                webPort: webPort, searchPort: searchPort,
                webJavaOpts: preferences.webMemoryMegabytes.map {
                    Preferences.WebMemory.javaOpts(megabytes: $0)
                })
            onPhase(.startingServer)
            _ = try await Supervise.start(webPort: webPort)
            _ = try await Supervise.awaitReady(
                webPort: webPort,
                onState: { status, elapsed in
                    onPhase(
                        .waitingForServer(status: status?.rawValue ?? "starting", elapsed: elapsed))
                },
                // A bumped jar against an existing database migrates here
                // rather than dead-ending, reported through the same channel
                // as everything else so a client showing one shows all.
                onMigration: { migration, elapsed in
                    onPhase(
                        .migratingDatabase(
                            status: migration.message ?? migration.state, elapsed: elapsed))
                })
            onPhase(.signingIn)
            try await Provisioning.run(base: base(webPort))
            secrets = Secrets.load() ?? secrets
            // Presses the x on SonarQube's banners on EVERY start: a
            // setup-only version leaves every instance provisioned earlier
            // showing the strip for ever.
            let refused = await SonarAPI.dismissNotices(
                base: base(webPort), token: secrets.analysisToken ?? "")
            if !refused.isEmpty {
                Log.warn("these notices were not dismissed: \(refused.joined(separator: ", "))")
            }

            let running = Running(webPort: webPort, databasePort: cluster.port)
            try JSONEncoder().encode(running).write(to: runningFile, options: .atomic)
            var stored = Preferences.load()
            stored.lastPorts = .init(web: webPort, search: searchPort)
            try? Preferences.save(stored)
            // After `running.json`, because the watchdog's own exit condition
            // is that file's absence — started earlier it would see no engine
            // and quit immediately.
            ensureWatching()
            return running
        } catch {
            await down()
            throw error
        }
    }
}
