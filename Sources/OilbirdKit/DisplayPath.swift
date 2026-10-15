import Foundation

/// A path as a person reads it, rather than as the filesystem writes it.
///
/// ⚠ **Nothing abbreviated a home-relative path, and under a long home
/// directory that is a run of noise repeated in four places.** The settings
/// window is 520pt of content; a long home directory (an email-style account
/// name easily passes 30 characters) is all spent before the path says
/// anything, and spent again in the CLI row, both Storage roots and the MCP
/// server row. A test machine with a short home hides this: every screenshot
/// taken there is of a shorter string than the product draws elsewhere.
///
/// One helper, because there is more than one place and a rule applied in
/// four of five is not a rule. `Tests/OilbirdKitTests/DisplayPathTests.swift`
/// holds it to the lengths that matter, including a 33-character home, so a
/// build machine with a short user name cannot report it clean.
extension Oilbird {
    /// `~` for the home directory, everything else untouched.
    ///
    /// The prefix must end at a component boundary: `/Users/al` is not
    /// inside `/Users/alex`, and a `hasPrefix` alone would say it is and
    /// hand back a path pointing somewhere else entirely.
    ///
    /// - Parameter home: the home directory to measure against. A parameter
    ///   so a test can pass a long home on a machine whose own is short,
    ///   since a short home is exactly what hides the problem.
    public static func displayPath(
        _ path: String, relativeTo home: String = NSHomeDirectory()
    ) -> String {
        let root = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !root.isEmpty, path == root || path.hasPrefix(root + "/") else { return path }
        return "~" + path.dropFirst(root.count)
    }
}
