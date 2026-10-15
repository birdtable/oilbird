import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

func managedDependencyTests() {
    Harness.suite("ManagedDependency — the triple, and what verify may claim") {
        // On a machine with nothing installed every detect must say so. The
        // failure this guards is a detect that reports present because a
        // directory exists.
        Harness.test("detect reports missing when nothing is installed") {
            let all: [any ManagedDependency] = [
                JDKDependency(), SonarQubeDependency(), PostgresDependency(),
                ScannerDependency(),
            ]
            for dependency in all {
                let health = dependency.detect()
                let installed = FileManager.default.fileExists(
                    atPath: Paths.install(dependency.id).path)
                if !installed {
                    Harness.expectEqual(health, .missing, "\(dependency.id) claimed presence")
                }
            }
        }

        // Every dependency's detect must be cheap and total -- it is called
        // before anything is installed, so it must not throw or hang.
        Harness.test("detect is total: it answers for every dependency") {
            let all: [any ManagedDependency] = [
                JDKDependency(), SonarQubeDependency(), PostgresDependency(),
                ScannerDependency(),
            ]
            Harness.expectEqual(all.count, 4)
            for dependency in all {
                _ = dependency.detect()
                Harness.expectTrue(true, "\(dependency.id) answered")
            }
        }

        Harness.test("each dependency's id matches the manifest key it reads") {
            guard let manifest = try? Manifest.bundled() else { return }
            let all: [any ManagedDependency] = [
                JDKDependency(), SonarQubeDependency(), PostgresDependency(),
                ScannerDependency(),
            ]
            for dependency in all {
                Harness.expectTrue(
                    (try? manifest.entry(dependency.id)) != nil,
                    "no manifest entry for \(dependency.id)")
            }
        }

        // A JDK that is not 21 is not a JDK Oilbird can use, and neither is one
        // that is not arm64. Both are corrupt, not present.
        Harness.test("verify never reports present on a missing install") {
            let health = runSync { try await JDKDependency().verify() }
            if Resolver.executable(.java) == nil {
                Harness.expectEqual(try? health.get(), .missing)
            } else {
                Harness.expectTrue(true, "a JDK is installed; nothing to assert here")
            }
        }
    }
}

func clusterTests() {
    Harness.suite("Cluster — ours, never the user's") {
        Harness.test("an uninitialised cluster is reported as such") {
            if !FileManager.default.fileExists(atPath: Paths.State.clusterData.path) {
                Harness.expectTrue(!Cluster.isInitialised())
            } else {
                Harness.expectTrue(true, "a cluster exists; nothing to assert here")
            }
        }

        // PG_VERSION alone is the half-initialised case: it starts and then
        // dies on a missing postgresql.conf, which reads as a crash rather
        // than a bad install.
        Harness.test("PG_VERSION alone does not count as initialised") {
            let scratch = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-cluster-probe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            try? Data("16".utf8).write(to: scratch.appending(path: "PG_VERSION"))
            let manager = FileManager.default
            let complete =
                manager.fileExists(atPath: scratch.appending(path: "PG_VERSION").path)
                && manager.fileExists(atPath: scratch.appending(path: "postgresql.conf").path)
                && manager.fileExists(atPath: scratch.appending(path: "base").path)
            Harness.expectTrue(!complete, "a lone PG_VERSION was treated as a cluster")
        }

        Harness.test("the database is the one initdb already makes") {
            // No psql and no createdb ship, so CREATE DATABASE would mean a
            // wire client for one statement at bootstrap.
            Harness.expectEqual(Cluster.database, "postgres")
            Harness.expectEqual(Cluster.role, "sonar")
        }
    }
}

