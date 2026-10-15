import Foundation
import OilbirdModel

/// The only thing permitted to produce an executable path, and the only place
/// a child environment is built.
///
/// Nothing is ever launched by bare name. A GUI app launched from Finder
/// inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, not the login shell's — so
/// code that works in a terminal fails silently when the same app is
/// double-clicked. It is the highest-frequency latent defect in this class of
/// app and it is invisible during development.
public enum Resolver {
    /// A managed executable, or `nil` when it is not installed.
    ///
    /// Never falls back to something on the user's `PATH`. A Homebrew `initdb`
    /// would work on a developer machine and be absent on a user's — touching
    /// the user's own dependencies and the hidden clean-machine breakage are the same bug.
    public static func executable(_ tool: Tool) -> URL? {
        let url = tool.url
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The analysis engine, taken from the SonarQube install Oilbird already
    /// has.
    ///
    /// The scanner CLI is a bootstrapper: unaided it asks the server for the
    /// engine over `api/v2/analysis/engine` and caches a second 50 MB copy of
    /// a jar that is already on this disk, inside the server we downloaded and
    /// checksummed. Pointing it at ours removes a download, a cache and an
    /// endpoint from the path.
    ///
    /// Globbed rather than named, because the engine's version tracks the
    /// server's and not the scanner's — hardcoding it would break on the next
    /// SonarQube bump in a way nothing would catch until a scan ran. Exactly
    /// one match is required: two would mean a half-replaced install, and
    /// picking either would be a guess.
    ///
    /// Deliberately NOT re-hashed. It arrived inside an archive whose SHA-256
    /// was verified before anything was extracted, so a digest here would
    /// protect against nothing the container does not already protect
    /// against, and would add a constant needing an update on every server
    /// bump — a maintenance trap that buys no safety.
    public static func scannerEngine() -> URL? {
        let directory = Paths.Cache.sonarqube.appending(path: "lib/scanner")
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let engines = names.filter {
            $0.hasPrefix("sonar-scanner-engine") && $0.hasSuffix(".jar")
        }
        guard engines.count == 1, let only = engines.first else { return nil }
        return directory.appending(path: only)
    }

    /// The scanner CLI's own jar, launched directly rather than through
    /// `bin/sonar-scanner`.
    ///
    /// The wrapper script falls back to `command -v java` when `JAVA_HOME` is
    /// unset — a `PATH` lookup for a runtime, one unset variable away from the
    /// bare-name launch the product exists to prevent. Running the jar on our
    /// own JDK's classpath removes the shell script from the path entirely.
    public static func scannerJar() -> URL? {
        let directory = Paths.Cache.scanner.appending(path: "lib")
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let jars = names.filter {
            $0.hasPrefix("sonar-scanner-cli") && $0.hasSuffix(".jar")
        }
        guard jars.count == 1, let only = jars.first else { return nil }
        return directory.appending(path: only)
    }

    public enum Tool: Sendable {
        case java
        case postgres
        case initdb
        case pgCtl
        case scanner

        var url: URL {
            switch self {
            case .java: Paths.Cache.jdk.appending(path: "Contents/Home/bin/java")
            case .postgres: Paths.Cache.postgres.appending(path: "bin/postgres")
            case .initdb: Paths.Cache.postgres.appending(path: "bin/initdb")
            case .pgCtl: Paths.Cache.postgres.appending(path: "bin/pg_ctl")
            // Kept because it still ships and `Paths` maps the dependency to
            // it, but Oilbird does not launch it: the wrapper falls back to
            // `command -v java`. Use `scannerJar()`.
            case .scanner: Paths.Cache.scanner.appending(path: "bin/sonar-scanner")
            }
        }
    }

    /// A child's environment, **constructed rather than inherited**.
    ///
    /// Absolute paths do not protect against an inherited `PGDATA` pointing at
    /// the user's own cluster, so every `PG*` variable is cleared rather than
    /// passed through. `JAVA_HOME` is never set: SonarQube derives the java
    /// binary for all four of its JVMs from the parent's `java.home`, so
    /// exec'ing our JDK by absolute path is enough.
    public static func childEnvironment(adding extras: [String: String] = [:]) -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp",
        ]
        for (key, value) in extras { environment[key] = value }
        return environment
    }

    /// Variables that must never reach a child, because they silently redirect
    /// it at the user's own installation.
    public static let forbiddenInherited = [
        "PGDATA", "PGPORT", "PGHOST", "PGUSER", "PGDATABASE", "JAVA_HOME",
    ]
}
