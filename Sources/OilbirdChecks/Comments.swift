import Foundation

/// This repository's commenting rules, as an instrument rather than an opinion.
///
/// A rule nobody can check is an opinion, so these are the five that can be
/// checked, against Swift.
///
/// ⚠ Existing comments are not swept. They are rewritten when the code
/// beneath them is touched, so the change is reviewable in the same diff as
/// the behaviour it describes. That is why `C-4` and `C-5` are ratchets
/// against a recorded budget rather than a flat threshold: the existing
/// blocks are allowed to stay and may only go down, and a file that gains
/// one fails today.
///
/// `C-1`  No decoration. A comment of rule characters with no words carries
///        nothing. A HEADING with a rule trailing off it is fine — the
///        heading text is the information.
/// `C-2`  No commented-out code. Version control has it.
/// `C-3`  A `TODO` names what makes it removable. A `TODO` with no reference
///        is a note to nobody; a person's name is not a reference.
/// `C-4`  Inline block length, capped at three lines, ratcheted per file.
///        ⚠ INLINE only. The reason for the cap is that a longer inline
///        comment is usually a fact with a home elsewhere: move it and link.
///        For a doc comment the interface IS that home — what `nil` means,
///        what is thrown, what is mutated, who owns the resource — so doc
///        comments have no length rule.
/// `C-5`  Emphasis inflation: if most comments are marked critical, none are.
///        Ratcheted on the whole repository, because the rule is about the
///        proportion and a per-file figure would say nothing.
struct Comments: Check {
    let name = "comments"
    let holds = "no decoration, no commented-out code, tracked TODOs, and a comment budget"

    /// Where the per-file budget and the emphasis ratio are recorded.
    private static let budgetFile = "comments-budget.txt"

    /// Three lines, per `C-4`. A block is its `//` or `///` lines,
    /// consecutive, at one indentation.
    private static let cap = 3

    /// The mark this repository uses for "read this or you will reintroduce
    /// the defect". Counted because `C-5` bans inflating it.
    private static let emphasis = "⚠"

    /// A comment line that is only rule characters. Words anywhere in it and
    /// it is a heading, which is allowed.
    private static func isDecoration(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.contains { $0.isLetter || $0.isNumber }
            && trimmed.count >= 4
    }

    /// A comment line that parses as a statement.
    ///
    /// ⚠ Deliberately narrow. A rule that guesses wrongly here deletes a
    /// sentence somebody wrote, and prose about code quotes code constantly —
    /// this file's own comments name `TODO`, `C-4` and `//`. So both halves
    /// must hold: it opens like a statement AND it closes like one, with no
    /// prose punctuation between. A line of prose that happens to start with
    /// `return` does not end in a brace or a semicolon.
    private static let statementOpener = Rx(
        "^(let|var|func|if|guard|return|for|while|switch|case|import|struct|class|enum|"
            + "extension|print|try|await|throw|defer)\\b")
    private static func isCommentedOutCode(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard statementOpener.matches(trimmed) else { return false }
        guard trimmed.hasSuffix("{") || trimmed.hasSuffix("}") || trimmed.hasSuffix(";") else {
            return false
        }
        // Prose ends in a full stop or a comma before its brace far more often
        // than code does, and a sentence with a comma in it is prose.
        return !trimmed.contains(". ") && !trimmed.contains(", ")
    }

    /// A `TODO` and the reference that makes it removable. The shapes this
    /// repository keys work on: `ABC-12`, `area/12`, `area/kind/12`, or a bare
    /// issue URL.
    /// ⚠ The MARKER, not the word, and never one inside backticks. This file
    /// names `TODO` a dozen times while describing the rule, and both earlier
    /// versions of this line reported their own prose.
    private static let todo = Rx("^\\s*TODO\\b|\\bTODO\\s*[:(]")
    /// A backtick span in a comment is a quotation, not the thing quoted.
    private static let quoted = Rx("`[^`]*`")
    private static let tracked = Rx(
        "\\b[A-Z]{1,4}-\\d+\\b|\\b[a-z]+/[a-z-]+/\\d+\\b|\\b[a-z]+/\\d+\\b|https?://")

    /// One run of comment lines, and where it starts.
    private struct Block {
        let line: Int
        var bodies: [String]
        var isDoc: Bool
    }

