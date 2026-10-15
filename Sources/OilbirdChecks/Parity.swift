import Foundation

/// The two surfaces stay level with each other.
///
/// MCP adds no capability the CLI lacks — if a behaviour exists only in MCP,
/// that is a defect. As a sentence that is an opinion. This is the check.
///
/// Both surfaces are published contracts the moment an agent or a script
/// depends on them (scripts and agents branch on them), so they must not drift apart
/// quietly. The mapping is `oilbird_<verb>` to `<verb>`.
struct Parity: Check {
    let name = "parity"
    let holds = "every MCP tool has a CLI verb, every verb is offered, and both are discoverable"

    private static let mcp = "Sources/OilbirdMCP/OilbirdMCP.swift"
    private static let cli = "Sources/OilbirdCLI/OilbirdCLI.swift"
    private static let usage = "Sources/OilbirdCLI/Usage.swift"
    private static let screens = "Sources/OilbirdKit/Screens.swift"
    /// The settings window cannot see `OilbirdMCP` — an executable target — so
    /// the Agents pane counts `Oilbird.mcpToolNames` instead of writing "Eleven
    /// tools" in prose, which is what it did until the eleventh tool arrived.
    /// That list is now the thing that can go stale, so it is held here too.
    private static let names = "Sources/OilbirdKit/AgentAccess.swift"

    /// A tool the CLI expresses under a different name. Each needs a reason,
    /// and an entry that matches nothing is stale — there the zero IS the
    /// finding (DM-4).
    private static let aliases = ["oilbird_quality_gate": "gate"]

    /// ⚠ A verb hidden from `--help` needs a reason, and an exemption matching
    /// nothing is stale (DM-4).
    private static let unlisted = [
        "cli-uninstall": """
        the inverse of cli-install, offered by the button in Settings that \
        installed it; a help screen listing both ways to undo a symlink is \
        noise at the moment somebody is looking for what Oilbird DOES
        """
    ]

    /// A CLI verb with no tool. Each needs a reason; an exemption matching
    /// nothing is stale (DM-4).
    private static let cliOnly = [
        "install": "an agent should not start a 1.14 GB download; it calls a tool that needs it",
        "up": "agents do not manage the lifetime; every tool starts the engine on demand",
        "down": "same — and an agent must not stop an engine another client is using",
        "watch": "the idle watchdog's own body, not a capability",
        "idle": "a user setting, not an agent's to change",
        "cli-install": "puts a symlink on PATH; meaningless to an agent",
        "cli-uninstall": "as above",
    ]

    private static let tool = Rx("\"name\":\\s*\"(oilbird_\\w+)\"")
    /// Exactly four spaces, and hyphens allowed. `\s*` also matched
    /// `case "present"` inside the doctor rendering's own switch, and `\w+`
    /// missed `cli-install` entirely — so the gate was reading two states as
    /// verbs and losing two real ones. It found both the moment it was pointed
    /// in this direction.
    private static let verb = Rx("^    case \"([\\w-]+)\":", [.anchorsMatchLines])
    /// The head of a switch at the same indentation as the cases above, used
    /// to tell one switch's cases from another's.
    private static let switchHead = Rx("^    switch ", [.anchorsMatchLines])
    private static let quoted = Rx("\"([\\w-]+)\"")
    private static let menuBlock = Rx(
        "static func menuRows\\(.*?\\n    \\}", [.dotMatchesLineSeparators])
    private static let menuVerb = Rx("MenuRow\\(\\s*\\n?\\s*verb: \"([\\w-]+)\"")
    private static let section = Rx(
        "let \\w+: \\[Row\\] = \\[(.*?)\\n        \\]", [.dotMatchesLineSeparators])
    private static let codeSection = Rx(
        "let code: \\[Row\\] = \\[(.*?)\\n        \\]", [.dotMatchesLineSeparators])
    private static let action = Rx("\\{action\\|([\\w-]+)\\}")
    private static let needEngine = Rx(
        "needEngine: Set<String> = \\[(.*?)\\]", [.dotMatchesLineSeparators])
    private static let toolNames = Rx("mcpToolNames\\s*=\\s*\\[(.*?)\\]", [.dotMatchesLineSeparators])
    private static let toolName = Rx("\"(oilbird_\\w+)\"")

    func selfTest() throws {
        guard Self.tool.matches("\"name\": \"oilbird_status\",") else {
            throw SelfTest("an MCP tool name was not read")
        }
        guard Self.verb.matches("    case \"cli-install\":\n") else {
            throw SelfTest("a hyphenated CLI verb was not read")
        }
        guard !Self.verb.matches("        case \"present\":\n") else {
            throw SelfTest("an indented switch case was read as a verb")
        }
        guard Self.action.matches("{action|summary}") else {
            throw SelfTest("a help screen's action was not read")
        }
    }

    /// Each case label that repeats inside one switch, with the line of the

