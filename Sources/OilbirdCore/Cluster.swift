import Foundation
import OilbirdModel

/// Creates and runs Oilbird's own PostgreSQL cluster.
///
/// Separate from supervision because `initdb` is one-time and irreversible
/// while starting the postmaster happens every boot — opposite change
/// disciplines.
///
/// It never touches a cluster Oilbird did not create. A developer Mac commonly
/// has a Homebrew PostgreSQL already, and adopting one would corrupt
/// unrelated databases *and* hide provisioning bugs on every developer machine
/// at once.
public enum Cluster {
    /// The role and database SonarQube connects as.
    ///
    /// ⚠ The database is `postgres`, the one `initdb` already creates, rather
    /// than a freshly created `sonar`. That is deliberate: the artifact ships
    /// no `psql` and no `createdb`, so `CREATE DATABASE` would mean
    /// implementing a PostgreSQL wire client to issue one statement at
    /// bootstrap. `initdb --username=sonar` makes `sonar` the superuser and the
    /// owner of `postgres`, which is all SonarQube needs — it wants a database
    /// with DDL rights, and ownership carries `CREATE` on `public` even under
    /// the PostgreSQL 15+ restriction.
    ///
    /// The cost is that Oilbird's data lives in the maintenance database, which
    /// is unusual. The benefit is one fewer moving part on the path that must
    /// work on a machine with nothing installed.
    public static let role = "sonar"
    public static let database = "postgres"

    public struct Running: Sendable {
        public let port: UInt16
        public let socketDirectory: URL
    }

    /// Has a cluster been initialised here, and completely?
    ///
    /// All three markers, not just one: a directory holding only `PG_VERSION`
    /// starts and then dies on a missing `postgresql.conf`, which reads as a
    /// server crash rather than a bad install.
    public static func isInitialised() -> Bool {
        let data = Paths.State.clusterData
        let manager = FileManager.default
        return manager.fileExists(atPath: data.appending(path: "PG_VERSION").path)
            && manager.fileExists(atPath: data.appending(path: "postgresql.conf").path)
            && manager.fileExists(atPath: data.appending(path: "base").path)
    }

    /// The major version of the server that wrote this data directory.
    ///
    /// `PG_VERSION` is one line holding one number, and it is the only thing
    /// in the directory that says which server can read it. `isInitialised`
    /// checks that the file *exists* and has never read it — which is how a
    /// major mismatch could reach `pg_ctl` at all.
    public static func dataDirectoryMajor() -> String? {
        let file = Paths.State.clusterData.appending(path: "PG_VERSION")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let major = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return major.isEmpty ? nil : major
    }

    /// Refuses to point this PostgreSQL at a data directory it cannot read.
    ///
    /// ⚠ **There is no in-place upgrade path here, and this must not be
    /// discovered by trying.** The Zonky artifact ships three binaries —
    /// `initdb`, `pg_ctl`, `postgres` — and no `pg_upgrade`, so nothing in
    /// the container can migrate a data directory across a major. Started
    /// anyway, the postmaster refuses with *"database files are incompatible
    /// with server"*, `pg_ctl` reports only "could not start server", and
    /// `start` surfaced that as **"The database did not start." → Try
    /// again** — a retry button on a cluster that is perfectly intact and
    /// simply unreadable by the server just installed.
    ///
    /// **The recovery is deliberately not an action.** The directory holds
    /// every scan ever run — state, not cache — so
    /// the two things Oilbird could do unasked are both wrong: `initdb` over
    /// it destroys the history, and adopting a user's own PostgreSQL to run
    /// `pg_upgrade` touches a dependency Oilbird does not own. A major
    /// upgrade is a deliberate migration, not an automatic action, and
    /// Oilbird does not have one yet. Until it does, the honest thing is to name
    /// both versions and leave the data untouched: a user told this can
    /// still open the Oilbird they had yesterday and keep working, which is
    /// a real recovery, and one nothing here can take away from them by
    /// guessing.
    ///
    /// Checked **before** `alreadyRunning()` so the answer does not depend
    /// on whether a postmaster from the previous major happens to still be
    /// alive. Adopting one would make `up` work until that process died and
    /// fail for ever afterwards, with the app upgrade that caused it long
    /// out of sight.
    static func assertReadableByInstalledServer() throws {
        guard let wrote = dataDirectoryMajor(),
            let pinned = try? Manifest.bundled().entry(.postgres).major,
            wrote != pinned
        else { return }
        throw OilbirdError(
            .clusterCorrupt,
            "Oilbird's database was created by PostgreSQL \(wrote) and this copy of "
                + "Oilbird ships PostgreSQL \(pinned), which cannot read it.",
            // Not `.retry`: the same attempt produces the same refusal, for
            // ever. Not a reinstall either — the server is fine and the data
            // is fine; it is the pair that is impossible.
            recovery: .reportIssue("Report an issue"),
            underlying: """
                PG_VERSION at \(Paths.State.clusterData.path) is \(wrote), the installed \
                server is \(pinned). There is no pg_upgrade in the Zonky artifact, so \
                Oilbird cannot migrate it. Nothing has been changed: the previous Oilbird \
                still reads this directory. Migrating across a PostgreSQL major is not \
                supported yet.
                """)
    }

