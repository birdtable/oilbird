import Foundation

/// Telling code from prose.
///
/// ⚠ This exists because the checks moved INTO `Sources/`. As twelve Python
/// scripts they sat outside the tree they read and could never see
/// themselves; as a Swift target they are scanned like everything else, and on
/// the first run two of them found their own E5 probes — the forbidden call
/// and the path literal each one keeps in order to prove it can fail.
///
/// The wrong fixes were tempting and both are worse than the finding. Skipping
/// `Sources/OilbirdChecks` wholesale leaves the checks the one unchecked
/// corner of the repository. Assembling the probes from fragments so no
/// literal appears would make the rules read as satisfied while the thing they
/// forbid was still there in pieces, which is the exact failure every rule
/// here is written against.
///
/// The right fix is the one the `domains` check already needed: a name inside
/// a comment or a string literal is PROSE. `"Use Owner.machineName()"` is a
/// sentence somebody reads. `ProcessInfo.processInfo.hostName` inside a
/// pattern is the rule's own subject quoted back. Neither is a call, an
/// import, or an edge in the matrix, and a rule that counted them was reading
/// its own error messages as violations.
enum Code {
    private static let blockComment = Rx("/\\*.*?\\*/", [.dotMatchesLineSeparators])
    private static let multilineString = Rx("\"\"\".*?\"\"\"", [.dotMatchesLineSeparators])
    private static let string = Rx("\"(?:[^\"\\\\\\n]|\\\\.)*\"")
    private static let trailingComment = Rx("//.*$", [.anchorsMatchLines])

    /// A whole file with every comment and every string literal removed.
    ///
    /// Comments before strings, so an apostrophe or a lone quote in prose
    /// cannot unbalance the string matcher. Whole-line comments only at the
    /// file level: a trailing comment sits on a line that is code, and
    /// dropping the line would take the code with it.
    static func withoutProse(_ text: String) -> String {
        let uncommented = blockComment.strip(from: text)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return string.strip(from: multilineString.strip(from: uncommented))
    }

    /// One line, with its string literals and then its trailing comment
    /// removed — in that order, so the `//` in a URL is not read as a comment.
    static func withoutProse(line: String) -> String {
        trailingComment.strip(from: string.strip(from: line))
    }
}
