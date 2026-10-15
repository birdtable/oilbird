import Foundation

/// Oilbird knows every severity word this SonarQube uses, and no others.
///
/// ⚠ SonarQube runs two severity taxonomies and has added words to both.
/// `--severity HIGH` was once refused by a build whose own summary screen had
/// just printed `high 186`, and before that an MQR server's severities were
/// all painted dim by a switch that knew only the standard ladder. Both were
/// found by a person, twice, after shipping.
///
/// The server publishes its own vocabulary: `rules/search` declares the legal
/// values of `severities` and `impactSeverities`, and that declaration is
/// generated from the same place everything else under `api` is. So this asks
/// rather than remembers.
///
/// `V-1`  every word the server declares is one the code paints. A word it
///        does not know is drawn as ordinary body text, which is honest and
///        still silent, and silence is what this exists to break.
/// `V-2`  every word the code paints is one the server declares. A case
///        matching nothing is a rule guarding nothing (DM-4), and it would sit
///        there reading as though it worked.
///
/// Read from the running engine, like `api` and `overrides`. With nothing
/// running there is no vocabulary, and this says so and passes rather than
/// demanding an engine on a clean machine.
struct Severities: Check {
    let name = "severities"
    let holds = "the severity words the code paints are exactly the ones the server uses"

    /// Where the two ladders are painted. Both, because they are two switches
    /// over the same vocabulary and only one of them was ever wrong at a time.
    private static let painters = [
        (file: "Sources/OilbirdKit/Screens.swift", function: "severityRole"),
        (file: "Sources/OilbirdKit/TUI/IssuesBrowser.swift", function: "tone"),
    ]

    /// The parameters whose legal values ARE the vocabulary.
    private static let parameters = ["severities", "impactSeverities"]

    private static let word = Rx("\"([A-Z]{3,})\"")

    /// The body of one `static func <name>(` through its closing brace at the
    /// same indentation.
    private static func body(of function: String, in text: String) -> String? {
        let subject = text as NSString
        let opening = subject.range(of: "func \(function)(")
        guard opening.location != NSNotFound else { return nil }
        let after = opening.location + opening.length
        let closing = subject.range(
            of: "\n    }", range: NSRange(location: after, length: subject.length - after))
        guard closing.location != NSNotFound else { return nil }
        return subject.substring(with: NSRange(location: after, length: closing.location - after))
    }

    func selfTest() throws {
        let sample = """
                static func severityRole(_ severity: String) -> String {
                    switch severity {
                    case "BLOCKER", "HIGH": "bad"
                    default: "body"
                    }
                }
            """
        guard let found = Self.body(of: "severityRole", in: sample) else {
            throw SelfTest("a painter's body could not be read")
        }
        let words = Set(Self.word.capture(in: found as NSString))
        guard words == ["BLOCKER", "HIGH"] else {
            throw SelfTest("the severity words were read as \(words.sorted())")
        }
    }

    func run() throws -> Report {
        var painted: [String: Set<String>] = [:]
        for painter in Self.painters {
            let text = try Checkout.read(painter.file)
            guard let found = Self.body(of: painter.function, in: text) else {
                throw Shape("\(painter.function) in \(painter.file) is gone, or has changed shape")
            }
            let words = Set(Self.word.capture(in: found as NSString))
            guard !words.isEmpty else {
                throw Shape("\(painter.function) paints no severity words; has it changed shape?")
            }
            painted[painter.function] = words
        }

        var report = Report(summary: "")
        guard let binary = Self.binary(), let declared = Self.vocabulary(binary) else {
            report.summary =
                "NOT CHECKED — no engine answered, so the server's own severity vocabulary "
                + "was not read"
            report.skipped = true
            return report
        }

        for (function, words) in painted.sorted(by: { $0.key < $1.key }) {
            for missing in declared.subtracting(words).sorted() {
                report.findings.append(
                    "V-1  the server uses '\(missing)' and \(function) does not paint it, so it "
                        + "would draw as ordinary text beside the ones that mean something")
            }
            for stale in words.subtracting(declared).sorted() {
                report.findings.append(
                    "V-2  \(function) paints '\(stale)', which this server does not use — the "
                        + "case guards nothing (DM-4)")
            }
        }
        report.summary =
            "\(declared.count) severity words declared by the server, across "
            + "\(Self.parameters.count) parameters, held against \(painted.count) painters"
        return report
    }

    private static func binary() -> URL? {
        [Checkout.url(".build/debug/oilbird"), URL(filePath: "/usr/local/bin/oilbird")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every legal value of the two severity parameters, asked through the
    /// product for the reason the `api` check gives: the CLI already holds the
    /// token, and a check that reads `credentials.json` is a check holding a
    /// secret for no reason.
    private static func vocabulary(_ binary: URL) -> Set<String>? {
        let task = Process()
        task.executableURL = binary
        task.arguments = ["api", "rules/search", "--json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let all = root["parameters"] as? [[String: Any]]
        else { return nil }

        var words: Set<String> = []
        for parameter in all {
            guard let key = parameter["key"] as? String, parameters.contains(key),
                let values = parameter["values"] as? [String]
            else { continue }
            words.formUnion(values)
        }
        return words.isEmpty ? nil : words
    }
}
