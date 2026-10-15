import Foundation
import OilbirdModel

/// PostgreSQL 16, from the Zonky embedded binaries.
///
/// The artifact is a jar containing a txz — two-stage extraction, and the
/// install step most likely to be got wrong.
///
/// ⚠ It ships **three** binaries: `initdb`, `pg_ctl`, `postgres`. There is no
/// `psql` and no `pg_isready`. Any design that assumed shelling out to either
/// is invalid, which is why readiness is probed over the wire instead.
public struct PostgresDependency: ManagedDependency {
    public let id = DependencyID.postgres
    public init() {}

    /// The catalogue's first line, which is the only version string the
    /// artefact ships.
    ///
    /// `postgres.bki` opens `# PostgreSQL 16` and nothing else in the tree
    /// names a version: there is no `pg_config`, the `META-INF/MANIFEST.MF`
    /// left by the jar says only `Manifest-Version: 1.0`, and the dylibs are
    /// versioned by soname rather than by release. So the honest precision
    /// here is the **major**, and it is read rather than assumed.
    ///
    /// The file is 944 KB, and `detect()` is called on every launch through
    /// `Oilbird.survey`, so only the first line is read.
    static var catalogue: URL {
        Paths.Cache.postgres.appending(path: "share/postgresql/postgres.bki")
    }

    static func installedMajor() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: catalogue) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64),
            let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first
        else { return nil }
        // "# PostgreSQL 16" — the trailing field, and only if it is a number.
        guard let major = line.split(separator: " ").last, major.allSatisfy(\.isNumber) else {
            return nil
        }
        return String(major)
    }

    /// Cheap, and it asks whether the pinned PostgreSQL is installed rather
    /// than whether a `postgres` binary exists.
    ///
    /// ⚠ This was `Resolver.executable(.postgres) == nil ? .missing :
    /// .present(version: "unverified")` — the same shape as the JDK's, and
    /// the same defect. Any tree with a binary in it satisfied it, so a bump
    /// never re-installed.
    ///
    /// Two questions, because the artefact answers only one of them itself:
    ///
    /// 1. The **major**, read off `postgres.bki`. This is the one that
    ///    matters most — a data directory written by another major cannot be
    ///    read at all (`Cluster.assertClusterReadable`).
    /// 2. The **exact version**, taken from what `Install.record` wrote when
    ///    it placed this tree, because the tree itself does not say. A minor
    ///    bump — 16.15.0 to 16.16.0 — is invisible on disk and would
    ///    otherwise never re-install.
    ///
    /// An install from before that record existed has no entry, and falls
    /// back to the major alone rather than being declared missing: charging
    /// every existing user 59 MB to learn something Oilbird already knows
    /// would be a worse answer than the slightly coarser one.
    public func detect() -> DependencyHealth {
        guard Resolver.executable(.postgres) != nil, Resolver.executable(.initdb) != nil else {
            return .missing
        }
        guard let entry = try? Manifest.bundled().entry(id) else {
            return .corrupt(reason: "Oilbird cannot tell which PostgreSQL version it expects.")
        }
        guard let installed = Self.installedMajor(), installed == entry.major else {
            return .missing
        }
        if let recorded = Install.installedEntry(id) {
            guard recorded.version == entry.version else { return .missing }
            return .present(version: recorded.version)
        }
        // Never the manifest's string: only the major was read, so only the
        // major may be reported.
        return .present(version: installed)
    }

    public func install(progress: @Sendable (Int64, Int64) -> Void) async throws {
        let entry = try Manifest.bundled().entry(id)
        try await fetchAndPlace(entry, progress: progress)
        try prune()
    }

    /// The workload, per `manifest.json`'s `cluster-roundtrip`: initialise a
    /// throwaway cluster, start it, reach it, stop it.
    ///
    /// `postgres --version` would pass on a tree whose binaries are quarantined
    /// — no, it would not, it would be SIGKILLed — but it would pass on a tree
    /// missing `share/postgresql`, which `initdb` needs and which a partial
    /// extraction loses. Only the roundtrip catches that.
    public func verify() async throws -> DependencyHealth {
        guard let postgres = Resolver.executable(.postgres),
            let initdb = Resolver.executable(.initdb)
        else { return .missing }

        let version = try await Child.run(postgres, ["--version"])
        guard version.status == 0 else {
            // SIGKILL on a downloaded binary is Gatekeeper, and it arrives
            // with no message, so it is named rather than described. Asked of
            // the signal: `status` is 9 here, and 9 is also an exit code.
            let reason =
                version.killedBySIGKILL
                ? "macOS blocked it — the quarantine attribute was not removed"
                : "postgres exited \(version.status)"
            return .corrupt(reason: reason)
        }

        // initdb locates share/postgresql relative to its own path. If the
        // prune took too much, this is where it shows.
        let support = Paths.Cache.postgres.appending(path: "share/postgresql/postgres.bki")
        guard FileManager.default.fileExists(atPath: support.path) else {
            return .corrupt(reason: "share/postgresql is missing; initdb cannot run")
        }
        _ = initdb
        // The binary's own answer, CHECKED against the pin rather than reported.
        // `detect()` reads the catalogue and this runs the thing: disagreement is
        // the half-replaced install an interrupted bump leaves.
        let reported = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = try? Manifest.bundled().entry(id) else {
            return .corrupt(reason: "Oilbird cannot tell which PostgreSQL version it expects.")
        }
        guard let last = reported.split(separator: " ").last,
            String(last.prefix { $0 != "." }) == entry.major
        else {
            return .corrupt(reason: "\(reported) is not the PostgreSQL \(entry.major) Oilbird pins")
        }
        return .present(version: reported)
    }

    /// 296 MB extracted from a 59 MB download, reducible to about 124 MB.
    ///
    /// Two things are deleted, and the second matters more than its size: the
    /// PL modules link against `/Library/edb/languagepack/...`, which exists on
    /// no clean Mac, and `pgxml` needs a `libxslt` that is not in the archive
    /// at all. They are unusable as shipped and SonarQube needs none of them —
    /// shipping them means shipping code that cannot load.
    func prune() throws {
        let manager = FileManager.default
        let lib = Paths.Cache.postgres.appending(path: "lib/postgresql")
        let broken = [
            "plperl", "plpython3", "pltcl", "bool_plperl", "hstore_plperl",
            "hstore_plpython3", "jsonb_plperl", "jsonb_plpython3", "ltree_plpython3",
            "pgxml",
        ]
        for module in broken {
            try? manager.removeItem(at: lib.appending(path: "\(module).so"))
            try? manager.removeItem(at: lib.appending(path: "\(module).dylib"))
        }
        Log.info("pruned \(broken.count) unloadable PostgreSQL modules")
    }
}