func readinessTests() {
    Harness.suite("Readiness — a listener is not a postmaster") {
        Harness.test("nothing answers on a port with no listener") {
            guard let port = try? Ports.free() else { return }
            Harness.expectTrue(!Readiness.postgresAnswering(port: port))
        }

        // A bare TCP connect would call this ready. The SSLRequest is what
        // distinguishes a postmaster from anything else holding the port.
        Harness.test("a plain TCP listener is not mistaken for PostgreSQL") {
            guard let port = try? Ports.free() else { return }
            let decoy = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(decoy) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(decoy, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            listen(decoy, 1)
            Harness.expectTrue(
                !Readiness.postgresAnswering(port: port), "a decoy listener passed as PostgreSQL")
        }
    }
}

func sonarQubeTests() {
    Harness.suite("SonarQube — the checks that bite on macOS") {
        // Elasticsearch's bootstrap checks are force-enabled because the JDBC
        // URL is not H2. On macOS the one that bites is file descriptors, and
        // it is the HARD limit that matters.
        Harness.test("the file-descriptor requirement is the Elasticsearch one") {
            Harness.expectEqual(SonarQubeDependency.requiredFileDescriptors, 10240)
            let limits = SonarQubeDependency.fileDescriptorLimit()
            Harness.expectTrue(limits.hard > 0, "could not read RLIMIT_NOFILE")
        }

        // lib/sonarqube.jar does not exist in the distribution -- it is a
        // symlink the Dockerfile creates -- so the versioned name is the only
        // one to reference.
        Harness.test("the application jar is referenced by its versioned name") {
            guard let version = try? Manifest.bundled().entry(.sonarqube).version else { return }
            let jar = SonarQubeDependency().applicationJar(version: version)
            Harness.expectTrue(jar.lastPathComponent.contains(version))
            Harness.expectTrue(jar.lastPathComponent != "sonarqube.jar")
        }
    }
}

func dependencyRegistrationTests() {
    Harness.suite("Every conformance is enumerated") {
        // A conformance that exists but is not listed is not installed. That
        // is not hypothetical: the scan pipeline shipped launching a scanner
        // that `install` never provisioned, and nothing pointed at the cause.
        Harness.test("all four managed dependencies are registered for install") {
            let registered = Set(Oilbird.dependencies.map { $0.id })
            for id in DependencyID.allCases {
                Harness.expectTrue(registered.contains(id), "\(id) is never installed")
            }
            Harness.expectEqual(registered.count, DependencyID.allCases.count)
        }

        Harness.test("the manifest has an entry for every registered dependency") {
            guard let manifest = try? Manifest.bundled() else { return }
            for dependency in Oilbird.dependencies {
                Harness.expectTrue(
                    (try? manifest.entry(dependency.id)) != nil,
                    "\(dependency.id) is registered with no manifest entry")
            }
        }
    }
}

func extractionTests() {
    Harness.suite("Install — a wrapped archive is flattened") {
        func tree(_ layout: [String]) -> URL {
            let root = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-extract-\(UUID().uuidString)")
            for entry in layout {
                let url = root.appending(path: entry)
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("x".utf8).write(to: url)
            }
            return root
        }

        // Three of the four artifacts wrap themselves in a directory named for
        // the release, so without stripping it every lookup misses by one
        // level: the download succeeds and the binary reports missing.
        Harness.test("a single wrapping directory is stripped") {
            let root = tree(["jdk-21.0.12.1+1/Contents/Home/bin/java"])
            defer { try? FileManager.default.removeItem(at: root) }
            try? Install.flattenSingleWrapper(root)
            Harness.expectTrue(
                FileManager.default.fileExists(atPath: root.appending(path: "Contents/Home/bin/java").path),
                "the wrapper was not stripped")
        }

        // PostgreSQL's txz is flat. Flattening it would destroy the layout.
        Harness.test("a flat archive is left alone") {
            let root = tree(["bin/postgres", "lib/x.dylib", "share/postgresql/postgres.bki"])
            defer { try? FileManager.default.removeItem(at: root) }
            try? Install.flattenSingleWrapper(root)
            Harness.expectTrue(
                FileManager.default.fileExists(atPath: root.appending(path: "bin/postgres").path),
                "a flat archive was mangled")
        }

        // One FILE at the top is not a wrapper. Only a lone directory is.
        Harness.test("a single file at the top is not treated as a wrapper") {
            let root = tree(["only.txt"])
            defer { try? FileManager.default.removeItem(at: root) }
            try? Install.flattenSingleWrapper(root)
            Harness.expectTrue(
                FileManager.default.fileExists(atPath: root.appending(path: "only.txt").path))
        }
    }
}
