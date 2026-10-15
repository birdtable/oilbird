import Foundation

/// Oilbird's own ground agrees with the dashboard it frames.
///
/// `C-1`  Theme's dark ground is within tolerance of BOTH of SonarQube's dark
///        grounds, as `make tint-tokens` recorded them from the pinned server.
///
///        `MainWindowController` states the rule this enforces: "the web
///        content's own ground runs to the edges … warm chrome wrapped around
///        a cool web view reads as an iframe". A cream frame around `#2a2f40`
///        is that failure, and it is what the user saw the first time they
///        used dark mode.
///
///        Oilbird tints the dashboard to its own values, so when the tint
///        lands the two agree exactly. This is about when it does NOT: the
///        tint degrades to stock by design, and this keeps the degraded
///        picture from being a mismatch. Both grounds, because
///        `html,body{background-color:#fff !important}` survives into the dark
///        theme — the visible page ground is painted by the app shell over the
///        top of it, and which token that is cannot be settled by reading the
///        stylesheets.
///
/// `C-2`  The recorded palette is there at all. A tokens file with no
///        `# theme` lines gives `C-1` nothing to compare, and a gate that
///        reports clean over a subject it never read is worse than no gate.
///
/// This cannot live in the Swift suites: `Theme.swift` is in an executable
/// target, which cannot be `@testable import`-ed (SwiftPM #7596). The values
/// it is checked against are in a resource the suites do read, so the other
/// half of this — that the file carries them — is asserted there too.
struct Chrome: Check {
    let name = "chrome"
    let holds = "Oilbird's dark ground is within tolerance of SonarQube's"

    private static let theme = "Sources/OilbirdApp/Theme.swift"
    private static let tokens = "Sources/OilbirdCore/Resources/sonarqube-tokens.txt"

    /// Per channel, out of 255. Wide enough that Oilbird's dark may be its own
    /// colour — warmer, and sitting between SonarQube's two grounds rather
    /// than on either — and narrow enough that a real restyle cannot pass.
    /// SonarQube's own two dark grounds are 17 apart on the blue channel, so
    /// anything under that would be a tolerance neither of them could satisfy.
    private static let tolerance = 34

    /// The `dark: srgb(a, b, c)` of `static let surface`, across however many
    /// lines swift-format has put it on. The doubles are the source of truth,
    /// not the hex in the comment beside them — a check that read the comment
    /// would be checking the comment.
    private static let darkSRGB = Rx(
        "dark:\\s*srgb\\(\\s*([\\d.]+)\\s*,\\s*([\\d.]+)\\s*,\\s*([\\d.]+)\\s*\\)")

    private struct Colour: Equatable {
        let red: Int
        let green: Int
        let blue: Int
        var channels: [Int] { [red, green, blue] }
    }

    /// `#fff` and `#2a2f40` both. `nil` for anything else.
    private static func parse(hex value: String) -> Colour? {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 else { return nil }
        let digits = Array(text)
        var channels: [Int] = []
        for start in stride(from: 0, to: 6, by: 2) {
            guard let value = Int(String(digits[start...start + 1]), radix: 16) else {
                return nil
            }
            channels.append(value)
        }
        return Colour(red: channels[0], green: channels[1], blue: channels[2])
    }

    private static func distance(_ one: Colour, _ other: Colour) -> Int {
        zip(one.channels, other.channels).map { abs($0 - $1) }.max() ?? 0
    }

    func selfTest() throws {
        guard Self.parse(hex: "#fff") == Colour(red: 255, green: 255, blue: 255) else {
            throw SelfTest("#fff did not parse as white")
        }
        let black = Colour(red: 0, green: 0, blue: 0)
        let white = Colour(red: 255, green: 255, blue: 255)
        guard Self.distance(black, white) > Self.tolerance else {
            throw SelfTest("black and white passed the tolerance")
        }
    }

    func run() throws -> Report {
        for declared in [Self.theme, Self.tokens] where !Checkout.exists(declared) {
            throw Shape(
                "declared path not found: \(declared). Refusing to report clean from a scan "
                    + "that read nothing")
        }

        var recorded: [String: String] = [:]
        for line in try Checkout.read(Self.tokens).components(separatedBy: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            if parts.count == 4 && parts[0] == "#" && parts[1] == "theme" {
                recorded[parts[2]] = parts[3]
            }
        }

        var report = Report(
            summary: "\(recorded.count) recorded theme values, tolerance \(Self.tolerance)/255")
        if !recorded.keys.contains(where: { $0.hasPrefix("dark-") }) {
            report.findings.append(
                "the token file records no `# theme dark-*` values — run `make tint-tokens`")
        }

        let palette = try Checkout.read(Self.theme) as NSString
        let anchor = palette.range(of: "static let surface = dynamic(")
        var ours: Colour?
        if anchor.location != NSNotFound,
            let hit = Self.darkSRGB.first(in: palette, from: anchor.location),
            let red = hit.group(1).flatMap(Double.init),
            let green = hit.group(2).flatMap(Double.init),
            let blue = hit.group(3).flatMap(Double.init)
        {
            ours = Colour(
                red: Int((red * 255).rounded()), green: Int((green * 255).rounded()),
                blue: Int((blue * 255).rounded()))
        }
        guard let ours else {
            report.findings.append(
                "Theme.Colour.surface has no `dark: srgb(...)` — has the palette changed shape?")
            return report
        }

        for role in ["dark-surface", "dark-canvas"] {
            guard let value = recorded[role] else {
                report.findings.append("\(role) is not recorded in the token file")
                continue
            }
            guard let theirs = Self.parse(hex: value) else {
                report.findings.append("\(role) = \(value) is not a colour this can read")
                continue
            }
            let apart = Self.distance(ours, theirs)
            if apart > Self.tolerance {
                report.findings.append(
                    "C-1  Oilbird's dark ground rgb\(ours.channels) is \(apart) from "
                        + "SonarQube's \(role) \(value) rgb\(theirs.channels), past the "
                        + "\(Self.tolerance) tolerance — the frame would read as a border "
                        + "round the page")
            }
        }
        return report
    }
}
