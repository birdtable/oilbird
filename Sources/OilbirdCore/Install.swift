import Foundation
import OilbirdModel

/// Places one verified artefact in the cache root.
///
/// Separate from `Fetch` because they fail differently and test differently:
/// fetching is network, retry and digest; installing is filesystem, atomic
/// rename and idempotency.
public enum Install {
    /// Unpacks a **already-verified** file and makes it runnable.
    ///
    /// Ordering is the security half of this: quarantine is stripped only
    /// after `Fetch` has matched the digest. Strip first and Oilbird is
    /// executing unverified downloaded code with Gatekeeper switched off; skip
    /// it entirely and the PostgreSQL binaries are `SIGKILL`ed on first exec
    /// with no message at all.
    public static func artifact(
        at verified: URL, archive: Manifest.Archive, into destination: URL
    ) throws {
        Log.phase("install \(destination.lastPathComponent)")
        let staging = destination.appendingPathExtension("incoming")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            switch archive {
            case .zip:
                try run("/usr/bin/ditto", ["-x", "-k", verified.path, staging.path])
            case .tarGz:
                try run("/usr/bin/tar", ["xzf", verified.path, "-C", staging.path])
            case .jarTxz:
                // Two stages, and the step most likely to be got wrong: the jar
                // is a zip whose only useful member is a txz.
                try run("/usr/bin/ditto", ["-x", "-k", verified.path, staging.path])
                guard let inner = try innerArchive(in: staging) else {
                    throw OilbirdError(
                        .extractionFailed,
                        "That download did not contain what Oilbird expected.",
                        recovery: .retry("Download again"),
                        underlying: "no .txz member inside \(verified.lastPathComponent)")
                }
                try run("/usr/bin/tar", ["xJf", inner.path, "-C", staging.path])
                try? FileManager.default.removeItem(at: inner)
            }
            // Inside the same `do`, because everything up to the atomic move
            // leaves a half-extracted staging directory behind if it throws,
            // and the disk filling is exactly when that matters.
            try flattenSingleWrapper(staging)
            try stripQuarantine(staging)
        } catch let error as OilbirdError {
            try? FileManager.default.removeItem(at: staging)
            throw outOfSpace(error, unpacking: verified, into: destination) ?? error
        }

