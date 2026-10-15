import Foundation
import OilbirdModel

/// The pinned version, origin, size and digest of every managed dependency.
///
/// One home for every version string — a version anywhere else is not
/// allowed. Ships in the bundle; each entry is written
/// into `Paths.State.installedManifest` as it is installed, by
/// `Install.record`, so an installed Oilbird records what it *installed*
/// rather than what this build expects. That is what makes a downgrade
/// diagnosable.
public struct Manifest: Sendable, Codable {
    /// Bumped only for a breaking change. A build reading a schema it does not
    /// know refuses rather than guessing — a half-understood manifest could
    /// install the wrong artefact.
    public static let supportedSchema = 1

    public let schema: Int
    public let dependencies: [String: Entry]

    public init(schema: Int, dependencies: [String: Entry]) {
        self.schema = schema
        self.dependencies = dependencies
    }

    public struct Entry: Sendable, Codable {
        public let version: String
        /// Adoptium returns both a semver (`21.0.12+101.0.LTS`) and a release
        /// tag (`jdk-21.0.12.1+1`) for one build. Recording only one makes the
        /// other read as a typo in the URL.
        public let release: String?
        public let url: String
        public let bytes: Int64
        public let sha256: String
        public let archive: Archive
        public let verify: Verify
        public let licence: String

        public init(
            version: String, release: String?, url: String, bytes: Int64, sha256: String,
            archive: Archive, verify: Verify, licence: String
        ) {
            self.version = version
            self.release = release
            self.url = url
            self.bytes = bytes
            self.sha256 = sha256
            self.archive = archive
            self.verify = verify
            self.licence = licence
        }

        /// The leading component of `version`.
        ///
        /// PostgreSQL's data-directory compatibility is decided by exactly
        /// this and nothing finer, and `PG_VERSION` holds exactly this — so
        /// it is the only comparison that can be made between what is
        /// installed and what wrote the cluster (`Cluster.dataDirectoryMajor`).
        public var major: String { String(version.prefix { $0 != "." }) }

        /// What this build pins, as the artefact's own publisher names it.
        ///
        /// For the JDK that is the release tag, because the release tag is
        /// what Adoptium writes into `Contents/Home/release` — the semver in
        /// `version` appears nowhere on disk, so comparing against it could
        /// only ever fail. Everything else has one identifier and uses it.
        public var pinnedIdentifier: String {
            guard let release else { return version }
            return release.hasPrefix("jdk-") ? String(release.dropFirst(4)) : release
        }
    }

    public enum Archive: String, Sendable, Codable {
        case zip
        case tarGz = "tar.gz"
        /// A jar containing a txz. Two-stage, and the install step most likely
        /// to be got wrong — naming it makes that explicit rather than
        /// incidental.
        case jarTxz = "jar+txz"
    }

    /// A *kind*, never a command: each names a workload rather than a version
    /// flag. This is the rule the JRE mistake produced — the bundled JRE
    /// printed a perfectly good `java -version` and could not boot the server.
    public enum Verify: String, Sendable, Codable {
        case serverUp = "server-up"
        case clusterRoundtrip = "cluster-roundtrip"
        case scanFixture = "scan-fixture"
    }

    public func entry(_ id: DependencyID) throws -> Entry {
        guard let entry = dependencies[id.rawValue] else {
            throw OilbirdError(
                .verifyFailed,
                "The dependency manifest has no entry for \(id.rawValue).",
                recovery: .reportIssue("Report an issue"),
                underlying: "manifest lists: \(dependencies.keys.sorted().joined(separator: ", "))")
        }
        return entry
    }

    public static func load(from data: Data) throws -> Manifest {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw OilbirdError(
                .verifyFailed,
                "The dependency manifest could not be read.",
                recovery: .reportIssue("Report an issue"),
                underlying: String(describing: error))
        }
        guard manifest.schema == supportedSchema else {
            throw OilbirdError(
                .verifyFailed,
                "This copy of Oilbird cannot read its own dependency list.",
                recovery: .reportIssue("Report an issue"),
                underlying: "manifest schema \(manifest.schema), supported \(supportedSchema)")
        }
        return manifest
    }
}

extension Manifest {
    /// The manifest shipped with this build.
    public static func bundled() throws -> Manifest {
        guard let url = Bundled.url(named: "manifest", extension: "json") else {
            throw OilbirdError(
                .verifyFailed,
                "This copy of Oilbird is missing its dependency list.",
                recovery: .reportIssue("Report an issue"),
                underlying: "manifest.json absent from the shipped resources")
        }
        return try load(from: Data(contentsOf: url))
    }
}
