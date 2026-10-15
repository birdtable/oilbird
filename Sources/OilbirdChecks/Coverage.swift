import Foundation

/// What the suite EXECUTED, held against a recorded floor.
///
/// ⚠ The suite reports "N assertions, 0 failed" and that number says
/// nothing about reach. This one does: it is the share of the product's lines
/// the suite ran at all. The two answer different questions and the first was
/// standing in for the second.
///
/// `V-1`  Overall line coverage may not fall.
/// `V-2`  No module's line coverage may fall. A module-level floor catches
///        the case `V-1` cannot — a thousand covered lines added to `Core`
///        while `Kit` quietly loses fifty.
/// `V-3`  The files the suite never enters are LISTED, not counted. A new one
///        fails; one that gained coverage is a finding too, because a floor
///        for something that is no longer there is a floor for the next one
///        (DM-4).
///
/// Recorded rather than set to an aspiration: a threshold nobody can meet is
/// turned off within a week. `make coverage-budget` re-records.
///
/// ⚠ Needs `make coverage`, which builds the suite instrumented and runs it.
/// Without that export this SKIPS and says so — reporting the absence of a
/// measurement, never the absence of a problem.
struct Coverage: Check {
    let name = "coverage"
    let holds = "the suite's reach into the product, floored per module and per file"

    /// Where the floor is recorded.
    private static let budgetFile = "coverage-budget.txt"

    /// What `make coverage` writes: `llvm-cov export --summary-only`.
    private static let exportFile = "build/coverage/summary.json"

    /// One percentage, to a tenth. Integers thrash: 51.9 recorded as 51 lets
    /// ninety lines of this repository go uncovered without a word.
    private static func tenths(_ percent: Double) -> Int { Int((percent * 10).rounded(.down)) }

    private static func shown(_ value: Int) -> String {
        "\(value / 10).\(value % 10)%"
    }

    /// Covered over total, in tenths of a percent. No lines is 0%, never a
    /// division by zero dressed up as full coverage.
    private static func share(_ covered: Int, of total: Int) -> Int {
        total == 0 ? 0 : tenths(Double(covered) * 100 / Double(total))
    }

    /// One tenth of a percent, given away when the floor is recorded.
    ///
    /// ⚠ Not slack, and not rounding. The suite drives `oilbird` as a
    /// subprocess and some of those paths are timed, so two runs of the same
    /// commit differ by a line or two. Recorded at the measurement exactly,
    /// the gate would fail on a rerun that changed nothing — and a gate that
    /// fails at random is one somebody turns off, which is the state
    /// `.swiftlint.yml` says reads the same as passing. A tenth is about ten
    /// lines here, roughly ten times the jitter seen.
    private static let jitter = 1

    /// One file's line counts, as llvm-cov reports them.
    struct Measured {
        let path: String
        let covered: Int
        let total: Int
    }

    /// The module a source file belongs to: `Sources/<module>/...`.
    ///
    /// Read from the path and not from `Package.swift`, because the thing
    /// being measured is a path in the export and a target that stopped
    /// existing should read as a stale row rather than as a parse failure.
    static func module(of path: String) -> String? {
        // No leading slash: the export's paths are absolute and the budget's
        // are repository-relative, and this is asked of both.
        let parts = path.components(separatedBy: "Sources/")
        guard parts.count > 1 else { return nil }
        return parts[1].components(separatedBy: "/").first
    }

    /// `llvm-cov export --summary-only`, reduced to the product's own files.
    ///
    /// ⚠ Paths come back absolute and machine-specific. They are cut at
    /// `/Sources/` so a budget recorded on one checkout reads on another.
    static func measured(inExport json: String) throws -> [Measured] {
        guard let data = json.data(using: .utf8),
            let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sets = top["data"] as? [[String: Any]], let first = sets.first,
            let files = first["files"] as? [[String: Any]]
        else {
            throw Shape("\(exportFile) is not an llvm-cov export — has the format changed?")
        }
        var found: [Measured] = []
        for file in files {
            guard let absolute = file["filename"] as? String,
                let summary = file["summary"] as? [String: Any],
                let lines = summary["lines"] as? [String: Any],
                let covered = lines["covered"] as? Int, let total = lines["count"] as? Int
            else { continue }
            guard let cut = absolute.range(of: "/Sources/") else { continue }
            found.append(
                Measured(
                    path: "Sources/" + String(absolute[cut.upperBound...]),
                    covered: covered, total: total))
        }
        guard !found.isEmpty else {
            throw Shape("the export named no file under Sources — was it taken over the tests?")
        }
        return found
    }

