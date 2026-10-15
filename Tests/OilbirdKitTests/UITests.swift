import Foundation
import OilbirdCore
import OilbirdKit

/// The design system's rules, held as tests rather than as prose.
///
/// Every one of these is a rule Oilbird's design states and a defect somebody
/// actually shipped. They live here — and the type lives in Kit — because an
/// executable target cannot be `@testable import`-ed (SwiftPM #7596), so a
/// design system written in `Sources/OilbirdCLI` would be untestable by
/// construction.
func uiTests() {
    Harness.suite("UI — presentation is what only exists at a known terminal") {
        let rich = UI(columns: 96, rich: true)
        let plain = UI.piped

        // ⚠ The rule everything else follows from. An escape in a CI
        // transcript is noise that makes the output HARDER to read, and an
        // agent pipes this CLI constantly.
        Harness.test("a pipe gets no escape at all") {
            let markup = "  {bad|FAIL}  {body|scanner}{note|   7.3.0.5189}"
            Harness.expectTrue(
                !plain.line(markup).contains("\u{1B}"), "a pipe received an escape")
            Harness.expectEqual(
                plain.line(markup), "  FAIL  scanner   7.3.0.5189",
                "the plain form is not the text without the markup")
        }

        Harness.test("a terminal with colour gets the paint") {
            let painted = rich.line("{bad|FAIL}")
            Harness.expectEqual(painted, "\u{1B}[31mFAIL\u{1B}[0m")
        }

        // ⚠ Eight-colour SGR only. Truecolour, 256-colour and backgrounds all
        // render differently in Terminal.app, a CI log and over ssh, and no
        // design idea here is worth losing that.
        Harness.test("every role is an eight-colour SGR parameter") {
            let allowed: Set<String> = ["1", "31", "32", "33", "36", "90", "91", "93"]
            for role in UI.Role.allCases where role != .body {
                let painted = rich.line("{\(role.rawValue)|x}")
                let code =
                    painted
                    .replacingOccurrences(of: "\u{1B}[", with: "")
                    .components(separatedBy: "m").first ?? ""
                Harness.expectTrue(
                    allowed.contains(code), "\(role.rawValue) paints with SGR \(code)")
            }
            // ⚠ `body` emits NO escape, which is the point of the palette: if
            // everything is coloured nothing is, so the reader's own
            // foreground stands and five roles carry all the meaning.
            Harness.expectEqual(rich.line("{body|x}"), "x", "the default role painted something")
        }

        // ⚠ Styles every recovery sentence in `OilbirdError` without editing
        // one of them. The backticks come back unpainted, or they would be
        // carrying the emphasis twice.
        Harness.test("backticks in an existing message become the action role") {
            let message = "Try `oilbird up`, then this again."
            Harness.expectEqual(
                rich.line(message),
                "Try \u{1B}[36moilbird up\u{1B}[0m, then this again.",
                "a backticked command was not painted, or the ticks were not removed")
            Harness.expectEqual(
                plain.line(message), "Try `oilbird up`, then this again.",
                "the backticks did not come back when there was no paint")
        }

        Harness.test("backticks inside a role token are still found") {
            let spans = UI.spans("{body|Try `oilbird up` now}")
            Harness.expectEqual(spans.count, 3)
            Harness.expectEqual(spans[1].role, .action)
            Harness.expectEqual(spans[1].text, "oilbird up")
            Harness.expectTrue(spans[1].quoted, "the run did not remember it was backticked")
        }

        // A markup language that mangles its own input is worse than none. A
        // project key, a scanner message and a JSON fragment all reach this.
        Harness.test("text that is not markup survives unchanged") {
            for awkward in [
                "a { brace", "an unclosed {note|token", "one ` tick", "{nosuchrole|x}",
                #"{"project": "x"}"#,
            ] {
                Harness.expectEqual(
                    plain.line(awkward), awkward, "markup mangled \(awkward)")
            }
        }

        // ⚠ The classic miscount in hand-rolled padding. Every screen in this
        // design has an em dash in it, and a byte count puts every aligned
        // column two cells out of true.
        Harness.test("width is measured in display cells, not bytes") {
            Harness.expectEqual(plain.cells("—"), 1, "an em dash is one cell")
            Harness.expectEqual("—".utf8.count, 3, "and three bytes, which is the trap")
            Harness.expectEqual(plain.cells("日本"), 4, "a wide glyph is two cells")
            Harness.expectEqual(rich.cells("{bad|FAIL}"), 4, "markup is not part of the width")
        }

        // ⚠ The backticked run is two cells narrower with the paint than
        // without it, so padding that ignores the capability is wrong in one
        // of the two modes — always.
        Harness.test("padding accounts for backticks coming back") {
            Harness.expectEqual(rich.cells("`up`"), 2)
            Harness.expectEqual(plain.cells("`up`"), 4)
            Harness.expectEqual(rich.cells(rich.pad("`up`", to: 10)), 10)
            Harness.expectEqual(plain.cells(plain.pad("`up`", to: 10)), 10)
        }

        // ⚠ Without a gutter a right-aligned cell fills its width and touches
        // the next column: `1m 12s~/src/storefront`. Invisible while every
        // column has slack, and there the moment one does not.
        Harness.test("table columns never touch") {
            let rows = plain.table(
                headers: ["project", "for", "path"],
                rows: [["storefront", "1m 12s", "~/src/storefront"]],
                align: [.left, .right, .left])
            Harness.expectEqual(rows.count, 2)
            Harness.expectTrue(
                rows[1].contains("1m 12s  ~/src/storefront"),
                "a right-aligned cell touched the next column: \(rows[1])")
        }

        Harness.test("table columns are sized to their content, not truncated") {
            let key = "storefront-wt-filters-inline-9af0"
            let rows = plain.table(headers: ["project"], rows: [[key]])
            Harness.expectTrue(
                rows[1].contains(key), "the key a person has to type was truncated")
        }

        // ⚠ The biggest defect this exists to fix. A long message wrapped back
        // to column ZERO, so its second line sat flush against the left margin
        // and read as the next check.
        Harness.test("a continuation line carries a hanging indent") {
            let narrow = UI(columns: 40, rich: false)
            let lines = narrow.wrap(
                "The fixture analysis did not reach the server and nothing was changed.",
                hanging: 6)
            Harness.expectTrue(lines.count > 1, "nothing wrapped at 40 columns")
            for line in lines.dropFirst() {
                Harness.expectTrue(
                    line.hasPrefix("      "), "a continuation line lost the indent: '\(line)'")
            }
        }

        // ⚠ Almost every over-long token here is a path, a URL or a command,
        // and all three exist to be copied. A path broken across two lines is
        // a path that cannot be double-clicked.
        Harness.test("a word is never broken") {
            let narrow = UI(columns: 30, rich: false)
            let path = "/Users/firstname.last@example.com/src/oilbird"
            let lines = narrow.wrap("see " + path + " now")
            Harness.expectTrue(
                lines.contains { $0.contains(path) }, "a path was split across lines: \(lines)")
        }

        // ⚠ A splitter that emits a space only for an empty piece deletes
        // every ordinary gap, because one space between two words produces no
        // empty piece: "Add at least one assertion" arrives as one word.
        Harness.test("wrapping puts the spaces back between the words") {
            let sentence = "Add at least one assertion to this test case."
            let wide = UI(columns: 96, rich: false)
            Harness.expectEqual(
                wide.wrap(sentence).map(wide.line), [sentence],
                "a sentence short enough not to wrap was still rewritten")
            let narrow = UI(columns: 24, rich: false)
            let wrapped = narrow.wrap(sentence, hanging: 4).map(narrow.line)
            Harness.expectTrue(wrapped.count > 1, "nothing wrapped at 24 columns")
            Harness.expectEqual(
                wrapped.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "),
                sentence, "wrapping lost or added a space: \(wrapped)")
        }

        // Markup that is a run of words split across roles is still one
        // sentence, and the boundary between two runs is not a space.
        Harness.test("wrapping across two roles does not invent a space") {
            let wide = UI(columns: 96, rich: false)
            Harness.expectEqual(
                wide.wrap("{body|Try }{action|oilbird up}{body|, then this again.}")
                    .map(wide.line),
                ["Try oilbird up, then this again."],
                "two runs of one sentence did not survive the round trip")
        }

        // ⚠ One backticked run is ONE command. Split on whitespace,
        // `` `oilbird --help` `` becomes two commands with a pair of ticks
        // around each half.
        Harness.test("a multi-word command stays one backticked run") {
            let wide = UI(columns: 96, rich: false)
            Harness.expectEqual(
                wide.wrap("Run `oilbird --help` for the verbs.").map(wide.line),
                ["Run `oilbird --help` for the verbs."])
            let painted = UI(columns: 96, rich: true)
            Harness.expectEqual(
                painted.wrap("Run `oilbird --help` for the verbs.").map(painted.line),
                ["Run \u{1B}[36moilbird --help\u{1B}[0m for the verbs."],
                "one command was painted as two")
        }

        // ⚠ Eight SGR pairs where one will do. Every word of a wrapped note
        // carried its own escape — visually identical, unreadable in a
        // transcript, and eight times the bytes.
        Harness.test("adjacent words of one role are painted once, not each") {
            let painted = UI(columns: 96, rich: true)
            let line = painted.wrap("{note|exit 2 — usage. A script can tell them apart.}")
                .map(painted.line).joined()
            Harness.expectEqual(
                line.components(separatedBy: "\u{1B}[90m").count - 1, 1,
                "the run was repainted per word: \(line)")
        }

        Harness.test("unknown width wraps nothing, because a guess is not a width") {
            let long = String(repeating: "word ", count: 60)
            Harness.expectEqual(
                plain.wrap(long).count, 1, "a pipe reflowed to a width it does not know")
        }

        Harness.test("the measure is clamped to 96 however wide the window is") {
            Harness.expectEqual(UI(columns: 200, rich: true).measure, 96)
            Harness.expectEqual(UI(columns: 60, rich: true).measure, 60)
            Harness.expectEqual(UI.piped.measure, 0, "unknown is not 96")
        }

        // Box drawing is used for rules only, and only under the condition we
        // already believe escapes will render.
        Harness.test("a rule exists only at a terminal with colour") {
            Harness.expectTrue(plain.rule("CHECKED").isEmpty, "a pipe received a rule")
            Harness.expectTrue(!rich.rule("CHECKED").isEmpty)
            Harness.expectEqual(
                rich.cells(rich.rule("CHECKED")[0]), 94, "the rule is not the measure less its indent")
        }
    }

    Harness.suite("UI — a message about the reader's code arrives intact") {
        // ⚠ A scanner message such as `duplicating this literal "{source}"` was
        // printed as `"(source}"`, so a reader grepped for a string that is
        // not in their code. Every `{` was replaced before printing.
        Harness.test("a brace in a scanner message survives to the screen") {
            let message = #"Define a constant instead of duplicating this literal "{source}" 4 times."#
            let painted = UI.spans("  {note|" + UI.escapingMarkup(message) + "}")
                .map(\.text).joined()
            Harness.expectTrue(
                painted.contains(#""{source}""#),
                "the literal did not survive the markup pass: \(painted)")
            Harness.expectTrue(
                !painted.contains("(source"),
                "the brace was replaced rather than escaped: \(painted)")
        }

        // The parser has always been safe here, which is why the substitution
        // was unnecessary as well as wrong. `spans` says so in as many words.
        Harness.test("an unparseable brace is text, as the parser promises") {
            let spans = UI.spans("a {source} and a {lone brace")
            Harness.expectEqual(
                spans.map(\.text).joined(), "a {source} and a {lone brace",
                "the parser mangled its own input")
        }

        // ⚠ The invariant, worth more than any list of cases: escaped text
        // renders as ITSELF, whatever it contains — both braces, backticks,
        // and text that spells a real token.
        Harness.test("escaped text renders as itself, whatever it contains") {
            for nasty in [
                #"literal "{source}" 4 times"#,
                "see {note|this} and {bad|that}",
                "trailing {bad|",
                "a lone } and a lone {",
                "`backticks` and ``empty``",
                #"a path C:\temp\{id} and a regex \d{2,3}"#,
                "{}{}{}",
            ] {
                let painted = UI.spans("{note|" + UI.escapingMarkup(nasty) + "}")
                    .map(\.text).joined()
                Harness.expectEqual(
                    painted, nasty, "escaped text did not survive the markup pass")
            }
        }

        // ⚠ A backslash before anything else stays a backslash. Paths and
        // regexes are full of them, and escaping those would be the mangling
        // this exists to stop.
        Harness.test("an ordinary backslash is not an escape") {
            Harness.expectEqual(
                UI.spans(#"C:\temp\new"#).map(\.text).joined(), #"C:\temp\new"#,
                "a backslash in a path was eaten")
        }
    }

    Harness.suite("UI — the two capabilities are derived separately") {
        // ⚠ The whole reason they are two. Collapsing them loses the layout
        // for a reader who only asked to lose the colour.
        Harness.test("NO_COLOR at a terminal keeps the width and loses the paint") {
            let ui = UI.derive(
                stdoutIsTerminal: true, stderrIsTerminal: true, columns: 120,
                environment: ["TERM": "xterm-256color", "NO_COLOR": "1"])
            Harness.expectEqual(ui.rich, false, "NO_COLOR still painted")
            Harness.expectEqual(ui.columns, 120, "NO_COLOR also took the width away")
            Harness.expectEqual(ui.measure, 96)
        }

        // no-color.org is explicit that the variable is set or unset, and
        // `NO_COLOR=0` meaning "yes colour" makes an accessibility setting
        // unreliable.
        Harness.test("NO_COLOR is honoured by presence, whatever its value") {
            for value in ["1", "0", "", "false", "yes"] {
                let ui = UI.derive(
                    stdoutIsTerminal: true, stderrIsTerminal: true, columns: 80,
                    environment: ["TERM": "xterm", "NO_COLOR": value])
                Harness.expectEqual(ui.rich, false, "NO_COLOR=\(value) still painted")
            }
        }

        Harness.test("a terminal with a real TERM and no muting is rich") {
            let ui = UI.derive(
                stdoutIsTerminal: true, stderrIsTerminal: true, columns: 96,
                environment: ["TERM": "xterm-256color"])
            Harness.expectEqual(ui.rich, true)
            Harness.expectEqual(ui.measure, 96)
        }

        Harness.test("TERM=dumb and an unset TERM both lose the paint") {
            for term in ["dumb", ""] {
                let ui = UI.derive(
                    stdoutIsTerminal: true, stderrIsTerminal: true, columns: 96,
                    environment: ["TERM": term])
                Harness.expectEqual(ui.rich, false, "TERM='\(term)' painted anyway")
            }
        }

        // A carriage-returned animation in a CI log arrives as thousands of
        // lines, and nobody is watching a live screen there.
        Harness.test("CI is never rich, whichever runner it is") {
            for runner in ["CI", "GITHUB_ACTIONS", "GITLAB_CI", "BUILDKITE", "JENKINS_URL"] {
                let ui = UI.derive(
                    stdoutIsTerminal: true, stderrIsTerminal: true, columns: 96,
                    environment: ["TERM": "xterm", runner: "true"])
                Harness.expectEqual(ui.rich, false, "\(runner) painted anyway")
            }
            // ⚠ And `CI=false` is not CI. A shell that exports it off is
            // saying so, and treating any value as truth would make the
            // variable impossible to turn off.
            let off = UI.derive(
                stdoutIsTerminal: true, stderrIsTerminal: true, columns: 96,
                environment: ["TERM": "xterm", "CI": "false"])
            Harness.expectEqual(off.rich, true, "CI=false was read as CI")
        }

        // ⚠ A redirect of either half must emit no escapes: `--json` owns
        // stdout and the human screen is on stderr, so capturing one leaves
        // the reader off a known terminal for the whole screen.
        Harness.test("a redirect of either stream loses the paint") {
            let outPiped = UI.derive(
                stdoutIsTerminal: false, stderrIsTerminal: true, columns: 96,
                environment: ["TERM": "xterm"])
            Harness.expectEqual(outPiped.rich, false, "stdout redirected and it still painted")
            Harness.expectEqual(
                outPiped.columns, 96, "the width was thrown away with the colour")
            let errPiped = UI.derive(
                stdoutIsTerminal: true, stderrIsTerminal: false, columns: 96,
                environment: ["TERM": "xterm"])
            Harness.expectEqual(errPiped.rich, false, "stderr redirected and it still painted")
            Harness.expectEqual(errPiped.columns, 0, "a width was claimed for a pipe")
        }
    }

    Harness.suite("UI — the wordmark is decoration and nothing else") {
        // ⚠ Piped, redirected, in CI, under NO_COLOR or TERM=dumb it emits
        // NOTHING — not a plainer banner, nothing. A wordmark in a log file is
        // noise, and every fact it carries is repeated underneath it.
        Harness.test("no terminal, no wordmark — and not a plainer one") {
            Harness.expectTrue(UI.piped.banner().isEmpty, "a pipe received a banner")
            Harness.expectNil(UI.piped.mark(), "a pipe received a one-line mark")
            let muted = UI(columns: 96, rich: false)
            Harness.expectTrue(muted.banner().isEmpty, "NO_COLOR received a banner")
            Harness.expectNil(muted.mark(), "NO_COLOR received a mark")
        }

        Harness.test("the banner is five rows and fits the measure") {
            let rich = UI(columns: 96, rich: true)
            let rows = rich.banner()
            Harness.expectEqual(rows.count, 5)
            for row in rows { Harness.expectTrue(rich.cells(row) <= 96, "a banner row overflows") }
        }

        // ⚠ A wordmark folded across two lines is not a wordmark, and a
        // 56-column banner in a 40-column pane is worse than none.
        Harness.test("a narrow terminal gets no banner rather than a folded one") {
            Harness.expectTrue(UI(columns: 40, rich: true).banner().isEmpty)
            Harness.expectTrue(
                UI(columns: 40, rich: true).mark() != nil,
                "the one-line mark is what a narrow terminal keeps")
        }

        Harness.test("the one-line mark carries the same gradient") {
            let mark = UI(columns: 96, rich: true).mark() ?? ""
            Harness.expectEqual(UI(columns: 96, rich: true).cells(mark), 11)
            for role in ["ember", "flame", "amber", "spark"] {
                Harness.expectTrue(mark.contains("{\(role)|"), "the mark lost \(role)")
            }
        }
    }

    Harness.suite("UI — the screens") {
        let rich = UI(columns: 96, rich: true)
        let plain = UI.piped

        // ⚠ Severity is carried by CASE as well as by colour, so it survives
        // NO_COLOR, a monochrome terminal and a screenshot pasted into Slack.
        // `grep -c ok` has to work on the piped form either way.
        Harness.test("a status token is the first thing on its line") {
            for (token, role) in [("ok", UI.Role.good), ("FAIL", .bad), ("wait", .attn)] {
                let row = plain.line(plain.statusRow(token, role, "scanner", "7.3.0.5189"))
                Harness.expectEqual(
                    row.trimmingCharacters(in: .whitespaces).hasPrefix(token), true,
                    "\(token) is not the first thing on the row")
            }
        }

        // ⚠ The eye locks onto a straight edge; it cannot lock onto a ragged
        // one. Every message starts at the same column, including the rows
        // whose token is shorter.
        Harness.test("every status row starts its message at the same column") {
            let columns = [("ok", UI.Role.good), ("FAIL", .bad), ("wait", .attn)].map {
                token, role -> Int in
                let row = plain.line(plain.statusRow(token, role, "scanner", ""))
                guard let subject = row.range(of: "scanner") else {
                    Harness.expectTrue(false, "the row lost its subject: \(row)")
                    return -1
                }
                return row.distance(from: row.startIndex, to: subject.lowerBound)
            }
            Harness.expectEqual(Set(columns).count, 1, "the message column is ragged: \(columns)")
            Harness.expectEqual(columns[0], UI.gutter)
        }

        // ⚠ Checked on the RENDERED line, and on EVERY line: the markup says
        // how the indent is spelt, not where it lands, and `[0]` alone misses
        // a line indented twice.
        Harness.test("every continuation under a row lines up with the message") {
            let narrow = UI(columns: 60, rich: false)
            let detail = narrow.statusDetail(
                "the fixture analysis did not reach the server, and this sentence is long "
                    + "enough that it has to wrap at least once")
            Harness.expectTrue(detail.count > 1, "nothing wrapped, so nothing was checked")
            for markup in detail {
                let line = narrow.line(markup)
                Harness.expectTrue(
                    line.hasPrefix(String(repeating: " ", count: UI.gutter)),
                    "a detail line does not reach the message column: |\(line)|")
                Harness.expectTrue(
                    !line.hasPrefix(String(repeating: " ", count: UI.gutter + 1)),
                    "a detail line is indented past the message column: |\(line)|")
                Harness.expectTrue(
                    narrow.cells(markup) <= narrow.measure,
                    "a detail line is \(narrow.cells(markup)) cells at a measure of 60")
            }
        }

        // ⚠ No dead ends. `Oilbird is not running. → Start it` names no
        // command, and "Start it" is not one.
        Harness.test("the paused screen names the command that ends it") {
            let screen = plain.pausedScreen(
                retrying: "oilbird summary web-app-deaa", idle: "after 30 minutes unused")
            let text = screen.joined(separator: "\n")
            Harness.expectTrue(
                text.contains("oilbird up && oilbird summary web-app-deaa"),
                "the recovery did not offer to run what was asked for")
            Harness.expectTrue(text.contains("oilbird idle never"), "the other way out is missing")
            Harness.expectTrue(text.contains("exit 1"), "the exit code is not stated")
        }

        // ⚠ Exit 3, not 0. A CI step that treats "read nothing" as a pass is
        // the whole problem this screen exists for.
        Harness.test("the read-nothing screen never reads like clean code") {
            let text = plain.readNothingScreen(
                "~/.dotfiles", because: "everything inside it counted as hidden."
            ).joined(separator: "\n")
            Harness.expectTrue(text.contains("read nothing"), "it did not say what happened")
            Harness.expectTrue(text.contains("0 files, 0 lines"), "it did not say how little")
            Harness.expectTrue(text.contains("exit 3"), "the exit code is not stated")
            Harness.expectTrue(!text.contains("scanned"), "it still reads like a successful scan")
        }

        Harness.test("the help screen carries the banner only at a terminal") {
            Harness.expectEqual(rich.helpScreen().count - plain.helpScreen().count, 5)
            Harness.expectTrue(
                plain.helpScreen().map(plain.line).joined(separator: "\n")
                    .contains("oilbird — a local SonarQube"),
                "the one line an issue is pasted with is gone")
        }

        // ⚠ Hand-padded literals put a cell out of true three times here,
        // last as `up | down` one cell right of its section. Invisible to any
        // test asking only whether the words are present.
        Harness.test("every description in the help starts at the same column") {
            var starts: [Int] = []
            for line in plain.helpScreen().map(plain.line) {
                // A verb row: indented four, then a verb, then the gutter.
                // Prose is indented two, and the USAGE line is indented four
                // but has no gutter in it, so neither can be mistaken for one.
                guard line.hasPrefix("    "), !line.hasPrefix("     ") else { continue }
                let body = String(line.dropFirst(4))
                guard let gutter = body.range(of: "  ") else { continue }
                let description = body[gutter.lowerBound...].drop(while: { $0 == " " })
                starts.append(4 + plain.cells(String(body[body.startIndex..<description.startIndex])))
            }
            // ⚠ A FLOOR, not an exact count: pinned exactly, a legitimate
            // nineteenth verb fails a test about alignment. The property is
            // the column; the count catches rows vanishing wholesale.
            Harness.expectTrue(
                starts.count >= 15, "the help lost verb rows: \(starts.count)")
            Harness.expectEqual(
                Set(starts).count, 1,
                "the help's descriptions start at \(Set(starts).sorted()) — a row is out of true")
        }

        // ⚠ `waitingForServer` carries SonarQube's own status string, so
        // comparing whole cases restarts the elapsed clock every time it
        // changes: a twenty-five second wait reports `done … 0s`.
        Harness.test("a phase that changes its status string is still one phase") {
            let phases = UI.Phases(plain)
            Harness.expectTrue(
                phases.advance(to: .startingServer) == nil, "the first phase closed something")
            Harness.expectTrue(
                phases.advance(to: .waitingForServer(status: "STARTING", elapsed: 1)) != nil,
                "moving off startingServer printed no row")
            // ⚠ The wait is BEFORE the status changes, not after. Waiting
            // afterwards passes either way: the clock has to be seen still
            // running ACROSS the change, which is the moment it was reset.
            Thread.sleep(forTimeInterval: 1.2)
            for status in ["DB_MIGRATION_NEEDED", "UP"] {
                Harness.expectTrue(
                    phases.advance(to: .waitingForServer(status: status, elapsed: 2)) == nil,
                    "SonarQube saying '\(status)' closed the phase it was still in")
            }
            guard let closed = phases.close() else {
                Harness.expectTrue(false, "the last phase left no row")
                return
            }
            Harness.expectTrue(
                closed.contains("Warming up the search index"), "the row names the wrong phase")
            Harness.expectTrue(
                !closed.contains("0s"),
                "the clock restarted when SonarQube changed its status string: \(closed)")
        }

        // ⚠ A fixed estimate with nothing moving is a claim the reader can
        // watch being wrong, and with no number moving there is no telling a
        // slow start from a dead one.
        Harness.test("a long wait stops claiming it is a short one") {
            func detail(_ seconds: Int) -> String {
                Oilbird.Phase.waitingForServer(status: "STARTING", elapsed: Double(seconds)).detail
            }
            // Inside the estimate: the estimate is useful, and the count runs.
            let early = detail(8)
            Harness.expectTrue(early.contains("8s so far"), "nothing was counting: \(early)")
            Harness.expectTrue(early.contains("25"), "the estimate stopped being offered")

            // Past it: the estimate is dropped rather than repeated.
            let late = detail(95)
            Harness.expectTrue(late.contains("95s so far"), "the count stopped: \(late)")
            Harness.expectTrue(
                !late.contains("Usually about"),
                "it still promised 25 seconds on the 95th: \(late)")
            Harness.expectTrue(
                late.contains("longer than usual"), "it did not say the wait was unusual")
            // And it names where to look, rather than leaving a dead end.
            Harness.expectTrue(late.contains("oilbird log"), "no way forward was offered")

            // SonarQube's own word travels in both.
            for text in [early, late] {
                Harness.expectTrue(text.contains("starting"), "the server's own status is gone")
            }
        }

        // ⚠ The mark is decoration and the facts are the answer, so a narrow
        // terminal wraps rather than folding through `127.0.0.1:50296`. An
        // overflow exists only where there is a width.
        Harness.test("the engine line fits whatever terminal it is drawn on") {
            let facts = ["127.0.0.1:50296", "up 47m", "221 MB", "stops after 30 minutes unused"]
            for columns in [120, 96, 80, 60, 40] {
                let terminal = UI(columns: columns, rich: true)
                let drawn = terminal.engineLine("{bold|running}", detail: facts)
                for markup in drawn {
                    Harness.expectTrue(
                        terminal.cells(markup) <= terminal.measure,
                        "at \(columns) columns a line is \(terminal.cells(markup)) cells")
                }
                // Every fact survives, whatever the width — wrapped, never
                // dropped. Which fact a reader wanted is not ours to guess.
                let all = drawn.map(terminal.stripped).joined(separator: " ")
                // Every WORD survives, whatever the width — wrapped, never
                // dropped. Which fact a reader wanted is not ours to guess,
                // and a phrase may legitimately break across two lines.
                let words = Set(all.split(separator: " ").map(String.init))
                for fact in facts {
                    for word in fact.split(separator: " ").map(String.init) {
                        Harness.expectTrue(
                            words.contains(word), "at \(columns) columns '\(word)' was lost")
                    }
                }
            }
            // A pipe has no width and no mark, and is one line as it always
            // was — behaviour a script reads must not move with a window.
            let piped = UI.piped.engineLine("{bold|running}", detail: facts)
            Harness.expectEqual(piped.count, 1, "a pipe got a wrapped status line")
            Harness.expectTrue(
                !UI.piped.stripped(piped[0]).contains("·))"), "a pipe got the wordmark")
        }

        // ⚠ Padded to a flat width, a subject wider than the pad leaves no
        // gap at all: `Starting the database0s`. The same defect `table`'s
        // gutter prevents, invisible while every subject is short.
        Harness.test("a status row keeps a gap however long the subject is") {
            for subject in ["jdk", "Starting the database", "Warming up the search index"] {
                let row = plain.line(plain.statusRow("done", .good, subject, "1m 12s"))
                Harness.expectTrue(
                    row.contains(subject + "  "),
                    "the detail touched the subject: \(row)")
            }
            // And the short ones still line up with each other.
            let short = ["jdk", "postgres"].compactMap { subject -> String.Index? in
                let row = plain.line(plain.statusRow("ok", .good, subject, "x"))
                guard let detail = row.firstIndex(of: "x") else {
                    Harness.expectTrue(false, "the row lost its detail: \(row)")
                    return nil
                }
                return detail
            }
            Harness.expectEqual(Set(short).count, 1, "short subjects stopped sharing a column")
        }

        // ⚠ Both of these shipped on one screen, under a `counted` helper
        // that had existed for weeks in a file the screens could not see.
        Harness.test("summary counts one of a thing in the singular") {
            let one = summaryFixture(total: 1, severities: ["MAJOR": 1], conditions: 1)
            let text = plain.summaryScreen(one).map(plain.line).joined(separator: "\n")
            Harness.expectTrue(text.contains("1 issue "), "it read '1 issues'")
            Harness.expectTrue(text.contains("of 1 condition\n"), "it read '1 conditions'")

            let many = summaryFixture(total: 4, severities: ["MAJOR": 4], conditions: 3)
            let plural = plain.summaryScreen(many).map(plain.line).joined(separator: "\n")
            Harness.expectTrue(plural.contains("4 issues"), "it stopped pluralising")
            Harness.expectTrue(plural.contains("of 3 conditions"), "it stopped pluralising")
        }

        // ⚠ The screen counts the family the SERVER judges by, or it reads
        // `reliability 34` beside a dashboard saying 111 in the same window.
        // The letter it leads with is on the row for the same reason.
        Harness.test("summary counts and rates the way the server judges") {
            let mqr = summaryFixture(
                facets: SonarAPI.IssueFacets(
                    severities: [
                        "BLOCKER": 5, "HIGH": 186, "MEDIUM": 540, "LOW": 869, "INFO": 2,
                    ],
                    types: ["SECURITY": 22, "RELIABILITY": 111, "MAINTAINABILITY": 1490],
                    total: 1559),
                conditions: 4,
                measures: [
                    "ncloc": "188962", "reliability_rating": "4.0", "security_rating": "4.0",
                    "sqale_rating": "1.0",
                ],
                taxonomy: .mqr)
            let text = plain.summaryScreen(mqr).map(plain.line).joined(separator: "\n")
            Harness.expectTrue(text.contains("reliability"), "the family row is gone")
            Harness.expectTrue(text.contains("111"), "it printed the legacy count, not the server's")
            Harness.expectTrue(text.contains("1,490"), "maintainability came from the wrong family")
            Harness.expectTrue(text.contains("high 186"), "the severity line is the legacy one")
            Harness.expectTrue(
                !text.contains("critical"), "a legacy severity leaked onto an MQR screen")
            // D, not nothing, and not A.
            Harness.expectTrue(text.contains("rating"), "the rating column is missing")
            Harness.expectTrue(
                text.split(separator: "\n").contains { $0.contains("reliability") && $0.contains("D") },
                "a project the server rates D shows no rating")

            let standard = summaryFixture(
                facets: SonarAPI.IssueFacets(
                    severities: ["CRITICAL": 3], types: ["BUG": 3], total: 3),
                conditions: 1, measures: ["ncloc": "9"])
            let legacy = plain.summaryScreen(standard).map(plain.line).joined(separator: "\n")
            Harness.expectTrue(legacy.contains("critical 3"), "a standard server lost its vocabulary")
            Harness.expectTrue(!legacy.contains("high "), "an MQR severity leaked onto a legacy screen")
        }

        // ⚠ The offer names a severity the project HAS. Fixed at BLOCKER it
        // sits under counts saying there are none, which is a dead end the
        // screen manufactured for itself.
        Harness.test("the severity summary offers is one the project has") {
            let worst = summaryFixture(
                total: 3, severities: ["BLOCKER": 0, "CRITICAL": 2, "MAJOR": 1], conditions: 1)
            let text = plain.summaryScreen(worst).map(plain.line).joined(separator: "\n")
            Harness.expectTrue(
                text.contains("--severity CRITICAL"), "it did not name the worst it has")
            Harness.expectTrue(
                !text.contains("--severity BLOCKER"), "it offered a severity with no issues")

            let clean = summaryFixture(total: 0, severities: ["BLOCKER": 0], conditions: 1)
            Harness.expectTrue(
                !plain.summaryScreen(clean).map(plain.line).joined().contains("--severity"),
                "a project with no issues was still offered a filter")
        }

        // ⚠ Every row of the menu is a verb the CLI dispatches, and
        // the `parity` check holds the list against the switch: a menu kept by
        // hand drifts out of step, and a human notices before a test does.
        Harness.test("every menu row names a verb and says when you want it") {
            let rows = UI.menuRows(scanning: "~/src/thing")
            Harness.expectTrue(rows.count >= 8, "the menu lost most of itself")
            for row in rows {
                Harness.expectNotEmpty(row.verb, "a menu row runs nothing")
                Harness.expectNotEmpty(row.blurb, "a menu row says only what it is called")
            }
            // The reading half comes back; the acting half ends.
            Harness.expectEqual(rows.first { $0.verb == "projects" }?.returns, true)
            Harness.expectEqual(rows.first { $0.verb == "down" }?.returns, false)
            Harness.expectEqual(rows.first { $0.verb == "scan" }?.returns, false)
        }

        // ⚠ An arrow is three bytes and a bare Escape is one, and the only
        // thing separating them is whether more bytes are already waiting.
        // Read blindly, a bare Escape eats the next keystroke as its tail.
        Harness.test("an arrow is told from a bare escape by what is waiting") {
            func key(_ bytes: [UInt8], waiting: Bool) -> UI.Key {
                var rest = bytes[...]
                return UI.Keyboard.classify(
                    read: { rest.popFirst() }, waiting: { waiting })
            }
            Harness.expectEqual(key([0x1B, 0x5B, 0x41], waiting: true), .up)
            Harness.expectEqual(key([0x1B, 0x5B, 0x42], waiting: true), .down)
            // ⚠ `.escape` is its own case. Folded into `.other`, Escape
            // cycles a severity and a filter cannot be cancelled: a screen
            // cannot answer a key it cannot tell from three others.
            Harness.expectEqual(key([0x1B], waiting: false), .escape)
            Harness.expectEqual(key([0x09], waiting: false), .tab)
            Harness.expectEqual(key([0x7F], waiting: false), .backspace)
            Harness.expectEqual(key([UInt8(ascii: "/")], waiting: false), .slash)
            // The tail is NOT consumed when nothing was waiting.
            var rest: ArraySlice<UInt8> = [0x1B, UInt8(ascii: "5")][...]
            _ = UI.Keyboard.classify(read: { rest.popFirst() }, waiting: { false })
            Harness.expectEqual(rest.first, UInt8(ascii: "5"), "a bare escape ate the next key")
        }

        Harness.test("every key the menu's legend names is classified") {
            func key(_ byte: UInt8) -> UI.Key {
                var rest = [byte][...]
                return UI.Keyboard.classify(read: { rest.popFirst() }, waiting: { false })
            }
            Harness.expectEqual(key(0x0A), .enter, "newline")
            Harness.expectEqual(key(0x0D), .enter, "carriage return")
            Harness.expectEqual(key(UInt8(ascii: "q")), .quit)
            Harness.expectEqual(key(UInt8(ascii: "Q")), .quit, "an upper-case q does not quit")
            Harness.expectEqual(key(0x04), .quit, "Ctrl-D does not end it")
            Harness.expectEqual(key(UInt8(ascii: "0")), .digit("0"))
            Harness.expectEqual(key(UInt8(ascii: "9")), .digit("9"))
            Harness.expectEqual(key(UInt8(ascii: "S")), .letter("s"), "type-ahead is case-blind")
            var empty: ArraySlice<UInt8> = [][...]
            Harness.expectEqual(
                UI.Keyboard.classify(read: { empty.popFirst() }, waiting: { false }), .eof)
        }

        // ⚠ A marker on a row nobody can move is decoration that looks like a
        // selection, and a legend naming a key that does nothing is the
        // cheapest way to make a UI feel broken.
        Harness.test("the menu's legend offers only the keys that work") {
            let rows = UI.menuRows(scanning: "~/src/thing")
            let typed = plain.menuScreen(rows, state: "running", divider: 6).map(plain.line)
            let keyed = plain.menuScreen(rows, state: "running", divider: 6, selected: 1)
                .map(plain.line)
            Harness.expectTrue(
                !typed.joined().contains("↑↓"), "a line-at-a-time menu offered arrow keys")
            Harness.expectTrue(
                !typed.joined().contains("▸"), "a menu with no selection drew a marker")
            Harness.expectTrue(keyed.joined().contains("↑↓ choose"), "the keyed menu hid its keys")
            Harness.expectTrue(
                keyed.contains { $0.contains("▸") && $0.contains(rows[1].label) },
                "the selected row carries no marker")
            Harness.expectEqual(
                keyed.filter { $0.contains("▸") }.count, 1, "more than one row was selected")
        }

        // ⚠ The gap, not the column: `pad` measures the whole prefix so the
        // column cannot drift. What breaks is a pad target computed without
        // the marker's cells: `versionwhat this build pins`.
        Harness.test("the longest row in the menu keeps a gap before its blurb") {
            let rows = UI.menuRows(scanning: "~/src/thing")
            for selected in [nil, 0, rows.count - 1] {
                for line in plain.menuScreen(
                    rows, state: "running", divider: 6, selected: selected
                ).map(plain.line) {
                    guard
                        let number = line.range(
                            of: "^ +(\u{25B8} )? *[0-9]+\\. ", options: .regularExpression)
                    else { continue }
                    Harness.expectTrue(
                        line[number.upperBound...].contains("  "),
                        "a blurb touched its label: \(line)")
                }
            }
        }

        Harness.test("the menu's own heading fits the measure") {
            let rows = UI.menuRows(scanning: "~/src/thing")
            for line in rich.menuScreen(rows, state: "running · up 2h 14m", divider: 6).prefix(5) {
                Harness.expectTrue(
                    rich.cells(line) <= 96, "the menu heading wraps: \(rich.cells(line)) cells")
            }
        }
    }
}

/// A summary with only the fields these screens read.
private func summaryFixture(
    total: Int, severities: [String: Int], conditions: Int
) -> Oilbird.Summary {
    summaryFixture(
        facets: SonarAPI.IssueFacets(
            severities: severities, types: ["CODE_SMELL": total], total: total),
        conditions: conditions)
}

/// ⚠ `facets` and not three separate arguments. `severities`, `types` and
/// `total` are one answer from one call and now have a type that says so, and
/// passing them apart put this at six parameters.
private func summaryFixture(
    facets: SonarAPI.IssueFacets, conditions: Int,
    measures: [String: String] = ["ncloc": "229"],
    taxonomy: SonarAPI.Taxonomy = .standard
) -> Oilbird.Summary {
    Oilbird.Summary(
        project: "fixture-9af0",
        gate: SonarAPI.GateResult(
            gate: .ok,
            conditions: (0..<conditions).map {
                SonarAPI.GateResult.Condition(
                    status: "OK", metricKey: "metric_\($0)", comparator: "GT",
                    errorThreshold: "0", actualValue: "0")
            }),
        measures: measures,
        severities: facets.severities,
        types: facets.types,
        total: facets.total,
        taxonomy: taxonomy)
}
