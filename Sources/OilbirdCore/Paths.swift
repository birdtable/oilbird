import Foundation
import OilbirdModel

/// Every location Oilbird uses, named exactly once.
///
/// Never write a path literal anywhere else — a rename must be one edit, and
/// the `paths` check fails the build on a literal outside this file.
///
/// Three roots, told apart by **what losing them costs**. The split is why
/// "reclaim disk
/// space" can be offered at all: everything under `cache` is a download away
/// from being back, and nothing under it is.
///
/// `Oilbird.reclaim` refuses any path that is not under `cache`, so the
/// split is enforced rather than merely respected.
public enum Paths {
    // MARK: Roots

    /// Losing this loses every scan ever run. Never cleared to free space.
    public static var state: URL {
        library("Application Support/Oilbird")
    }

    /// Losing this costs a download. All four managed dependencies live here.
    public static var cache: URL {
        library("Caches/Oilbird")
    }

    /// Is this executable one Oilbird installed?
    ///
    /// The question `reapOrphans` has to answer before it signals anything.
    /// Everything Oilbird runs — the JVM, the scanner's JVM, PostgreSQL —
    /// lives under the cache root, because that is the whole point of having
    /// no `PATH` assumptions: Oilbird never reaches for a runtime it did not
    /// install. So a pid whose executable is outside the container is, by construction, not ours,
    /// and killing it is killing a stranger's work.
    ///
    /// Compared as resolved paths so a symlinked home or a `/private/var`
    /// versus `/var` difference cannot make ours look like somebody else's.
    public static func isInsideContainer(_ executable: String) -> Bool {
        let resolved = URL(filePath: executable).resolvingSymlinksInPath().path
        let roots = [cache, state].map { $0.resolvingSymlinksInPath().path }
        return roots.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
    }

    /// The user's own choices.
    public static var config: URL {
        library("Preferences/com.birdtable.oilbird.plist")
    }

    // MARK: State — irreplaceable

    public enum State {
        /// Our PostgreSQL cluster. Never a cluster Oilbird did not create.
        public static var clusterData: URL { Paths.state.appending(path: "postgres/data") }
        /// Mode 0600. The generated database password and analysis token.
        public static var credentials: URL { Paths.state.appending(path: "credentials.json") }
        /// What is actually installed, as opposed to what this build expects.
        public static var installedManifest: URL { Paths.state.appending(path: "manifest.json") }
        /// Pidfiles and the single-owner lock.
        public static var run: URL { Paths.state.appending(path: "run") }
        /// One directory per project: what its last scan did, and the log it
        /// streamed while doing it.
        ///
        /// Under `state` rather than `cache`, and the split is exactly the
        /// one this file opens with: a log nobody kept is not a download
        /// away from being back. "Did that finish?" has to survive
        /// `Oilbird.reclaim`.
        public static var scans: URL { Paths.state.appending(path: "scans") }
        public static var clusterLock: URL { run.appending(path: "cluster.lock") }
    }

    // MARK: Cache — rederivable

    public enum Cache {
        public static var jdk: URL { Paths.cache.appending(path: "jdk") }
        public static var postgres: URL { Paths.cache.appending(path: "postgres") }
        public static var sonarqube: URL { Paths.cache.appending(path: "sonarqube") }
        public static var scanner: URL { Paths.cache.appending(path: "sonar-scanner") }
        /// Resumable downloads, keyed by digest.
        public static var partials: URL { Paths.cache.appending(path: "partials") }
        public static var logs: URL { Paths.cache.appending(path: "logs") }
        /// SonarQube's scratch space. Rederivable, so it belongs here.
        public static var temp: URL { Paths.cache.appending(path: "temp") }
        /// Somewhere to build a throwaway fixture or a half-finished install.
        /// Named here so nothing has to place one beside a real install
        /// directory and hope the difference is obvious.
        public static var scratch: URL { Paths.cache.appending(path: "scratch") }

        /// What the scanner treats as its home — its plugin cache, and where
        /// it would put a JRE if it ever provisioned one.
        ///
        /// It defaults to `~/.sonar`, outside everything Oilbird owns: a
        /// single scan can leave **~300 MB** there, including a
        /// second JRE of a different version from the pinned one. Left there,
        /// `Oilbird.diskReport` could not see it and uninstalling would not
        /// remove it — it is counted under "Scanner" because of this line.
        public static var scannerHome: URL { Paths.cache.appending(path: "scanner-home") }

        /// Where the scanner keeps its per-analysis working files.
        ///
        /// It defaults to `.scannerwork` **inside the directory being
        /// analysed** — so Oilbird wrote into the user's repository, which
        /// `Scan` promised in a comment that it never does. Verified: it left
        /// `scripts/.scannerwork/` in Oilbird's own untracked working tree.
        public static var scannerWork: URL { Paths.cache.appending(path: "scanner-work") }
        /// SonarQube's own data — its Elasticsearch index, which it rebuilds.
        public static var sonarData: URL { Paths.cache.appending(path: "sonar-data") }
        public static var log: URL { logs.appending(path: "oilbird.log") }
    }

    // MARK: Elsewhere, and why

    /// PostgreSQL's unix socket directory.
    ///
    /// **Deliberately not under the container.** `sun_path` is 104 bytes and
    /// `~/Library/Application Support/Oilbird/run/.s.PGSQL.<port>` is already
    /// close to it before a long user name is added — verified while probing
    /// the artifact, where a 127-character path failed outright. This bites
    /// only some users, which is what makes it dangerous.
    public static var postgresSocketDirectory: URL {
        URL(filePath: "/tmp/oilbird-\(shortUserToken)")
    }

    /// The install directory for a managed dependency. Always under `cache`:
    /// a dependency written to `state` would make `Oilbird.reclaim`
    /// destructive, and that function will not delete outside this root.
    public static func install(_ dependency: DependencyID) -> URL {
        switch dependency {
        case .sonarqube: Cache.sonarqube
        case .jdk: Cache.jdk
        case .postgres: Cache.postgres
        case .scanner: Cache.scanner
        }
    }

    // MARK: -

    /// Relocates the whole container. Set by the clean-machine gate and by
    /// the test harness.
    ///
    /// ⚠ This exists because **relocating `HOME` does not work on macOS**:
    /// `FileManager.homeDirectoryForCurrentUser` reads `getpwuid`, not the
    /// environment, so `env HOME=/tmp/...` leaves every path pointing at the
    /// real container. An `L1` run that
    /// relied on `HOME` alone would silently read and write the user's actual
    /// installation while believing it was sandboxed — which is worse than not
    /// sandboxing, because it looks isolated.
    public static let containerRootVariable = "OILBIRD_HOME"

    private static func library(_ suffix: String) -> URL {
        if let override = ProcessInfo.processInfo.environment[containerRootVariable],
            !override.isEmpty
        {
            return URL(filePath: override).appending(path: "Library/\(suffix)")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/\(suffix)")
    }

    /// Short and stable, so the socket path stays inside `sun_path`.
    private static var shortUserToken: String {
        let name = NSUserName()
        return name.count <= 8 ? name : String(name.prefix(8))
    }
}
