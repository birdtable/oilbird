import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

// Shipping a new pinned version of anything used to break every existing
// install, in four separate ways. These are the four.

func migrationTests() {
    Harness.suite("SonarAPI — the database upgrade a version bump needs") {
        Harness.test("every migration state the server can report is decodable") {
            let all = [
                "NO_MIGRATION", "NOT_SUPPORTED", "MIGRATION_REQUIRED", "MIGRATION_RUNNING",
                "MIGRATION_SUCCEEDED", "MIGRATION_FAILED",
            ]
            for raw in all {
                Harness.expectTrue(
                    SonarAPI.MigrationState(rawValue: raw) != nil, "\(raw) is not decodable")
            }
            // An unknown state must reach the poller as an unknown state, not
            // as an undecodable response — a server that adds one must not
            // make Oilbird unable to read the reply at all.
            let future = SonarAPI.Migration(state: "MIGRATION_TELEPORTED")
            Harness.expectNil(future.status, "an unknown state was mapped to a known one")
        }

        // ⚠ The assertion is that the POST is really SENT, not that the
        // function returns: `migrate_db` appeared nowhere in the source while
        // `sonar.properties` claimed Oilbird drove the migration.
        Harness.test("the upgrade is asked for, then polled to a verdict") {
            let polls = Box(0)
            guard
                let server = FixtureServer(answer: { request in
                    switch request.path {
                    case "/api/system/migrate_db":
                        return .ok(#"{"state":"MIGRATION_RUNNING"}"#)
                    case "/api/system/db_migration_status":
                        polls.set(polls.get() + 1)
                        return .ok(
                            polls.get() >= 2
                                ? #"{"state":"MIGRATION_SUCCEEDED","message":"Migration succeeded."}"#
                                : #"{"state":"MIGRATION_RUNNING","message":"Database migration is running."}"#
                        )
                    default:
                        return .notFound
                    }
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }

            let seen = Box(0)
            let base = server.base
            let outcome = runSync(within: 30) {
                try await SonarAPI.migrate(base: base) { _ in seen.set(seen.get() + 1) }
            }
            Harness.expectTrue(
                (try? outcome.get()) != nil, "a successful migration was reported as a failure")
            Harness.expectTrue(
                server.requests.contains(
                    .init(method: "POST", path: "/api/system/migrate_db")),
                "the migration was never asked for — the endpoint was not called at all")
            Harness.expectTrue(
                server.requests.contains(
                    .init(method: "GET", path: "/api/system/db_migration_status")),
                "the migration was started and never polled")
            // The caller can tell a long migration from a dead one only
            // if something reports each poll.
            Harness.expectTrue(seen.get() >= 2, "progress was reported \(seen.get()) times")
        }

        // A migration that fails leaves the schema half-upgraded. Running it
        // again is the loop, so the recovery must not be one.
        Harness.test("a failed upgrade is terminal, in the server's own words") {
            guard
                let server = FixtureServer(answer: { _ in
                    .ok(
                        #"{"state":"MIGRATION_FAILED","message":"Fail to execute ALTER TABLE issues"}"#
                    )
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) { try await SonarAPI.migrate(base: base) }
            guard case .failure(let error) = outcome, let failure = error as? OilbirdError else {
                Harness.expectTrue(false, "a failed migration did not fail the call")
                return
            }
            Harness.expectEqual(failure.cause, .serverUnhealthy)
            Harness.expectTrue(
                failure.underlying?.contains("ALTER TABLE issues") == true,
                "the server's own explanation was dropped")
            if case .retry = failure.recovery {
                Harness.expectTrue(
                    false, "the recovery for a half-finished migration is to run it again")
            } else {
                Harness.expectNotEmpty(failure.recovery.actionLabel)
            }
        }

        Harness.test("nothing to upgrade finishes without polling") {
            guard
                let server = FixtureServer(answer: { _ in .ok(#"{"state":"NO_MIGRATION"}"#) })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) { try await SonarAPI.migrate(base: base) }
            Harness.expectTrue(
                (try? outcome.get()) != nil, "NO_MIGRATION was treated as a failure")
            Harness.expectEqual(
                server.requests.count, 1, "a database with nothing to do was polled anyway")
        }

        Harness.test("a server that refuses the upgrade is not polled for half an hour") {
            guard let server = FixtureServer(answer: { _ in .notFound }) else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) { try await SonarAPI.migrate(base: base) }
            guard case .failure(let error) = outcome, error is OilbirdError else {
                Harness.expectTrue(false, "a refused POST did not fail the call")
                return
            }
            Harness.expectTrue(true, "the refusal was immediate")
        }
    }

    Harness.suite("Supervise — an upgrade is driven, not reported as a dead end") {
        // ⚠ Throwing on DB_MIGRATION_NEEDED has `up` tear the engine down and
        // rethrow, and the next `up` reach the same state: every existing
        // install loops there for ever on the first SonarQube bump.
        Harness.test("DB_MIGRATION_NEEDED is migrated through, not thrown") {
            let migrated = Box(false)
            guard
                let server = FixtureServer(answer: { request in
                    switch request.path {
                    case "/api/system/status":
                        let state = migrated.get() ? "UP" : "DB_MIGRATION_NEEDED"
                        return .ok(#"{"version":"26.10","status":"\#(state)"}"#)
                    case "/api/system/migrate_db":
                        migrated.set(true)
                        return .ok(#"{"state":"MIGRATION_SUCCEEDED"}"#)
                    default:
                        return .notFound
                    }
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }

            let reported = Box(0)
            let port = server.port
            let outcome = runSync(within: 40) {
                try await Supervise.awaitReady(webPort: port, timeout: 20) { _, _ in
                } onMigration: { _, _ in
                    reported.set(reported.get() + 1)
                }
            }
            guard case .success(let status) = outcome else {
                Harness.expectTrue(
                    false,
                    "a server asking to be upgraded was reported as a failure to start")
                return
            }
            Harness.expectEqual(status.status, .up)
            Harness.expectTrue(
                reported.get() >= 1, "the upgrade happened with nothing shown to the user")
        }

        // The state stays terminal in the vocabulary, because polling alone
        // still cannot turn it into UP. That is why `awaitReady` acts.
        Harness.test("DB_MIGRATION_NEEDED is still not something to wait out") {
            Harness.expectTrue(SonarAPI.Status.migrationNeeded.isTerminal)
        }
    }
}

func versionPinTests() {
    Harness.suite("detect — the version is read off the install, never assumed") {
        guard let manifest = try? Manifest.bundled() else {
            Harness.expectTrue(false, "no bundled manifest")
            return
        }

        // ⚠ Globbing `sonar-scanner-cli*.jar` and returning the MANIFEST's
        // version skips the install after a bump: the old jar runs every scan
        // and `doctor` prints the new version beside it.
        Harness.test("a scanner of the wrong version is not the pinned scanner") {
            guard let entry = try? manifest.entry(.scanner) else { return }
            let scanner = ScannerDependency()
            let lib = Paths.Cache.scanner.appending(path: "lib")
            defer { try? FileManager.default.removeItem(at: Paths.Cache.scanner) }

            try? FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
            try? Data("jar".utf8).write(to: lib.appending(path: "sonar-scanner-cli-0.0.0.jar"))
            Harness.expectEqual(
                scanner.detect(), .missing,
                "a superseded scanner jar was reported as the pinned one")

            try? Data("jar".utf8).write(to: scanner.cliJar(version: entry.version))
            Harness.expectEqual(
                scanner.detect(), .present(version: entry.version),
                "the pinned scanner jar was not recognised")
        }

        // ⚠ `Resolver.executable(.java) == nil ? .missing : .present`, and a
        // `verify()` that hard-coded 21 — so a bump inside or beyond 21 was a
        // no-op on every existing install.
        Harness.test("a JDK of the wrong build is not the pinned JDK") {
            guard let entry = try? manifest.entry(.jdk) else { return }
            let jdk = JDKDependency()
            let home = Paths.Cache.jdk.appending(path: "Contents/Home")
            defer { try? FileManager.default.removeItem(at: Paths.Cache.jdk) }

            try? FileManager.default.createDirectory(
                at: home.appending(path: "bin"), withIntermediateDirectories: true)
            let java = home.appending(path: "bin/java")
            try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: java)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: java.path)

            // A runtime that will not say what it is cannot be the pinned one.
            Harness.expectEqual(
                jdk.detect(), .missing, "a JDK with no release file was taken on trust")

            let release = home.appending(path: "release")
            try? Data("SEMANTIC_VERSION=\"1.2.3+4\"\n".utf8).write(to: release)
            Harness.expectEqual(
                jdk.detect(), .missing, "a superseded JDK was reported as the pinned one")

            try? Data("SEMANTIC_VERSION=\"\(entry.pinnedIdentifier)\"\n".utf8).write(to: release)
            Harness.expectEqual(
                jdk.detect(), .present(version: entry.pinnedIdentifier),
                "the pinned JDK was not recognised")
        }

        // The pinned identifier has to be the one Adoptium writes on disk.
        // The semver in `version` appears nowhere in the release file, so a
        // comparison against it could only ever fail.
        Harness.test("the JDK is pinned by the identifier that exists on disk") {
            guard let entry = try? manifest.entry(.jdk) else { return }
            Harness.expectNotEmpty(entry.release ?? "", "the JDK entry lost its release tag")
            Harness.expectTrue(
                !entry.pinnedIdentifier.hasPrefix("jdk-"),
                "the release tag reached the comparison with its prefix still on")
        }

        // ⚠ Same shape as the JDK's, same defect: any tree with a binary in
        // it satisfied `detect()`.
        Harness.test("a PostgreSQL of the wrong major is not the pinned one") {
            guard let entry = try? manifest.entry(.postgres) else { return }
            let postgres = PostgresDependency()
            let root = Paths.Cache.postgres
            defer { try? FileManager.default.removeItem(at: root) }

            try? FileManager.default.createDirectory(
                at: root.appending(path: "bin"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: root.appending(path: "share/postgresql"), withIntermediateDirectories: true)
            for tool in ["postgres", "initdb"] {
                let binary = root.appending(path: "bin/\(tool)")
                try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: binary.path)
            }
            let catalogue = root.appending(path: "share/postgresql/postgres.bki")

            try? Data("# PostgreSQL 99\ncreate pg_proc\n".utf8).write(to: catalogue)
            Harness.expectEqual(
                postgres.detect(), .missing,
                "a PostgreSQL of another major was reported as the pinned one")

            try? Data("# PostgreSQL \(entry.major)\ncreate pg_proc\n".utf8).write(to: catalogue)
            Harness.expectEqual(
                postgres.detect(), .present(version: entry.major),
                "the pinned PostgreSQL major was not recognised")

            // The artefact carries no finer marker than the major, so the
            // exact version comes from what the install recorded. A minor
            // bump is invisible on disk and would otherwise never reinstall.
            try? Install.record(.postgres, stale(entry))
            Harness.expectEqual(
                postgres.detect(), .missing,
                "a recorded minor version behind the pin was reported as present")
            try? Install.record(.postgres, entry)
            Harness.expectEqual(postgres.detect(), .present(version: entry.version))
            try? FileManager.default.removeItem(at: Paths.State.installedManifest)
        }

        Harness.test("no detect reports the manifest's version for an empty container") {
            for dependency in [
                JDKDependency() as any ManagedDependency, SonarQubeDependency(),
                PostgresDependency(), ScannerDependency(),
            ] {
                guard !FileManager.default.fileExists(atPath: Paths.install(dependency.id).path)
                else { continue }
                Harness.expectEqual(
                    dependency.detect(), .missing, "\(dependency.id) claimed a version")
            }
        }
    }
}

func installedManifestTests() {
    Harness.suite("What is installed, recorded where it can be read") {
        // ⚠ Three documents described the installed manifest as written on
        // first run and nothing wrote it, so a version change was
        // undiagnosable and a downgrade looked like a bump.
        Harness.test("an install records what it placed") {
            guard let manifest = try? Manifest.bundled(),
                let entry = try? manifest.entry(.sonarqube)
            else { return }
            defer { try? FileManager.default.removeItem(at: Paths.State.installedManifest) }
            try? FileManager.default.removeItem(at: Paths.State.installedManifest)

            Harness.expectNil(Install.installedEntry(.sonarqube), "something was recorded already")
            try? Install.record(.sonarqube, entry)
            Harness.expectTrue(
                FileManager.default.fileExists(atPath: Paths.State.installedManifest.path),
                "nothing was written to the container")
            Harness.expectEqual(Install.installedEntry(.sonarqube)?.version, entry.version)
            // Per dependency, not a wholesale copy: one install must not
            // claim the other three are at this build's versions.
            Harness.expectNil(
                Install.installedEntry(.jdk),
                "recording one dependency claimed another had been installed")
        }

        Harness.test("a record and a pin that differ are reported as a change") {
            guard let manifest = try? Manifest.bundled(),
                let entry = try? manifest.entry(.scanner)
            else { return }
            defer { try? FileManager.default.removeItem(at: Paths.State.installedManifest) }
            try? FileManager.default.removeItem(at: Paths.State.installedManifest)

            Harness.expectEqual(
                Oilbird.versionChanges().count, 0,
                "an empty container invented a version change")

            try? Install.record(.scanner, stale(entry))
            let changes = Oilbird.versionChanges()
            Harness.expectEqual(changes.count, 1, "the recorded change was not noticed")
            Harness.expectEqual(changes.first?.id, .scanner)
            Harness.expectEqual(changes.first?.expected, entry.version)
            Harness.expectTrue(
                changes.first?.summary.contains(entry.version) == true,
                "the change does not say what it is changing to")

            try? Install.record(.scanner, entry)
            Harness.expectEqual(
                Oilbird.versionChanges().count, 0, "a matching record was read as a change")
        }

        Harness.test("the record is a manifest, readable by the loader that ships") {
            guard let manifest = try? Manifest.bundled(),
                let entry = try? manifest.entry(.postgres)
            else { return }
            defer { try? FileManager.default.removeItem(at: Paths.State.installedManifest) }
            try? Install.record(.postgres, entry)
            guard
                let data = FileManager.default.contents(
                    atPath: Paths.State.installedManifest.path)
            else {
                Harness.expectTrue(false, "the record could not be read back")
                return
            }
            let reread = try? Manifest.load(from: data)
            Harness.expectEqual(reread?.schema, Manifest.supportedSchema)
            Harness.expectEqual(reread?.dependencies["postgres"]?.sha256, entry.sha256)
        }
    }
}

func clusterCompatibilityTests() {
    Harness.suite("Cluster — a data directory outlives the server that wrote it") {
        // ⚠ `isInitialised()` checks PG_VERSION EXISTS and never reads it. With
        // no `pg_upgrade` in the artifact, a major bump reaches `pg_ctl` and
        // surfaces as "The database did not start." with Try again.
        Harness.test("the data directory's own version is read, not merely counted") {
            let data = Paths.State.clusterData
            defer { try? FileManager.default.removeItem(at: data) }
            try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try? Data("99\n".utf8).write(to: data.appending(path: "PG_VERSION"))
            Harness.expectEqual(Cluster.dataDirectoryMajor(), "99")
        }

        Harness.test("a cluster this PostgreSQL cannot read is named, not attempted") {
            guard let entry = try? Manifest.bundled().entry(.postgres) else { return }
            let data = Paths.State.clusterData
            defer { try? FileManager.default.removeItem(at: data) }
            try? FileManager.default.createDirectory(
                at: data.appending(path: "base"), withIntermediateDirectories: true)
            try? Data("99\n".utf8).write(to: data.appending(path: "PG_VERSION"))
            try? Data("".utf8).write(to: data.appending(path: "postgresql.conf"))

            let outcome = runSync(within: 30) { try await Cluster.start() }
            guard case .failure(let error) = outcome, let refusal = error as? OilbirdError else {
                Harness.expectTrue(false, "an unreadable cluster was started anyway")
                return
            }
            Harness.expectEqual(refusal.cause, .clusterCorrupt)
            Harness.expectTrue(
                refusal.detail.contains("99") && refusal.detail.contains(entry.major),
                "the refusal names neither version: \(refusal.detail)")
            // "Try again" on this can only ever produce this, for ever.
            if case .retry = refusal.recovery {
                Harness.expectTrue(false, "the recovery for an unreadable cluster is to retry")
            } else {
                Harness.expectNotEmpty(refusal.recovery.actionLabel)
            }
            Harness.expectTrue(
                FileManager.default.fileExists(atPath: data.appending(path: "base").path),
                "the refusal touched the data it refused to read")
        }

        Harness.test("a cluster written by the pinned major is not refused") {
            guard let entry = try? Manifest.bundled().entry(.postgres) else { return }
            let data = Paths.State.clusterData
            defer { try? FileManager.default.removeItem(at: data) }
            try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try? Data("\(entry.major)\n".utf8).write(to: data.appending(path: "PG_VERSION"))

            // No PostgreSQL is installed in the sandbox, so the start gets no
            // further than that — which is the point: it is a DIFFERENT
            // refusal, and the compatible cluster was never the objection.
            let outcome = runSync(within: 30) { try await Cluster.start() }
            guard case .failure(let error) = outcome, let refusal = error as? OilbirdError else {
                Harness.expectTrue(false, "a cluster started with no PostgreSQL installed")
                return
            }
            Harness.expectTrue(
                !refusal.detail.contains("cannot read it"),
                "a compatible cluster was refused as incompatible")
        }
    }
}

/// Where a staged scanner install has to put its jar.
///
/// The stubs in the other suites named `sonar-scanner-cli-7.0.jar` — a
/// version string outside `manifest.json`, and one no release has ever
/// carried. It passed while `detect()` globbed; it cannot now, because that
/// glob is the defect. Asked of the manifest so a bump moves the fixture
/// with the pin instead of stranding it.
func pinnedScannerJar() -> URL {
    guard let version = try? Manifest.bundled().entry(.scanner).version else {
        return Paths.install(.scanner).appending(path: "lib/sonar-scanner-cli.jar")
    }
    return ScannerDependency().cliJar(version: version)
}

/// The same entry with a version nothing pins, for standing in as "what was
/// installed last time".
private func stale(_ entry: Manifest.Entry) -> Manifest.Entry {
    Manifest.Entry(
        version: "0.0.0-previous", release: entry.release, url: entry.url, bytes: entry.bytes,
        sha256: entry.sha256, archive: entry.archive, verify: entry.verify,
        licence: entry.licence)
}
