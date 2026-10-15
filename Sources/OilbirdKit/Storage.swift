import Foundation
import OilbirdCore
import OilbirdModel

/// What Oilbird has put on the disk, and which of it can go.
///
/// The split into two roots in `Paths.swift` is what lets reclaiming disk
/// space be offered at all, and a dependency is required to live under
/// `cache` because putting one under `state` would make reclaiming disk
/// space destructive.
///
/// The partials directory, keyed by digest so a changed artefact is a miss
/// rather than a silent overwrite, is pruned here too. Left alone it grows
/// past **1 GB** — a second complete copy of everything already installed,
/// plus every artefact any previous version of Oilbird had pinned.
///
/// Here rather than in the settings window because an executable target
/// cannot be `@testable import`-ed: the arithmetic and the "is this safe to
/// delete?" decision are the whole of this feature, and both belong where a
/// test can reach them.
extension Oilbird {
    /// One line of the disk breakdown.
    public struct DiskEntry: Sendable, Equatable {
        public let label: String
        /// What losing it would cost, in a sentence the window can show.
        public let cost: String
        public let bytes: Int64
        /// How much of `bytes` `reclaim()` would free, right now, in this
        /// state.
        ///
        /// ⚠ A count and not a flag. A row is often part dead weight and
        /// part live — the partials directory usually holds both — and a
        /// boolean forces that row to be reported as all of one or all of
        /// the other. The first version said "not reclaimable" for a
        /// directory `reclaim()` was about to take 900 MB out of.
        public let reclaimable: Int64

        public init(label: String, cost: String, bytes: Int64, reclaimable: Int64 = 0) {
            self.label = label
            self.cost = cost
            self.bytes = bytes
            self.reclaimable = reclaimable
        }
    }

    /// Where it all lives and what it costs.
    public struct DiskReport: Sendable, Equatable {
        /// Irreplaceable. Never cleared to free space.
        public let keep: [DiskEntry]
        /// Rederivable. Some of it is dead weight and some is not.
        public let cache: [DiskEntry]
        /// The two roots, for the rows that offer Reveal in Finder.
        public let stateRoot: String
        public let cacheRoot: String
        /// Set when `OILBIRD_HOME` has moved the container, because nothing
        /// else in the product says that it can be.
        public let relocatedTo: String?

        public var total: Int64 { (keep + cache).reduce(0) { $0 + $1.bytes } }
        public var reclaimable: Int64 { (keep + cache).reduce(0) { $0 + $1.reclaimable } }
    }

    /// Everything Oilbird occupies, measured now.
    ///
    /// Walked rather than cached: a number that is a minute old is the
    /// number a person will act on, and the walk costs milliseconds against
    /// a directory tree the OS has in its cache anyway.
    public static func diskReport() -> DiskReport {
        let running = status() != nil
        let dead = supersededPartials()
        let deadBytes = dead.reduce(0) { $0 + fileBytes(at: $1) }
        let partialsTotal = directoryBytes(at: Paths.Cache.partials)
        let scratch = directoryBytes(at: Paths.Cache.temp)

        return DiskReport(
            keep: [
                DiskEntry(
                    label: "Analysis history",
                    cost: "Every scan ever run. A download cannot bring it back.",
                    bytes: directoryBytes(at: Paths.State.clusterData))
            ],
            cache: [
                DiskEntry(
                    label: "SonarQube",
                    cost: "The analysis server itself.",
                    bytes: directoryBytes(at: Paths.Cache.sonarqube)),
                DiskEntry(
                    label: "Java",
                    cost: "The runtime the server and the scanner both use.",
                    bytes: directoryBytes(at: Paths.Cache.jdk)),
                DiskEntry(
                    label: "PostgreSQL",
                    cost: "The database programs, not the data.",
                    bytes: directoryBytes(at: Paths.Cache.postgres)),
                DiskEntry(
                    label: "Scanner",
                    cost: "What analyses a project, and its plugin cache.",
                    bytes: directoryBytes(at: Paths.Cache.scanner)
                        + directoryBytes(at: Paths.Cache.scannerHome)
                        + directoryBytes(at: Paths.Cache.scannerWork)),
                DiskEntry(
                    label: "Search index",
                    cost: "Rebuilt by the server on demand.",
                    bytes: directoryBytes(at: Paths.Cache.sonarData)),
                DiskEntry(
                    // Named for what it is to the user, not for the
                    // directory: "partials" is Oilbird's word.
                    label: "Downloaded installers",
                    cost: deadBytes == 0
                        ? "Kept so an interrupted download can resume."
                        : "Already unpacked, or pinned by a version of Oilbird "
                            + "that is no longer this one.",
                    bytes: partialsTotal,
                    reclaimable: deadBytes),
                DiskEntry(
                    label: "Server scratch",
                    cost: running
                        ? "In use by the running server."
                        : "Working files the server makes again as it needs them.",
                    bytes: scratch,
                    reclaimable: running ? 0 : scratch),
                DiskEntry(
                    label: "Logs",
                    cost: "What a bug report is written from. Kept.",
                    bytes: directoryBytes(at: Paths.Cache.logs)),
            ],
            stateRoot: Paths.state.path,
            cacheRoot: Paths.cache.path,
            relocatedTo: ProcessInfo.processInfo.environment[Paths.containerRootVariable])
    }

