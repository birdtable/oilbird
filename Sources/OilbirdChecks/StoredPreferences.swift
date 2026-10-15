import Foundation

/// Every stored preference is actually stored.
///
/// ⚠ `Preferences.Stored` writes its own `CodingKeys`, `encode(to:)` and
/// `init(from:)`, each for a good reason recorded beside it — a legacy key to
/// migrate from, and defaults that a synthesized decoder would throw over
/// rather than fall back to. The cost is that adding a property is now THREE
/// edits, and missing one of them fails silently in the worst way: it
/// compiles, the setting appears to save, the command says so, and nothing is
/// written.
///
/// Found the hard way. `projectNames` was added, `oilbird configure --name`
/// said `saved`, and the plist never grew the key.
struct StoredPreferences: Check {
    let name = "prefs"
    let holds = "every property of Preferences.Stored has a coding key and is encoded"

    private static let source = Checkout.core("Preferences")
    private static let block = Rx(
        "public struct Stored[^{]*\\{(.*?)\\n    \\}\\n", [.dotMatchesLineSeparators])
    private static let property = Rx("^\\s+public var (\\w+)", [.anchorsMatchLines])
    private static let codingKey = Rx("^\\s+case ([\\w, ]+)$", [.anchorsMatchLines])
    private static let encodes = Rx(
        "container\\.encode(?:IfPresent)?\\([^,]+, forKey: \\.(\\w+)\\)")
    private static let byKey = Rx("forKey: \\.(\\w+)\\)")

    func selfTest() throws {
        // The three shapes this reads, each asserted against a line of the
        // form it is written for. A pattern that stopped matching would
        // otherwise parse to nothing, and "no properties" reads as clean.
        guard Self.property.matches("    public var projectNames: [String: String]") else {
            throw SelfTest("a stored property was not recognised")
        }
        guard Self.codingKey.matches("        case projectNames\n") else {
            throw SelfTest("a coding key was not recognised")
        }
        guard Self.encodes.matches("container.encode(projectNames, forKey: .projectNames)")
        else {
            throw SelfTest("an encode call was not recognised")
        }
    }

    func run() throws -> Report {
        let text = try Checkout.read(Self.source) as NSString
        guard let found = Self.block.first(in: text), let body = found.group(1) else {
            throw Shape("Preferences.Stored is gone, or has changed shape")
        }
        let inside = body as NSString

        let properties = Set(Self.property.capture(in: inside))
        var keys: Set<String> = []
        for group in Self.codingKey.capture(in: inside) {
            keys.formUnion(
                group.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
        }
        let encoded = Set(Self.encodes.capture(in: inside))
        let decoded = Set(Self.byKey.capture(in: inside)).subtracting(encoded)

        guard !properties.isEmpty, !keys.isEmpty else {
            throw Shape("parsed no properties or no coding keys — has the shape changed?")
        }

        var report = Report(
            summary:
                "\(properties.count) stored properties, \(keys.count) coding keys, "
                + "\(encoded.count) encoded")
        for missing in properties.subtracting(keys).sorted() {
            report.findings.append(
                "`\(missing)` is a stored property with no CodingKey; it can never be written")
        }
        for missing in properties.subtracting(encoded).sorted() {
            report.findings.append(
                "`\(missing)` is never encoded; it will not survive a restart")
        }
        // A key that is not a property is a legacy name kept to migrate FROM,
        // which is deliberate and documented — those are read and never
        // written.
        for stale in keys.subtracting(properties).subtracting(decoded).sorted() {
            report.findings.append(
                "CodingKey `\(stale)` is neither a property nor migrated from; it is stale")
        }
        return report
    }
}