    /// ⚠ A run of `///` and a run of `//` are two blocks even when adjacent,
    /// because `C-4` asks a different question of each and a doc comment with
    /// an implementation note under it is two facts, not one.
    private static func blocks(in text: String) -> [Block] {
        var found: [Block] = []
        var current: Block?
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else {
                if let block = current { found.append(block) }
                current = nil
                continue
            }
            let isDoc = trimmed.hasPrefix("///")
            let body = String(trimmed.drop(while: { $0 == "/" }))
            if current == nil || current?.isDoc != isDoc {
                if let block = current { found.append(block) }
                current = Block(line: index + 1, bodies: [body], isDoc: isDoc)
            } else {
                current?.bodies.append(body)
            }
        }
        if let block = current { found.append(block) }
        return found
    }

    /// The recorded budget: how many over-cap blocks each file is allowed, and
    /// the emphasis ratio the repository may not exceed.
    private struct Budget {
        var perFile: [String: Int] = [:]
        var emphasisPercent: Int = 100
    }

    private static func readBudget() -> Budget? {
        guard let text = try? Checkout.read(budgetFile) else { return nil }
        var budget = Budget()
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[1] == "emphasis-percent" {
                budget.emphasisPercent = Int(parts[0]) ?? 100
            } else if let count = Int(parts[0]) {
                budget.perFile[parts[1]] = count
            }
        }
        return budget
    }

    func selfTest() throws {
        guard Self.isDecoration("─────────────"), Self.isDecoration("=========") else {
            throw SelfTest("a rule of box characters was not read as decoration")
        }
        guard !Self.isDecoration("── Route table ────"), !Self.isDecoration("") else {
            throw SelfTest("a heading was read as decoration")
        }
        guard Self.isCommentedOutCode("let x = compute(y)") == false,
            Self.isCommentedOutCode("guard let winner = best else {"),
            Self.isCommentedOutCode("return best?.name;")
        else {
            throw SelfTest("commented-out code was not recognised")
        }
        guard !Self.isCommentedOutCode("return the shortest prefix that claims it."),
            !Self.isCommentedOutCode("if the server did not answer, this is nil, not false.")
        else {
            throw SelfTest("a sentence was read as commented-out code")
        }
        guard Self.todo.matches("TODO: fix"), !Self.tracked.matches("TODO: fix"),
            Self.tracked.matches("TODO: GH-29 — once the register lands")
        else {
            throw SelfTest("TODO hygiene did not separate a tracked note from an untracked one")
        }
        let prose = Self.quoted.strip(from: "naming `TODO: do it` is not a TODO")
        guard !Self.todo.matches(prose), !Self.todo.matches("A `TODO` is banned.") else {
            throw SelfTest("the word TODO in prose was read as a TODO marker")
        }
        // C-4 asks a different question of `///` than of `//`, so the split
        // has to hold or the cap silently applies to both again.
        let mixed = Self.blocks(
            in: "/// one\n/// two\n/// three\n/// four\n// five\n// six\ncode()\n")
        guard mixed.count == 2, mixed[0].isDoc, mixed[0].bodies.count == 4,
            !mixed[1].isDoc, mixed[1].bodies.count == 2
        else {
            throw SelfTest(
                "a doc run and an inline run under it were not read as two blocks: "
                    + mixed.map { "\($0.isDoc ? "doc" : "inline")×\($0.bodies.count)" }
                    .joined(separator: ", "))
        }
    }

    func run() throws -> Report {
        guard let budget = Self.readBudget() else {
            throw Shape(
                "no \(Self.budgetFile). Run `make comments-budget` to record what is there "
                    + "today; without it this would demand a sweep the standard forbids")
        }

        var report = Report(summary: "")
        var totalBlocks = 0
        var docBlocks = 0
        var emphasised = 0
        var overCap: [String: Int] = [:]

        for file in Checkout.swiftFiles(under: "Sources") + Checkout.swiftFiles(under: "Tests") {
            let text = try Checkout.read(file)
            for block in Self.blocks(in: text) {
                totalBlocks += 1
                if block.bodies.contains(where: { $0.contains(Self.emphasis) }) { emphasised += 1 }

                for (offset, body) in block.bodies.enumerated() {
                    let at = "\(file):\(block.line + offset)"
                    if Self.isDecoration(body) {
                        report.findings.append(
                            "C-1  \(at)  a comment of rule characters with no words in it")
                    }
                    if Self.isCommentedOutCode(body) {
                        report.findings.append(
                            "C-2  \(at)  commented-out code; version control has it")
                    }
                    // Looked for across the block: a marker and the id it
                    // names are routinely two lines apart.
                    let whole = block.bodies.joined(separator: " ")
                    if Self.todo.matches(Self.quoted.strip(from: body)),
                        !Self.tracked.matches(whole)
                    {
                        report.findings.append(
                            "C-3  \(at)  a TODO with nothing that says when it can go")
                    }
                }

                if block.isDoc {
                    docBlocks += 1
                } else if block.bodies.count > Self.cap {
                    overCap[file, default: 0] += 1
                }
            }
        }

        for (file, count) in overCap.sorted(by: { $0.key < $1.key }) {
            let allowed = budget.perFile[file] ?? 0
            if count > allowed {
                report.findings.append(
                    "C-4  \(file)  has \(count) inline comment block(s) over \(Self.cap) lines "
                        + "and is budgeted \(allowed). The standard says do not sweep — rewrite "
                        + "the ones under the code you touched, and the budget goes down")
            }
        }
        // A file that lost its over-cap blocks and kept its budget is an
        // allowance for something that is no longer there (DM-4).
        for (file, allowed) in budget.perFile.sorted(by: { $0.key < $1.key }) {
            guard allowed > 0 else { continue }
            let actual = overCap[file] ?? 0
            if !Checkout.exists(file) {
                report.findings.append(
                    "C-4  \(file) is budgeted \(allowed) and does not exist; the row is stale")
            } else if actual < allowed {
                report.findings.append(
                    "C-4  \(file)  is budgeted \(allowed) over-cap inline block(s) and now has "
                        + "\(actual). Lower the budget — an allowance for something that is no "
                        + "longer there is an allowance for the next one")
            }
        }

        let percent = totalBlocks == 0 ? 0 : emphasised * 100 / totalBlocks
        if percent > budget.emphasisPercent {
            report.findings.append(
                "C-5  \(percent)% of comment blocks carry \(Self.emphasis), against a budget of "
                    + "\(budget.emphasisPercent)%. If most comments are marked critical, none "
                    + "are")
        }

        report.summary =
            "\(totalBlocks) comment blocks (\(docBlocks) doc, uncapped), "
            + "\(overCap.values.reduce(0, +)) inline over \(Self.cap) lines, "
            + "\(percent)% marked \(Self.emphasis) (budget \(budget.emphasisPercent)%)"
        return report
    }

    /// The budget file this repository has today, for `make comments-budget`.
    static func recordBudget() throws -> String {
        var totalBlocks = 0
        var emphasised = 0
        var overCap: [String: Int] = [:]
        for file in Checkout.swiftFiles(under: "Sources") + Checkout.swiftFiles(under: "Tests") {
            let text = try Checkout.read(file)
            for block in blocks(in: text) {
                totalBlocks += 1
                if block.bodies.contains(where: { $0.contains(emphasis) }) { emphasised += 1 }
                if !block.isDoc && block.bodies.count > cap { overCap[file, default: 0] += 1 }
            }
        }
        let percent = totalBlocks == 0 ? 0 : emphasised * 100 / totalBlocks
        var lines = [
            "# What the commenting rules are owed, recorded rather than swept.",
            "#",
            "# Comments are not swept: they are rewritten when the code",
            "# beneath them is touched, so the change is reviewable in the same diff as",
            "# the behaviour it describes. This file is what that costs -- every number",
            "# here is a debt, and the `comments` check fails if one goes up.",
            "#",
            "# `make comments-budget` re-records it. Doing that to make room for",
            "# something you just wrote is how a budget becomes a place to hide.",
            "#",
            "# INLINE blocks only. A doc comment's home for a fact IS the",
            "# interface, so a doc comment has no length rule, and the cap",
            "# belongs to `//`.",
            "",
            "\(percent) emphasis-percent",
            "",
        ]
        for (file, count) in overCap.sorted(by: { $0.key < $1.key }) {
            lines.append("\(count) \(file)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
