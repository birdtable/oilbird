import Foundation
import OilbirdCore

/// What an analysis will and will not look at, in words a person can check.
///
/// ⚠ Oilbird decides all of this and told nobody. A repository with
/// `node_modules` in it is analysed in seconds rather than twenty minutes
/// because of a list in `ScannerCommand.swift`; a `.spec.ts` is scored as
/// test code because of another. Both are good decisions and both were
/// invisible, so the one question a person asks after a surprising result —
/// "did it even look at that?" — had no answer short of reading the source.
///
/// ⚠ And they are the USER'S lists now, not ours. They were constants that
/// could be added to and never removed, applied to every language at once.
/// SonarQube does not do that — it ships `**/vendor/**` for Go, PHP and
/// Ruby and for nothing else, and every one of its settings is a value the
/// user can change. A fixed list was chosen over inference and that
/// half stands: Oilbird still never guesses. It suggests, once, visibly,
/// and then does what it is told.
extension Oilbird {
    /// Where a fresh install starts. Not what any particular install uses —
    /// ask `settings()` for that.
    public static var suggestedNeverAnalysed: [String] { ScannerCommand.defaultNeverSource }

    /// Patterns suggested as test code rather than production code.
    public static var suggestedTreatedAsTests: [String] { ScannerCommand.defaultTestPatterns }

    /// Whether this install still has the suggestion untouched, so a window
    /// can offer to restore it without offering a no-op.
    public static var usingSuggestedScope: Bool {
        settings().neverAnalysed == suggestedNeverAnalysed
            && settings().treatedAsTests == suggestedTreatedAsTests
    }

    /// The list the scanner is actually given, exactly as it appears on the
    /// command line.
    ///
    /// Shown rather than described, so the window cannot claim one thing
    /// while the scan does another. Empty means "analyse everything", which
    /// is a legitimate thing to have chosen and must not read as a fault.
    public static func exclusionsAsSent() -> String {
        ScannerCommand.patterns(settings().neverAnalysed)
    }

    /// What a folder becomes: the key SonarQube stores it under, and the
    /// name a person reads.
    ///
    /// ⚠ Two different things, and the difference has bitten twice. The key
    /// carries a hash of the absolute path so two checkouts of one
    /// repository cannot overwrite each other's history, and it is
    /// transliterated to ASCII because SonarQube's key rule is not Unicode
    /// aware — `~/src/café-service` used to fail after twenty-five seconds
    /// of analysis with the reason only in a log. Both facts are surprising
    /// enough to be worth showing rather than explaining.
    public struct ProjectNaming: Sendable, Equatable {
        /// The whole path, which is what the key's hash is taken over.
        public let folder: String
        /// Its last component — what the example shows, because the point
        /// is what happens to the name and not where it lives.
        public let folderName: String
        public let key: String
        public let name: String
    }

    public static func projectNaming(for path: URL) -> ProjectNaming {
        ProjectNaming(
            folder: path.path, folderName: path.lastPathComponent,
            key: Project.key(for: path), name: Project.name(for: path))
    }

    /// The example the Scanning pane shows.
    ///
    /// Computed from the real functions rather than written down, so it
    /// cannot become a screenshot of behaviour Oilbird no longer has —
    /// which is what a written-down design example turned into. A path under `/tmp`
    /// rather than a home directory: it is illustrative, and interpolating
    /// the reader's own user name into it would suggest Oilbird had looked.
    public static func namingExample() -> ProjectNaming {
        projectNaming(for: Paths.Cache.scratch.appending(path: "café-service"))
    }
}