    /// `Usage.verbs` is the same set the CLI dispatches.
    ///
    /// ⚠ It exists only to suggest a nearest match for a typo, which makes it
    /// exactly the kind of list that rots unnoticed: a verb missing from it
    /// costs nothing visible, and then one day `oilbird stauts` suggests
    /// nothing at all. Held against the switch that actually dispatches.
    private static func usageVerbs(
        _ usageText: String, verbs: Set<String>, into report: inout Report
    ) throws {
        guard !usageText.isEmpty else { return }
        let parts = usageText.components(separatedBy: "static let verbs")
        guard parts.count > 1, let block = parts[1].components(separatedBy: "]").first else {
            throw Shape("Usage.verbs is gone, or has changed shape")
        }
        let listed = Set(Self.quoted.capture(in: block as NSString))
        for missing in verbs.subtracting(listed).sorted() {
            report.findings.append(
                "Usage.verbs is missing '\(missing)', so a typo of it suggests nothing")
        }
        for extra in listed.subtracting(verbs).sorted() {
            report.findings.append(
                "Usage.verbs lists '\(extra)', which the CLI does not accept")
        }
    }

    /// Every tool has a verb, every verb an agent should reach has a tool, and
    /// the settings window counts the same list MCP publishes.
    ///
    /// ⚠ The second direction is the one that drifts. "MCP adds no
    /// capability the CLI lacks" is one-directional, and it stays clean
    /// while the CLI gains verbs and MCP gains none — leaving an agent unable
    /// to ask, for instance, whether the engine is running.
    ///
    /// - Returns: the tools the settings window counts, for the summary line.
    private static func acrossSurfaces(
        tools: Set<String>, verbs: Set<String>, names namesText: NSString,
        into report: inout Report
    ) throws -> Set<String> {
        for published in tools.sorted() {
            let expected = Self.aliases[published] ?? String(published.dropFirst("oilbird_".count))
            if !verbs.contains(expected) {
                report.findings.append(
                    "\(published) has no CLI verb '\(expected)' — a behaviour only agents can "
                        + "reach")
            }
        }
        for (alias, mapped) in Self.aliases.sorted(by: { $0.key < $1.key })
        where !tools.contains(alias) {
            report.findings.append("alias \(alias) -> \(mapped) matched no tool; it is stale")
        }

        // And the other direction, which is the one that drifted: the rule
        // above is one-directional by design, so it stays clean while the CLI
        // gains verbs and MCP gains none.
        for dispatched in verbs.sorted() {
            if Self.aliases.values.contains(dispatched) { continue }
            if tools.contains("oilbird_\(dispatched)") { continue }
            if Self.cliOnly[dispatched] != nil { continue }
            report.findings.append(
                "CLI verb '\(dispatched)' has no oilbird_\(dispatched) tool and no reason to be "
                    + "CLI-only — agents cannot do what the terminal can")
        }
        for (exempt, _) in Self.cliOnly.sorted(by: { $0.key < $1.key }) where !verbs.contains(exempt) {
            report.findings.append("CLI-only exemption '\(exempt)' matches no verb; it is stale")
        }

        // And the list the window counts, which is in a third file because a
        // library target is the only one both an executable and a test can see.
        guard let counting = Self.toolNames.first(in: namesText)?.group(1) else {
            throw Shape("Oilbird.mcpToolNames is gone — the Agents pane counts nothing")
        }
        let counted = Set(Self.toolName.capture(in: counting as NSString))
        for uncounted in tools.subtracting(counted).sorted() {
            report.findings.append(
                "\(uncounted) is published but missing from Oilbird.mcpToolNames")
        }
        for phantom in counted.subtracting(tools).sorted() {
            report.findings.append(
                "Oilbird.mcpToolNames counts \(phantom), which oilbird-mcp does not publish")
        }
        return counted
    }

    /// repeat.
    private static func duplicateCases(in text: NSString) -> [(line: Int, verb: String)] {
        var boundaries = Self.switchHead.hits(in: text).map(\.start)
        boundaries.append(text.length)
        var repeats: [(line: Int, verb: String)] = []
        for (index, start) in boundaries.enumerated().dropLast() {
            let end = boundaries[index + 1]
            var seen: Set<String> = []
            for hit in Self.verb.hits(in: text, from: start) where hit.start < end {
                guard let name = hit.group(1) else { continue }
                if !seen.insert(name).inserted {
                    repeats.append((Line.of(hit.start, in: text), name))
                }
            }
        }
        return repeats
    }

