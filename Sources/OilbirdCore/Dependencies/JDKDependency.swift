import Foundation
import OilbirdModel

/// Temurin JDK 21.
///
/// A **full JDK**, not the JRE the SonarQube distribution bundles. That JRE
/// has 49 modules and no `jdk.attach`, which Elasticsearch's entitlement
/// bootstrap requires, so the server dies at boot with
/// `FindException: Module jdk.attach not found`. The bundled `jres/` exist so
/// SonarQube can hand a JRE to *scanners*, which have no such requirement.
///
/// The earlier conclusion that the bundled JRE was usable came from running
/// `java -version` and calling it verification. It printed a perfectly good
/// answer. That is why `verify()` boots the server instead.
public struct JDKDependency: ManagedDependency {
    public let id = DependencyID.jdk
    public init() {}

    /// Adoptium's own record of what it built, written beside the runtime.
    ///
    /// `SEMANTIC_VERSION="21.0.12.1+1"` is the release tag without its
    /// `jdk-` prefix — the same string `manifest.json` pins as `release`.
    /// The `version` field, Adoptium's semver `21.0.12+101.0.LTS`, appears
    /// nowhere in this file, which is why the comparison is against the tag.
    static var releaseFile: URL {
        Paths.Cache.jdk.appending(path: "Contents/Home/release")
    }

    /// Cheap, and it asks whether the pinned JDK is installed rather than
    /// whether a JDK is.
    ///
    /// ⚠ This was `Resolver.executable(.java) == nil ? .missing :
    /// .present(version: "unverified")`. Any JDK at all satisfied it, so a
    /// bump — inside 21 or beyond it — was a no-op on every existing
    /// install: `Oilbird.install` skips a dependency whose `detect()` is
    /// `.present`, so the new artefact was never fetched and the old runtime
    /// kept booting the server. `verify()` could not catch it either,
    /// because it hard-coded `version == 21` and 21 is what was there.
    ///
    /// A JDK that is not the pinned one is `.missing`, not `.corrupt`: it is
    /// not damaged, it is superseded, and `.corrupt` would send the user to
    /// repair something that works.
    public func detect() -> DependencyHealth {
        guard Resolver.executable(.java) != nil else { return .missing }
        guard let entry = try? Manifest.bundled().entry(id) else {
            return .corrupt(reason: "Oilbird cannot tell which Java version it expects.")
        }
        guard let installed = Self.installedVersion() else { return .missing }
        // Never the manifest's string. The whole defect was reporting a
        // version that had not been read off the thing being reported on.
        return installed == entry.pinnedIdentifier ? .present(version: installed) : .missing
    }

    /// The `SEMANTIC_VERSION` line of the release file, or `nil`.
    ///
    /// A JDK without a readable release file is one Oilbird cannot identify,
    /// and an unidentifiable runtime is not the pinned one.
    static func installedVersion() -> String? {
        guard let text = try? String(contentsOf: releaseFile, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("SEMANTIC_VERSION=") {
            return String(line.dropFirst("SEMANTIC_VERSION=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"\r "))
        }
        return nil
    }

    public func install(progress: @Sendable (Int64, Int64) -> Void) async throws {
        let entry = try Manifest.bundled().entry(id)
        try await fetchAndPlace(entry, progress: progress)
    }

    /// ⚠ Booting SonarQube is the real verification, and it needs SonarQube
    /// installed — so the full check lives in `SonarQubeDependency.verify()`,
    /// which runs on this JDK. What is checked here is the weaker claim this
    /// dependency can make alone: that the binary runs, is the right feature
    /// version, and is the right architecture.
    ///
    /// Reporting `.present` from here would repeat the original mistake, so it
    /// reports the version it found and leaves the workload claim to the
    /// server.
    public func verify() async throws -> DependencyHealth {
        guard let java = Resolver.executable(.java) else { return .missing }
        let result = try await Child.run(java, ["-version"])
        // `java -version` writes to stderr. That is not a bug.
        let output = result.stderr + result.stdout
        guard result.status == 0 else {
            // Named, not described. A quarantined JVM is `SIGKILL`ed on exec
            // and says nothing, and "java exited 9" sends the reader to Java.
            return .corrupt(
                reason: result.killedBySIGKILL
                    ? "macOS blocked it — the quarantine attribute was not removed"
                    : "java exited \(result.status)")
        }
        guard let version = feature(in: output) else {
            return .corrupt(reason: "could not read a version from java -version")
        }
        // ⚠ A version string here is one outside `manifest.json`, which this
        // codebase forbids, and it makes the pin unbumpable: raising
        // the manifest leaves this rejecting the JDK it asked for.
        guard let entry = try? Manifest.bundled().entry(id),
            let pinned = Int(entry.version.prefix { $0.isNumber })
        else {
            return .corrupt(reason: "Oilbird cannot tell which Java version it expects.")
        }
        guard version == pinned else {
            return .corrupt(reason: "found Java \(version), Oilbird pins \(pinned)")
        }
        // A universal binary that runs under Rosetta would work and be slow;
        // the artifact is pinned to aarch64, so anything else means the wrong
        // one was installed.
        let arch = try await Child.run(URL(filePath: "/usr/bin/file"), [java.path])
        guard arch.stdout.contains("arm64") else {
            return .corrupt(reason: "the installed Java is not arm64")
        }
        // The full build, not the feature number. "21" is true of four
        // artefacts a year and says nothing about which one is here.
        return .present(version: Self.installedVersion() ?? String(version))
    }

    private func feature(in output: String) -> Int? {
        guard let range = output.range(of: #"version "([0-9]+)"#, options: .regularExpression)
        else { return nil }
        return Int(output[range].drop(while: { !$0.isNumber }))
    }
}
