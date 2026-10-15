import Foundation

/// The artefacts Oilbird installs and supervises.
///
/// Every one is fetched at run time from its official origin and lives under
/// the cache root — none of it is state, all of it is rederivable. The pinned
/// version, URL, size and digest for each live in `manifest.json`, which is
/// the only place a version string may appear.
public enum DependencyID: String, CaseIterable, Sendable {
    case sonarqube
    case jdk
    case postgres
    case scanner
}

/// What a `verify()` found. Presence on disk is not presence: `.present` is
/// only reported after the dependency has run its workload.
public enum DependencyHealth: Sendable, Equatable {
    case missing
    case present(version: String)
    case corrupt(reason: String)
}
