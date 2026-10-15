import Foundation
import OilbirdCore
import OilbirdModel

func pathsTests() {
    Harness.suite("Paths — three roots, told apart by what losing them costs") {
        Harness.test("state, cache and config are genuinely different places") {
            Harness.expectTrue(Paths.state != Paths.cache)
            Harness.expectTrue(Paths.state.path != Paths.cache.path)
            Harness.expectTrue(Paths.config.path.hasSuffix(".plist"))
        }

        Harness.test("every managed dependency installs under cache, never state") {
            for dependency in DependencyID.allCases {
                let install = Paths.install(dependency).path
                Harness.expectTrue(
                    install.hasPrefix(Paths.cache.path), "\(dependency) escaped the cache root")
                Harness.expectTrue(
                    !install.hasPrefix(Paths.state.path), "\(dependency) landed in state")
            }
        }

        Harness.test("the cluster and credentials live in state, never cache") {
            Harness.expectTrue(Paths.State.clusterData.path.hasPrefix(Paths.state.path))
            Harness.expectTrue(Paths.State.credentials.path.hasPrefix(Paths.state.path))
            Harness.expectTrue(!Paths.State.clusterData.path.hasPrefix(Paths.cache.path))
        }

        Harness.test("the log is rederivable, so it lives in cache") {
            Harness.expectTrue(Paths.Cache.log.path.hasPrefix(Paths.cache.path))
        }

        // sun_path is 104 bytes. The container path is already close to it
        // before a long user name is added, which is why the socket is not
        // beside the data directory.
        Harness.test("the postgres socket path stays inside sun_path") {
            let socket = Paths.postgresSocketDirectory.appending(path: ".s.PGSQL.54321").path
            Harness.expectTrue(socket.utf8.count < 104, "socket path is \(socket.utf8.count) bytes")
        }

        // If this regresses, every suite silently starts reading and writing
        // the developer's real installation -- which is how one run changed
        // the next one's assertion count before the override existed.
        Harness.test("the container is relocated by OILBIRD_HOME, not by HOME") {
            let override = ProcessInfo.processInfo.environment[Paths.containerRootVariable]
            Harness.expectTrue(override != nil, "the suites are not sandboxed")
            Harness.expectTrue(
                Paths.cache.path.hasPrefix(override ?? "/nope"),
                "cache escaped the sandbox: \(Paths.cache.path)")
            Harness.expectTrue(
                Paths.state.path.hasPrefix(override ?? "/nope"),
                "state escaped the sandbox: \(Paths.state.path)")
        }

        // Relocating HOME is NOT sufficient: homeDirectoryForCurrentUser reads
        // getpwuid and ignores the environment on macOS.
        Harness.test("HOME alone would not have relocated anything") {
            let real = FileManager.default.homeDirectoryForCurrentUser.path
            setenv("HOME", "/tmp/oilbird-not-a-home", 1)
            Harness.expectEqual(
                FileManager.default.homeDirectoryForCurrentUser.path, real,
                "HOME now works, and the sandbox rationale needs revisiting")
        }

        Harness.test("the socket is deliberately not under the container") {
            Harness.expectTrue(!Paths.postgresSocketDirectory.path.hasPrefix(Paths.state.path))
        }
    }
}