    /// Deletes what the report said was reclaimable, and returns the bytes.
    ///
    /// ⚠ **It touches nothing under the state root, and that is checked
    /// rather than intended.** `Paths.isInsideContainer` already exists to
    /// answer "is this ours?" for `reapOrphans`; the question here is
    /// narrower — is this under the CACHE root — and it is asked of every
    /// path immediately before the delete, because the whole justification
    /// for two roots is that this function cannot reach the analysis
    /// history.
    ///
    /// The server's scratch is skipped while the engine is running rather
    /// than refused: reclaiming 1.1 GB of dead downloads is still worth
    /// doing, and a button that fails outright because one of five things
    /// is busy is a dead end.
    @discardableResult
    public static func reclaim() throws -> Int64 {
        var freed: Int64 = 0
        var targets = supersededPartials()
        if status() == nil { targets.append(Paths.Cache.temp) }

        for target in targets {
            guard isUnderCacheRoot(target) else {
                // Not a warning to be swallowed: reaching here means the
                // path arithmetic above produced something outside the one
                // tree this function is allowed to delete from.
                throw OilbirdError(
                    .verifyFailed,
                    "Oilbird refused to delete something outside its cache.",
                    recovery: .reportIssue("Report this"),
                    underlying: "\(target.path) is not under \(Paths.cache.path)")
            }
            let bytes = directoryBytes(at: target) + fileBytes(at: target)
            do {
                try FileManager.default.removeItem(at: target)
                freed += bytes
            } catch CocoaError.fileNoSuchFile {
                // Raced with an install placing or pruning the same file.
                // Nothing was freed and nothing is wrong.
                continue
            }
        }
        Log.info("reclaimed \(humanBytes(freed))")
        return freed
    }

    /// Partial downloads with nothing left to resume.
    ///
    /// **A file survives only if it is INCOMPLETE and still pinned.** That
    /// is the entire purpose of this directory: `Fetch` resumes with a
    /// `Range` header from wherever a download stopped, so a file shorter
    /// than the size the manifest records is somebody's interrupted first
    /// run and must be left alone. A file at its full size has nothing to
    /// resume — it is either already unpacked, or one `Install` call from
    /// being so — and its bytes are a second copy of something the cache
    /// root promises can be fetched again.
    ///
    /// "Is this dependency installed?" is the wrong question.
    /// `Install.installedEntry` reads a record Oilbird writes as it places
    /// an artefact, and an install provisioned before that record existed
    /// has none. Asked that way, every digest looks resumable and the
    /// Storage pane says "Nothing to reclaim" over a gigabyte of finished
    /// installers. Size against the manifest needs no record and
    /// cannot be wrong about this: it is the same number `Fetch` itself
    /// compares before deciding to resume.
    ///
    /// A manifest that will not load returns nothing at all. Deleting on
    /// the strength of a list that could not be read is how a "clean up"
    /// button removes the download somebody is halfway through.
    public static func supersededPartials() -> [URL] {
        guard let manifest = try? Manifest.bundled() else { return [] }
        var pinned: [String: Int64] = [:]
        for id in DependencyID.allCases {
            guard let entry = try? manifest.entry(id) else { continue }
            pinned[entry.sha256] = entry.bytes
        }
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: Paths.Cache.partials, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { file in
            // A digest this build does not pin can never be resumed into
            // anything it wants, at any size.
            guard let expected = pinned[file.lastPathComponent] else { return true }
            return fileBytes(at: file) >= expected
        }
    }

    /// Is this path inside the cache root — the only tree `reclaim` may
    /// delete from?
    ///
    /// Resolved on both sides, so a symlinked home or `/private/var` against
    /// `/var` cannot make the answer wrong in either direction.
    public static func isUnderCacheRoot(_ url: URL) -> Bool {
        let root = Paths.cache.resolvingSymlinksInPath().path
        // Resolve the PARENT, not the file: resolving a symlink that is
        // itself the thing being deleted would answer about its target.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolved = parent + "/" + url.lastPathComponent
        return resolved.hasPrefix(root + "/")
    }

    /// Every byte under a directory, following no symlinks.
    ///
    /// `allocatedSizeOfAllValues` would be closer to what Finder reports,
    /// and it is not what a person freeing space wants: they want the
    /// number that will change. Zero for a path that is not there, which is
    /// the ordinary state of half of these.
    public static func directoryBytes(at url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return 0 }
        guard
            let walk = manager.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return 0 }

        var total: Int64 = 0
        for case let child as URL in walk {
            let values = try? child.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// One file's bytes, or zero if it is a directory or absent.
    static func fileBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else { return 0 }
        return Int64(size)
    }
}
