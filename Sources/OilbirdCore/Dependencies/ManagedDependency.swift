import Foundation
import OilbirdModel

/// The dependency triple, as a protocol.
///
/// Nothing counts as present until `verify()` passes, and the compiler
/// enforces the shape: a type missing any of the three does
/// not conform, so a half-managed dependency does not build.
///
/// **`verify()` runs the workload, not a version flag.** That rule exists
/// because it was broken: the JRE bundled in the SonarQube distribution
/// printed a perfectly good `java -version` and was pronounced usable, then
/// failed to boot Elasticsearch for want of `jdk.attach`. Presence on disk is
/// not presence.
public protocol ManagedDependency: Sendable {
    var id: DependencyID { get }

    /// Cheap. Is it on disk at all?
    func detect() -> DependencyHealth

    /// Fetch, verify the digest, unpack, make runnable. Idempotent.
    func install(progress: @Sendable (Int64, Int64) -> Void) async throws

    /// Does it actually work? Runs the thing, never a version flag.
    func verify() async throws -> DependencyHealth
}

extension ManagedDependency {
    /// The shared body of every `install`: fetch to the partials directory,
    /// then place. Split because they fail and test differently — fetching is
    /// network and digest, installing is filesystem and idempotency.
    func fetchAndPlace(
        _ entry: Manifest.Entry, progress: @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard let url = URL(string: entry.url) else {
            throw OilbirdError(
                .originMoved, "That download address is not usable.",
                recovery: .reportIssue("Report an issue"),
                underlying: "unparseable URL in manifest: \(entry.url)")
        }
        let verified = try await Fetch.artifact(
            url: url, expecting: entry.sha256, bytes: entry.bytes, progress: progress)
        try Install.artifact(at: verified, archive: entry.archive, into: Paths.install(id))
        // Recorded here rather than in each `install()`, being the one line all
        // four go through. It records what was PLACED: `Fetch` matched the
        // digest before extraction, so the tree is this artefact.
        try Install.record(id, entry)
    }
}