    /// The recorded floor: an overall figure, one per module, and the files
    /// the suite is known never to enter.
    struct Budget {
        var overall = 0
        var perModule: [String: Int] = [:]
        var unexecuted: Set<String> = []
    }

    static func readBudget(_ text: String) -> Budget {
        var budget = Budget()
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("Sources/") {
                budget.unexecuted.insert(trimmed)
                continue
            }
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let value = Int(parts[0]) else { continue }
            if parts[1] == "overall" {
                budget.overall = value
            } else {
                budget.perModule[parts[1]] = value
            }
        }
        return budget
    }

    func selfTest() throws {
        let export = """
            {"data":[{"files":[
              {"filename":"/x/y/Sources/OilbirdCore/Fetch.swift",
               "summary":{"lines":{"covered":0,"count":99}}},
              {"filename":"/x/y/Sources/OilbirdCore/Ports.swift",
               "summary":{"lines":{"covered":30,"count":40}}},
              {"filename":"/x/y/Tests/OilbirdKitTests/PortsTests.swift",
               "summary":{"lines":{"covered":10,"count":10}}}
            ]}]}
            """
        let files = try Self.measured(inExport: export)
        guard files.count == 2, files.contains(where: { $0.path == "Sources/OilbirdCore/Fetch.swift" })
        else {
            throw SelfTest("the export was not cut at /Sources/, or a test file was measured")
        }
        guard Self.module(of: "Sources/OilbirdCore/Dependencies/JDKDependency.swift") == "OilbirdCore"
        else {
            throw SelfTest("a nested source file was not attributed to its module")
        }
        // 30 of 40 lines is 75.0%, and a floor recorded at 75.1 must refuse it
        // — a ratchet that rounds in the code's favour is not a ratchet.
        guard Self.tenths(75.0) == 750, Self.tenths(51.93) == 519 else {
            throw SelfTest("a percentage did not round down to a tenth")
        }
        let budget = Self.readBudget("# note\n519 overall\n647 OilbirdCore\nSources/a/B.swift\n")
        guard budget.overall == 519, budget.perModule["OilbirdCore"] == 647,
            budget.unexecuted == ["Sources/a/B.swift"]
        else {
            throw SelfTest("a recorded budget did not read back as it was written")
        }
        guard (try? Self.measured(inExport: "{\"data\":[]}")) == nil else {
            throw SelfTest("an export with no data was accepted")
        }
    }

    func run() throws -> Report {
        guard Checkout.exists(Self.exportFile) else {
            return Report(
                summary: "no \(Self.exportFile)",
                notes: [
                    "`make coverage` builds the suite instrumented and runs it. Nothing here "
                        + "measured anything, which is not the same as nothing being wrong."
                ],
                skipped: true)
        }
        guard let budgetText = try? Checkout.read(Self.budgetFile) else {
            throw Shape(
                "no \(Self.budgetFile). Run `make coverage-budget` to record what the suite "
                    + "reaches today; a floor invented rather than measured is one nobody meets")
        }
        let budget = Self.readBudget(budgetText)
        let files = try Self.measured(inExport: try Checkout.read(Self.exportFile))

        var report = Report(summary: "")
        var covered = 0
        var total = 0
        var byModule: [String: (covered: Int, total: Int)] = [:]
        var unexecuted: Set<String> = []

        for file in files {
            covered += file.covered
            total += file.total
            if let module = Self.module(of: file.path) {
                byModule[module, default: (0, 0)].covered += file.covered
                byModule[module, default: (0, 0)].total += file.total
            }
            if file.covered == 0 && file.total > 0 { unexecuted.insert(file.path) }
        }

        let overall = Self.share(covered, of: total)
        if overall < budget.overall {
            report.findings.append(
                "V-1  line coverage is \(Self.shown(overall)) against a floor of "
                    + "\(Self.shown(budget.overall)). The suite reaches less of the product "
                    + "than it did")
        }

        var measured: [String] = []
        for (module, counts) in byModule.sorted(by: { $0.key < $1.key }) {
            let percent = Self.share(counts.covered, of: counts.total)
            measured.append("\(module) \(Self.shown(percent))")
            guard let floor = budget.perModule[module] else {
                report.findings.append(
                    "V-2  \(module) is measured at \(Self.shown(percent)) and has no floor. Run "
                        + "`make coverage-budget` so a new module starts where it is rather "
                        + "than at zero")
                continue
            }
            if percent < floor {
                report.findings.append(
                    "V-2  \(module) is \(Self.shown(percent)) against a floor of "
                        + "\(Self.shown(floor))")
            }
        }
        for module in budget.perModule.keys.sorted() where byModule[module] == nil {
            report.findings.append(
                "V-2  \(module) has a floor and was not measured; the row is stale")
        }

        for file in unexecuted.subtracting(budget.unexecuted).sorted() {
            report.findings.append(
                "V-3  \(file)  shipped with no test that enters it. Either the suite reaches "
                    + "it or the budget says out loud that it does not")
        }
        // The good news is a finding too: a floor for something no longer
        // there is a floor for the next one (DM-4).
        for file in budget.unexecuted.subtracting(unexecuted).sorted() {
            let why = Checkout.exists(file) ? "is executed now" : "does not exist"
            report.findings.append(
                "V-3  \(file)  is budgeted as unexecuted and \(why). Re-record — an allowance "
                    + "nothing matches is an allowance for the next one")
        }

        report.summary =
            "\(covered)/\(total) lines \(Self.shown(overall)) (floor \(Self.shown(budget.overall)))"
            + ", \(unexecuted.count) file(s) never entered — " + measured.joined(separator: ", ")
        return report
    }

    /// The budget file this repository has today, for `make coverage-budget`.
    static func recordBudget() throws -> String {
        guard Checkout.exists(exportFile) else {
            throw Shape("no \(exportFile). Run `make coverage` first — there is nothing to record")
        }
        let files = try measured(inExport: try Checkout.read(exportFile))
        var covered = 0
        var total = 0
        var byModule: [String: (covered: Int, total: Int)] = [:]
        var unexecuted: [String] = []
        for file in files {
            covered += file.covered
            total += file.total
            if let module = module(of: file.path) {
                byModule[module, default: (0, 0)].covered += file.covered
                byModule[module, default: (0, 0)].total += file.total
            }
            if file.covered == 0 && file.total > 0 { unexecuted.append(file.path) }
        }
        var lines = [
            "# How far the suite reaches, recorded rather than wished for.",
            "#",
            "# `N assertions, 0 failed` says nothing about reach. These are the",
            "# lines the suite actually ran, as a floor: every number may go up and",
            "# none may go down. Tenths of a percent, because whole percents let",
            "# ninety lines of this repository go quiet without a word.",
            "#",
            "# Each figure is recorded one tenth UNDER what was measured. The suite",
            "# drives the CLI as a subprocess and some of those paths are timed, so",
            "# two runs of one commit differ by a line; a gate that fails on a rerun",
            "# that changed nothing is a gate somebody turns off.",
            "#",
            "# `make coverage` measures. `make coverage-budget` re-records, and doing",
            "# that to make room for a test you did not write is how a floor becomes",
            "# a ceiling.",
            "",
            "\(max(0, share(covered, of: total) - jitter)) overall",
            "",
        ]
        for (module, counts) in byModule.sorted(by: { $0.key < $1.key }) {
            lines.append("\(max(0, share(counts.covered, of: counts.total) - jitter)) \(module)")
        }
        lines.append("")
        lines.append("# Files no test enters at all. This list is the work queue, and")
        lines.append("# a file that leaves it must leave this file too.")
        lines.append("")
        lines.append(contentsOf: unexecuted.sorted())
        return lines.joined(separator: "\n") + "\n"
    }
}
