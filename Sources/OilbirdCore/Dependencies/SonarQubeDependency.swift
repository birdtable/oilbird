import Foundation
import OilbirdModel

/// SonarQube Community Build.
///
/// Launched by its jar, never by `bin/macosx-universal-64/sonar.sh`: that
/// script writes its pidfile into the install directory and depends on
/// relative paths, and it adds nothing — its own command line is the
/// `java -jar` issued here.
public struct SonarQubeDependency: ManagedDependency {
    public let id = DependencyID.sonarqube
    public init() {}

    /// The application jar carries the version in its name. `lib/sonarqube.jar`
    /// does NOT exist in the distribution — it is a symlink the Dockerfile
    /// creates — so the versioned name is the only one to reference.
    public func applicationJar(version: String) -> URL {
        Paths.Cache.sonarqube.appending(path: "lib/sonar-application-\(version).jar")
    }

    /// The pattern the other three now follow: ask whether the jar *this
    /// build pins* is on disk, not whether some jar is.
    ///
    /// The version is reported rather than `"unverified"` because the
    /// filename is where it was read from — a jar named for another release
    /// answers `.missing` here, so a version that comes back is one that was
    /// found. It is still the weak claim: `verify()` is what says it runs.
    public func detect() -> DependencyHealth {
        guard let version = try? Manifest.bundled().entry(id).version else { return .missing }
        let jar = applicationJar(version: version)
        return FileManager.default.fileExists(atPath: jar.path)
            ? .present(version: version) : .missing
    }

    public func install(progress: @Sendable (Int64, Int64) -> Void) async throws {
        let entry = try Manifest.bundled().entry(id)
        try await fetchAndPlace(entry, progress: progress)
    }

    /// The workload, per `manifest.json`'s `server-up`: the server is started
    /// and polled until `/api/system/status` reports `UP`.
    ///
    /// ⚠ Starting it needs a configured database, so the full boot lives in
    /// `Supervise`. What is verified here is everything that can be
    /// checked without one — that the distribution is the version claimed and
    /// structurally complete.
    public func verify() async throws -> DependencyHealth {
        let entry = try Manifest.bundled().entry(id)
        let jar = applicationJar(version: entry.version)
        guard FileManager.default.fileExists(atPath: jar.path) else { return .missing }

        // Elasticsearch ships inside the distribution and is started as a child
        // of the server. A distribution missing it will fail at boot with an
        // error that says nothing about the download.
        let elasticsearch = Paths.Cache.sonarqube.appending(path: "elasticsearch")
        guard FileManager.default.fileExists(atPath: elasticsearch.path) else {
            return .corrupt(reason: "the distribution has no bundled Elasticsearch")
        }
        // conf/ must be writable: SonarQube has no --config flag, so
        // sonar.properties is written into the install directory.
        let conf = Paths.Cache.sonarqube.appending(path: "conf/sonar.properties")
        guard FileManager.default.isWritableFile(atPath: conf.path) else {
            return .corrupt(reason: "conf/sonar.properties is not writable")
        }
        return .present(version: entry.version)
    }

    /// Elasticsearch's bootstrap checks are force-enabled whenever the JDBC URL
    /// is not H2 — so using PostgreSQL turns them on. On macOS the check that
    /// bites is the file-descriptor one.
    ///
    /// `vm.max_map_count` is Linux-only, confirmed at the bytecode level; it
    /// does not apply here and must not be "fixed".
    public static func fileDescriptorLimit() -> (soft: UInt64, hard: UInt64) {
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        return (limit.rlim_cur, limit.rlim_max)
    }

    /// Elasticsearch refuses to start below this. It is the HARD limit that
    /// matters — HotSpot raises soft to hard at JVM init, so a low soft limit
    /// starts fine and a low hard limit fails with exit 78.
    public static let requiredFileDescriptors: UInt64 = 10240
}
