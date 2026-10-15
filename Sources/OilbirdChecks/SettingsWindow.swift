import Foundation

/// The two things this gate asks of the settings window.
///
/// `S-1`  The settings window contains no layout literal at all: every
///        measurement in it comes from `SettingsLayout`.
///
///        "No number in `SettingsLayout` appears anywhere else in the app",
///        enforced literally, is not a rule, it is a lottery. `SettingsLayout`
///        holds a `9` and a `10` and a `44`; so does every other view file in
///        every UI ever written, and a bird drawn 44 points wide is not a
///        citation of `titlebarClearance`.
///
///        So it is turned round, and the result is STRONGER for the thing the
///        gate is protecting. If the settings window never writes a bare
///        measurement, then every number it lays out with is in
///        `SettingsLayout` by construction, and a number elsewhere in the app
///        that happens to equal one of them is not the same number — it is
///        `Theme`'s, or a local one, and editing `SettingsLayout` was never
///        going to reach it anyway. These metrics have one home;
///        this is what having one means.
///
/// `S-2`  No user-visible string in the app contains markdown that will not
///        render.
///
///        Literal backticks in the settings panel — "puts `oilbird` on your
///        PATH" — render as those characters, which is the source of a
///        document nobody was going to format. `**bold**` and `[link](url)` are the same mistake with
///        different punctuation.
///
/// Both arms are proven able to fail before either reports clean (E5).
struct SettingsWindow: Check {
    let name = "settings"
    let holds = "no bare measurement in the settings window, no markdown in a visible string"

    private static let app = "Sources/OilbirdApp"
    private static let metricsFile = "Sources/OilbirdApp/SettingsLayout.swift"

    /// `static let rowHeight: CGFloat = 42`
    private static let definition = Rx("static\\s+let\\s+(\\w+)\\s*:\\s*CGFloat\\s*=\\s*([\\d.]+)")

    /// The files the rule applies to: the settings window and nothing else.
    private static let guardedPrefix = "Settings"

    /// A number in a position where it is a measurement: a constraint, a
    /// spacing, a radius, an inset. NOT every number in the file — an alpha, a
    /// font weight and a poll interval are all numbers and none of them is a
    /// metric, and a gate that flagged those would be switched off within a
    /// week.
    private static let layout = Rx(
        "(?:equalToConstant|greaterThanOrEqualToConstant|lessThanOrEqualToConstant|constant)"
            + "\\s*:\\s*(-?[\\d.]+)"
            + "|(?:spacing|cornerRadius|borderWidth|preferredMaxLayoutWidth|pointSize)"
            + "\\s*=\\s*(-?[\\d.]+)"
            + "|NSEdgeInsets\\(([^)]*)\\)", [.dotMatchesLineSeparators])
    private static let number = Rx("-?\\d+(?:\\.\\d+)?")

    /// Markdown that renders as itself in an `NSTextField`. The backtick is
    /// the one that actually shipped: "puts `oilbird` on your PATH", drawn
    /// with the backticks in it.
    private static let markdown = Rx(
        "`[^`\\n]+`|\\*\\*[^*\\n]+\\*\\*|\\[[^\\]\\n]+\\]\\([^)\\n]+\\)")

    /// ⚠ A glob is not markdown. `**/generated/**` matches the bold rule
    /// exactly, and it is the placeholder in the field where a user types glob
    /// patterns — the one string in the window that MUST contain those
    /// characters. A slash inside the match is the tell, and it is not a
    /// plausible shape for emphasis.
    private static let glob = "/"

    /// A Swift string literal on one line.
    private static let literal = Rx("\"((?:[^\"\\\\\\n]|\\\\.)*)\"")

    /// The file with every comment line blanked, newlines kept.
    ///
    /// Blanked rather than dropped so line numbers still point at the source,
    /// and whole-file rather than line-by-line because an `NSEdgeInsets` that
    /// swift-format has broken over four lines is exactly where a stray
    /// measurement hides.
    private static func withoutComments(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0 }
            .joined(separator: "\n")
    }

    func selfTest() throws {
        guard Self.layout.matches("x.widthAnchor.constraint(equalToConstant: 42)") else {
            throw SelfTest("a layout literal was not detected")
        }
        guard Self.markdown.matches("puts `oilbird` on your PATH") else {
            throw SelfTest("a backtick pair was not detected")
        }
        guard !Self.markdown.matches("nothing to see here") else {
            throw SelfTest("markdown was seen where there is none")
        }
    }

    func run() throws -> Report {
        for declared in [Self.app, Self.metricsFile] where !Checkout.exists(declared) {
            throw Shape(
                "declared path not found: \(declared). Refusing to report clean from a scan "
                    + "that read nothing")
        }

        let metrics = Self.definition.capture(in: try Checkout.read(Self.metricsFile) as NSString)
        guard !metrics.isEmpty else {
            throw Shape(
                "SettingsLayout declares no CGFloat metrics. Refusing to report clean from a "
                    + "list of none")
        }

        var report = Report(summary: "")
        var read = 0
        var guarded = 0

        for file in Checkout.swiftFiles(under: Self.app) where file != Self.metricsFile {
            let code = Self.withoutComments(try Checkout.read(file))
            let subject = code as NSString
            read += 1

            if (file as NSString).lastPathComponent.hasPrefix(Self.guardedPrefix) {
                guarded += 1
                for hit in Self.layout.hits(in: subject) {
                    var found = [hit.group(1), hit.group(2)].compactMap { $0 }
                    if let insets = hit.group(3) {
                        found += Self.number.capture(0, in: insets as NSString)
                    }
                    for value in found {
                        // 0 and 1 are not measurements: a zero inset is the
                        // absence of one, and a hairline is a device pixel
                        // rather than a proportion anybody would tune.
                        guard let measure = Double(value), measure != 0, measure != 1 else {
                            continue
                        }
                        report.findings.append(
                            "S-1  \(file):\(Line.of(hit.start, in: subject))  the bare "
                                + "measurement \(value) belongs in SettingsLayout")
                    }
                }
            }

            for string in Self.literal.hits(in: subject) {
                guard let body = string.group(1) else { continue }
                for found in Self.markdown.hits(in: body as NSString) {
                    guard let text = found.group(0), !text.contains(Self.glob) else { continue }
                    report.findings.append(
                        "S-2  \(file):\(Line.of(string.start, in: subject))  \"\(text)\" is "
                            + "markdown in a string the user reads; it renders as those "
                            + "characters")
                }
            }
        }

        guard guarded > 0 else {
            throw Shape(
                "no Settings*.swift under \(Self.app). S-1 read nothing; refusing to report it "
                    + "clean")
        }
        report.summary =
            "\(metrics.count) metrics, \(guarded) settings files held to them, "
            + "\(read) files read for markdown"
        return report
    }
}