    func run() throws -> Report {
        let mcpText = try Checkout.read(Self.mcp) as NSString
        let cliText = try Checkout.read(Self.cli) as NSString
        let namesText = try Checkout.read(Self.names) as NSString

        let tools = Set(Self.tool.capture(in: mcpText))
        let verbs = Set(Self.verb.capture(in: cliText))
        guard !tools.isEmpty, !verbs.isEmpty else {
            throw Shape("found no tools or no verbs — has a surface changed shape?")
        }

        var report = Report(summary: "")

        // ⚠ A verb dispatched TWICE in one switch compiles, and the second
        // block is unreachable, so an edit made there changes nothing. Every
        // other rule here collects verbs into a set and cannot see it.

        // Grouped by enclosing switch: two switches in that file legitimately
        // answer the same verb, so only a repeat within ONE is the defect.
        for (line, duplicated) in Self.duplicateCases(in: cliText) {
            report.findings.append(
                "`oilbird \(duplicated)` is dispatched twice in the same switch — the second "
                    + "block at line \(line) is unreachable, and an edit made there does "
                    + "nothing")
        }

        // ⚠ `Usage.verbs` only suggests a nearest match, so a verb missing
        // from it costs nothing visible until `oilbird stauts` suggests
        // nothing. Held against the switch that dispatches.
        let usageText = Checkout.exists(Self.usage) ? try Checkout.read(Self.usage) : ""
        try Self.usageVerbs(usageText, verbs: verbs, into: &report)

        // ⚠ And the menu, where the failure is worse: a row naming a verb the
        // switch lacks offers a choice that cannot be run, and one that runs
        // the wrong thing is worse still.

        // One direction only. Every menu row must be a verb; not every verb
        // belongs in a menu, and one listing everything is a help screen with
        // extra steps.
        var offered: Set<String> = []
        let screensText = Checkout.exists(Self.screens) ? try Checkout.read(Self.screens) : ""
        if !screensText.isEmpty {
            let subject = screensText as NSString
            guard let menu = Self.menuBlock.first(in: subject)?.group(0) else {
                throw Shape("UI.menuRows is gone — bare `oilbird` offers nothing")
            }
            offered = Set(Self.menuVerb.capture(in: menu as NSString))
            guard !offered.isEmpty else {
                throw Shape("UI.menuRows parsed to no verbs — has the shape changed?")
            }
            for row in offered.subtracting(verbs).sorted() {
                report.findings.append(
                    "the menu offers '\(row)', which the CLI does not dispatch — a row that "
                        + "runs nothing")
            }
        }

        // ⚠ And the group `--help` makes a promise about. A count in prose is
        // unfalsifiable — "the first six need an engine" over a section of
        // seven — so the screen names the SECTION and this holds it.
        if !screensText.isEmpty && !usageText.isEmpty {
            guard let look = Self.codeSection.first(in: screensText as NSString)?.group(1),
                let promised = Self.needEngine.first(in: usageText as NSString)?.group(1)
            else {
                throw Shape("the LOOK AT CODE section or Usage.needEngine is gone")
            }
            let listedInHelp = Set(Self.action.capture(in: look as NSString))
            let startsOne = Set(Self.quoted.capture(in: promised as NSString))
            guard !listedInHelp.isEmpty, !startsOne.isEmpty else {
                throw Shape("parsed no verbs from LOOK AT CODE or Usage.needEngine")
            }
            for promisedVerb in listedInHelp.subtracting(startsOne).sorted() {
                report.findings.append(
                    "--help lists '\(promisedVerb)' under LOOK AT CODE, which promises it "
                        + "starts an engine, but Usage.needEngine does not — the wait would be "
                        + "drawn for every verb but that one")
            }
            for silent in startsOne.subtracting(listedInHelp).sorted() {
                report.findings.append(
                    "Usage.needEngine starts an engine for '\(silent)', which --help does not "
                        + "list under LOOK AT CODE — a 1.6 GB side effect the screen does not "
                        + "mention")
            }
        }

        // ⚠ And every verb is DISCOVERABLE: `configure` shipped dispatching,
        // registered and held by every rule above, and absent from `--help`.
        // A verb nobody can find is a verb that does not exist.
        var listedAnywhere: Set<String> = []
        for block in Self.section.capture(in: screensText as NSString) {
            listedAnywhere.formUnion(Self.action.capture(in: block as NSString))
        }
        if !listedAnywhere.isEmpty {
            for hidden in verbs.subtracting(listedAnywhere).subtracting(Self.unlisted.keys).sorted() {
                report.findings.append(
                    "`oilbird \(hidden)` is dispatched but is in no section of --help, so "
                        + "nobody can find it")
            }
            for (exempt, _) in Self.unlisted.sorted(by: { $0.key < $1.key }) {
                if !verbs.contains(exempt) {
                    report.findings.append(
                        "the unlisted exemption for '\(exempt)' matches no verb; it is stale")
                } else if listedAnywhere.contains(exempt) {
                    report.findings.append(
                        "'\(exempt)' is exempted from --help and listed in it anyway")
                }
            }
        }

        let counted = try Self.acrossSurfaces(
            tools: tools, verbs: verbs, names: namesText, into: &report)

        report.summary =
            "\(tools.count) MCP tools against \(verbs.count) CLI verbs, \(counted.count) counted "
            + "by the settings window, \(offered.count) offered by the menu"
        return report
    }
}