    public static func initialise(password: String) async throws {
        guard let initdb = Resolver.executable(.initdb) else {
            throw OilbirdError(
                .clusterCorrupt, "PostgreSQL is not installed.",
                recovery: .reinstall(.postgres), underlying: "initdb absent")
        }
        let data = Paths.State.clusterData
        if FileManager.default.fileExists(atPath: data.path), !isInitialised() {
            Log.warn("wiping a half-initialised cluster at \(data.path)")
            try FileManager.default.removeItem(at: data)
        }
        try FileManager.default.createDirectory(
            at: Paths.State.run, withIntermediateDirectories: true)

        // The password reaches initdb by FILE, never argv: argv is world-
        // readable in `ps`.
        let passwordFile = Paths.State.run.appending(path: "initdb.pw")
        try Data(password.utf8).write(to: passwordFile, options: .completeFileProtection)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)
        defer { try? FileManager.default.removeItem(at: passwordFile) }

        Log.phase("initialise the database")
        let result = try await Child.run(
            initdb,
            [
                "--pgdata=\(data.path)",
                "--username=\(role)",
                "--pwfile=\(passwordFile.path)",
                "--auth-local=scram-sha-256",
                "--auth-host=scram-sha-256",
                "--encoding=UTF8",
                // A shell locale of C.UTF-8 is common, and macOS libc does not
                // properly support it. C is the deterministic choice.
                "--locale=C",
                "--no-instructions",
            ])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: data)
            throw OilbirdError(
                .clusterCorrupt, "Oilbird could not set up its database.",
                recovery: .retry("Try again"),
                underlying: "initdb exited \(result.status): \(result.stderr)")
        }
    }

    /// A postmaster already serving **our** data directory, or `nil`.
    ///
    /// Adopting one is not politeness, it is the only way out of a state a
    /// user can reach and cannot leave. `pg_ctl start` refuses while a live
    /// postmaster holds `postmaster.pid` — "lock file already exists", which
    /// `start` reports as *The database did not start*, on a machine where the
    /// database is running perfectly. Nothing else can clear it either: the
    /// port was assigned by the OS and recorded nowhere Oilbird reads, so the
    /// process is invisible to `status`, to `down` and to the next attempt.
    /// Every `up` from then on fails the same way.
    ///
    /// Three conditions, and all three are needed. The pid must be alive — a
    /// stale pidfile is not this case, and PostgreSQL clears one itself. The
    /// recorded data directory must be ours — this is the guard that keeps the
    /// promise not to touch a cluster Oilbird did not create, such as a
    /// Homebrew installation. And it must answer on the
    /// recorded port, because a pid that has been recycled by an unrelated
    /// process would otherwise be adopted as a database.
    ///
    /// The layout is PostgreSQL's own, stable since 9.3: pid, data directory,
    /// start time, port, socket directory.
    public static func alreadyRunning() -> Running? {
        let pidfile = Paths.State.clusterData.appending(path: "postmaster.pid")
        guard let text = try? String(contentsOf: pidfile, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 5, let pid = Int32(lines[0]), pid > 0, kill(pid, 0) == 0,
            URL(filePath: lines[1]).standardizedFileURL.path
                == Paths.State.clusterData.standardizedFileURL.path,
            let port = UInt16(lines[3]), Readiness.postgresAnswering(port: port)
        else { return nil }
        Log.info("adopting the database already running on port \(port) (pid \(pid))")
        return Running(port: port, socketDirectory: URL(filePath: lines[4]))
    }

    public static func start() async throws -> Running {
        // Before anything at all, including adoption: a data directory this
        // server cannot read is a fact about the pair, and it must not
        // depend on whether a process from the previous major is alive.
        try assertReadableByInstalledServer()
        // Before a port is taken, and before pg_ctl is asked for anything: a
        // cluster that is already up is the answer, not an obstacle.
        if let adopted = alreadyRunning() { return adopted }

        guard let pgCtl = Resolver.executable(.pgCtl) else {
            throw OilbirdError(
                .clusterCorrupt, "PostgreSQL is not installed.",
                recovery: .reinstall(.postgres), underlying: "pg_ctl absent")
        }
        let port = try Ports.free()
        let socketDirectory = Paths.postgresSocketDirectory
        try FileManager.default.createDirectory(
            at: socketDirectory, withIntermediateDirectories: true)

        Log.phase("start the database on port \(port)")
        let options = [
            "-p \(port)", "-h 127.0.0.1", "-k \(socketDirectory.path)",
            "-c listen_addresses=127.0.0.1", "-c unix_socket_permissions=0700",
        ].joined(separator: " ")
        let result = try await Child.run(
            pgCtl,
            [
                "-D", Paths.State.clusterData.path,
                "-l", Paths.Cache.logs.appending(path: "postgres.log").path,
                "-o", options, "-w", "-t", "60", "start",
            ])
        guard result.status == 0 else {
            // pg_ctl says only "could not start server"; the real cause is in
            // the logfile it never prints. Read it, or the error is useless.
            throw OilbirdError(
                .clusterCorrupt, "The database did not start.",
                recovery: .retry("Try again"),
                underlying: "pg_ctl exited \(result.status). log tail:\n\(logTail())")
        }
        guard Readiness.postgresAnswering(port: port) else {
            throw OilbirdError(
                .clusterCorrupt, "The database started but is not answering.",
                recovery: .retry("Try again"), underlying: "no SSLRequest reply on \(port)")
        }
        return Running(port: port, socketDirectory: socketDirectory)
    }

    public static func stop() async throws {
        guard let pgCtl = Resolver.executable(.pgCtl), isInitialised() else { return }
        _ = try await Child.run(
            pgCtl, ["-D", Paths.State.clusterData.path, "-m", "fast", "-w", "stop"])
    }

    private static func logTail() -> String {
        let log = Paths.Cache.logs.appending(path: "postgres.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else {
            return "(no postgres log)"
        }
        return text.split(separator: "\n").suffix(12).joined(separator: "\n")
    }
}
