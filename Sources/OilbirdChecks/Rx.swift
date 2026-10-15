import Foundation

/// A regular expression and the four things a gate asks of one.
///
/// ⚠ `NSRegularExpression` rather than Swift's `Regex`. Half the patterns
/// here are built at run time out of a domain name, an override anchor or a
/// route, and a `Regex` literal cannot be assembled from a `String` at all.
///
/// A pattern that will not compile is a crash and not a thrown error. A gate
/// whose rule failed to build would otherwise report clean over a rule that
/// never ran, which is the one outcome every gate in this directory is
/// written against.
/// ⚠ `@unchecked Sendable` and not a warning to be silenced later.
/// `NSRegularExpression` is documented thread-safe for matching — the object
/// is immutable once compiled — and the gates hold theirs in `static let`
/// properties, which Swift 6 requires be Sendable. The alternative is
/// rebuilding every pattern on every call, over every file in the repository.
struct Rx: @unchecked Sendable {
    let pattern: String
    private let expression: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        self.pattern = pattern
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            fatalError(
                "checks: the pattern /\(pattern)/ does not compile")
        }
        expression = compiled
    }

    /// One match, with its capture groups. `group(1)` is the first capture;
    /// `group(0)` is the whole match, as in every other regex dialect.
    struct Hit {
        let text: NSString
        let result: NSTextCheckingResult

        func group(_ index: Int) -> String? {
            guard index < result.numberOfRanges else { return nil }
            let range = result.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return text.substring(with: range)
        }

        /// Where the match starts, in UTF-16 units, for `Line.of`.
        var start: Int { result.range.location }
    }

    func hits(in text: NSString, from offset: Int = 0) -> [Hit] {
        let range = NSRange(location: offset, length: text.length - offset)
        return expression.matches(in: text as String, range: range)
            .map { Hit(text: text, result: $0) }
    }

    func first(in text: NSString, from offset: Int = 0) -> Hit? {
        hits(in: text, from: offset).first
    }

    func matches(_ text: String) -> Bool { first(in: text as NSString) != nil }

    /// The subject with every match removed.
    func strip(from text: String) -> String {
        let subject = text as NSString
        return expression.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: subject.length), withTemplate: "")
    }

    /// Every occurrence of one capture group, in order, like Python's
    /// `findall` with a single group.
    func capture(_ index: Int = 1, in text: NSString) -> [String] {
        hits(in: text).compactMap { $0.group(index) }
    }
}

/// Line numbers, for findings that name a place.
enum Line {
    /// The 1-based line holding this UTF-16 offset.
    ///
    /// Newlines counted rather than lines enumerated: an offset sitting
    /// exactly on a line break belongs to the line it ends, and every
    /// line-enumerating API disagrees with the next about which one that is.
    static func of(_ offset: Int, in text: NSString) -> Int {
        guard offset > 0 else { return 1 }
        let prefix = text.substring(to: min(offset, text.length)) as NSString
        var lines = 1
        for index in 0..<prefix.length where prefix.character(at: index) == 10 { lines += 1 }
        return lines
    }
}