        // Atomic: the destination either is the previous install or the new
        // one, never a half-extracted mixture.
        let previous = destination.appendingPathExtension("previous")
        try? FileManager.default.removeItem(at: previous)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: destination, to: previous)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: destination)
        carryOver(from: previous, to: destination)
        try? FileManager.default.removeItem(at: previous)
    }

    /// The same failure, told as the one thing the user can act on.
    ///
    /// ⚠ A disk that filled mid-extract reached a person as *"Oilbird could
    /// not unpack that download. → Download again"* — advice that cannot
    /// work, on the machine least able to follow it: the download was fine,
    /// and fetching 1.14 GiB again needs the room that is missing. `.diskFull`
    /// and its `freeSpace` recovery have been declared since the error model
    /// was written and nothing in the product raised either, so the whole
    /// `disk-full` row of the fault table was a description of code that did
    /// not exist.
    ///
    /// Read from the child's own words: `ditto` and `tar` both write "No
    /// space left on device" and both exit 1, which `run` has already turned
    /// into an `underlying`.
    ///
    /// ⚠ `needed` is the ARCHIVE's size, a floor rather than the install's
    /// footprint — nothing records an unpacked size. Understating keeps the
    /// sentence true, and the alternative is a guessed multiplier.
    static func outOfSpace(_ error: OilbirdError, unpacking archive: URL, into destination: URL)
        -> OilbirdError?
    {
        guard error.underlying?.lowercased().contains("no space left on device") == true
        else { return nil }
        let needed =
            (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64)
            ?? 0
        return OilbirdError(
            .diskFull, "There is not enough room to unpack that download.",
            recovery: .freeSpace(needed: needed, available: freeBytes(on: destination)),
            underlying: error.underlying)
    }

    /// Room on the volume a path lives on, or 0 when it cannot be read.
    ///
    /// The important-usage figure first, because it is the one Finder shows
    /// and so the one the user will go and check against.
    static func freeBytes(on path: URL) -> Int64 {
        let volume = path.deletingLastPathComponent()
        let keys: [URLResourceKey] = [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let values = try? volume.resourceValues(forKeys: Set(keys)) else { return 0 }
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        return Int64(values.volumeAvailableCapacity ?? 0)
    }

    /// Directories the new install inherits from the one it replaces.
    ///
    /// ⚠ **Everything in `extensions/plugins` was deleted by every upgrade,
    /// silently.** SonarQube ships that directory with its own README saying
    /// to put jars there, it works, and this function used to move the whole
    /// install aside and throw it away — so a plugin someone installed by
    /// hand vanished at the next version bump with nothing said, and the only
    /// symptom was analysis quietly getting worse.
    ///
    /// Copied rather than merged: a file the new install ships wins, because
    /// a bundled analyser must not be shadowed by a stale copy of itself.
    public static let carried = ["extensions/plugins"]

    public static func carryOver(from previous: URL, to destination: URL) {
        let manager = FileManager.default
        for relative in carried {
            let old = previous.appending(path: relative)
            let new = destination.appending(path: relative)
            guard let kept = try? manager.contentsOfDirectory(atPath: old.path), !kept.isEmpty
            else { continue }
            try? manager.createDirectory(at: new, withIntermediateDirectories: true)
            for file in kept where !file.hasPrefix(".") {
                let target = new.appending(path: file)
                // The new install wins. A jar it ships is the one to run.
                guard !manager.fileExists(atPath: target.path) else { continue }
                do {
                    try manager.copyItem(at: old.appending(path: file), to: target)
                    Log.info("carried \(relative)/\(file) over the upgrade")
                } catch {
                    // Said, never silent: this is the failure the whole
                    // function exists to stop happening quietly.
                    Log.warn("could not carry \(relative)/\(file) over: \(error)")
                }
            }
        }
    }

    /// Strips a single wrapping directory, if the archive has one.
    ///
    /// Three of the four artifacts wrap their contents in one top-level
    /// directory named for the release — `jdk-21.0.12.1+1/`,
    /// `sonarqube-26.9.0.129388/`, `sonar-scanner-7.3.0.5189/` — which is the
    /// polite tar convention. PostgreSQL's `.txz` is flat.
    ///
    /// Without this every path lookup misses by exactly one directory, and it
    /// fails in the worst way available: the download succeeds, the checksum
    /// matches, the quarantine strip runs, and then the binary is reported
    /// missing. Nothing points at the cause.
    ///
    /// The version is in the directory name, so hard-coding it would put a
    /// version string outside `manifest.json`, which this codebase forbids. Detecting
    /// the shape avoids that and survives a version bump.
    public static func flattenSingleWrapper(_ tree: URL) throws {
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(
            at: tree, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { $0.lastPathComponent != ".DS_Store" }

        guard entries.count == 1,
            let only = entries.first,
            (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return }

        Log.info("flattening wrapper directory \(only.lastPathComponent)")
        for child in try manager.contentsOfDirectory(at: only, includingPropertiesForKeys: nil) {
            try manager.moveItem(at: child, to: tree.appending(path: child.lastPathComponent))
        }
        try manager.removeItem(at: only)
    }

    /// Removes `com.apple.quarantine` from an extracted tree.
    ///
    /// The PostgreSQL binaries are Developer ID signed but **not notarized**,
    /// so a quarantined postmaster is `SIGKILL`ed on first exec, exit 137,
    /// silently. Quarantine propagates through both `ditto` and `tar`, so the
    /// strip covers the extracted tree rather than the file that was
    /// downloaded. Ad-hoc re-signing does not help; removing the attribute is
    /// necessary and sufficient.
    /// ⚠ **And it is CHECKED, because it was best-effort and silent.** The
    /// strip ran with `allowFailure: true` and nothing looked afterwards —
    /// so on the one machine where it did not work, the install completed,
    /// reported success, and the postmaster was `SIGKILL`ed on first exec
    /// with exit 137 and no message. That is the failure described two
    /// paragraphs up, reached by the code meant to prevent it.
    ///
    /// It matters more now than when this was written: a downloaded Oilbird
    /// is itself quarantined, and quarantine propagates to what a
    /// quarantined process writes — so the case this guards against is the
    /// NORMAL case for anyone who did not build from source.
    public static func stripQuarantine(_ tree: URL) throws {
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", tree.path], allowFailure: true)
        let left = quarantined(in: tree)
        guard left.isEmpty else {
            throw OilbirdError(
                .quarantined,
                "Oilbird could not clear the quarantine flag from what it downloaded.",
                recovery: .retry("Try again"),
                underlying:
                    "\(left.count) file(s) still quarantined under \(tree.path), "
                    + "first: \(left[0])")
        }
    }

    /// Every file under a tree that still carries the quarantine flag.
    ///
    /// Bounded: the first few are enough to name the problem, and walking a
    /// 947 MB tree to count all of them helps nobody.
    public static func quarantined(in tree: URL, limit: Int = 5) -> [String] {
        guard
            let walker = FileManager.default.enumerator(
                at: tree, includingPropertiesForKeys: nil)
        else { return [] }
        var found: [String] = []
        for case let file as URL in walker {
            // `getxattr` rather than spawning `xattr` per file: this runs
            // over every file of a 947 MB extraction.
            let has = file.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                return getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
            }
            if has {
                found.append(file.lastPathComponent)
                if found.count >= limit { break }
            }
        }
        return found
    }

    // MARK: What is actually installed

    /// Records the entry an install just placed, in the container.
    ///
    /// ⚠ `Manifest`'s own docstring had described this file since it was
    /// written — "copied into the container on first run, so an
    /// installed Oilbird records what it actually installed … that is what
    /// makes a downgrade diagnosable" — and `Paths.State.installedManifest`
    /// has always named the location. Nothing wrote it. The file was absent
    /// from the live container, so the claim was documentation of an
    /// intention and behaviour nowhere.
    ///
    /// What that cost: with nothing recorded, "the artefact on disk is older
    /// than this build pins" and "this build is older than the one that
    /// installed" are the same silence, and every one of those is a version
    /// bump going wrong with no way to tell which.
    ///
    /// Written **per dependency as each is placed**, not copied whole on
    /// first run. Installs are per dependency and can partially fail; a
    /// wholesale copy would claim all four were at this build's versions the
    /// moment one of them was, which is the same lie in a new file.
    public static func record(_ id: DependencyID, _ entry: Manifest.Entry) throws {
        var entries = installed()?.dependencies ?? [:]
        if let previous = entries[id.rawValue], previous.version != entry.version {
            Log.info("\(id.rawValue) \(previous.version) → \(entry.version)")
        }
        entries[id.rawValue] = entry
        let file = Paths.State.installedManifest
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder
                .encode(Manifest(schema: Manifest.supportedSchema, dependencies: entries))
                .write(to: file, options: .atomic)
        } catch {
            // Fatal to the install, never a warning: an install that does not
            // record itself is discovered one version bump later, by somebody
            // who cannot see the install that caused it.
            throw OilbirdError(
                .verifyFailed, "Oilbird could not record what it installed.",
                recovery: .reportIssue("Report an issue"),
                underlying: "\(file.path): \(error)")
        }
    }

    /// What the container says is installed, or `nil` if it says nothing.
    ///
    /// A record this build cannot read is no record: `Manifest.load` refuses
    /// an unknown schema rather than guessing, and a downgrade reading a
    /// newer file is precisely when guessing would be worst. The next install
    /// rewrites it in a shape this build does understand.
    public static func installed() -> Manifest? {
        guard
            let data = FileManager.default.contents(atPath: Paths.State.installedManifest.path)
        else { return nil }
        return try? Manifest.load(from: data)
    }

    public static func installedEntry(_ id: DependencyID) -> Manifest.Entry? {
        installed()?.dependencies[id.rawValue]
    }

    // MARK: -

    private static func innerArchive(in tree: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: tree, includingPropertiesForKeys: nil)
        return contents.first { $0.pathExtension == "txz" }
    }

    private static func run(_ path: String, _ argv: [String], allowFailure: Bool = false) throws {
        let executable = URL(filePath: path)
        Log.subprocess(executable, argv: argv)
        let process = Process()
        process.executableURL = executable
        process.arguments = argv
        process.environment = Resolver.childEnvironment()
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard allowFailure || process.terminationStatus == 0 else {
            let detail = String(data: stderr, encoding: .utf8) ?? ""
            throw OilbirdError(
                .extractionFailed,
                "Oilbird could not unpack that download.",
                recovery: .retry("Download again"),
                underlying: "\(path) exited \(process.terminationStatus): \(detail)")
        }
    }
}
