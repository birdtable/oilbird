import Foundation
import OilbirdCore

func resolverTests() {
    Harness.suite("Resolver — no PATH assumptions, and environments built not inherited") {
        Harness.test("a child environment carries no PG* or JAVA_HOME") {
            let environment = Resolver.childEnvironment()
            for forbidden in Resolver.forbiddenInherited {
                Harness.expectNil(environment[forbidden], "\(forbidden) leaked into the child")
            }
        }

        // Absolute paths do not protect against an inherited PGDATA: the
        // binary is ours, the cluster it opens would be the user's.
        Harness.test("PGDATA in our own environment does not reach a child") {
            setenv("PGDATA", "/opt/homebrew/var/postgresql@16", 1)
            defer { unsetenv("PGDATA") }
            Harness.expectNil(Resolver.childEnvironment()["PGDATA"])
        }

        Harness.test("a child PATH is the Finder-inherited minimum, not the login shell's") {
            let path = Resolver.childEnvironment()["PATH"] ?? ""
            Harness.expectTrue(!path.contains("homebrew"), "Homebrew reached the child PATH")
            Harness.expectTrue(path.contains("/usr/bin"))
        }

        Harness.test("nothing resolves before it is installed") {
            // On a machine where the cache is empty this is nil, and that is
            // the point: the resolver never falls back to the user's PATH.
            let java = Resolver.executable(.java)
            Harness.expectTrue(
                java?.path.contains("Oilbird") ?? true,
                "the resolver fell back to the user's PATH: \(java?.path ?? "nil")")
        }
    }
}
