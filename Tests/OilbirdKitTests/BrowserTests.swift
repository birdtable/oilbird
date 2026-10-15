import Foundation
import OilbirdKit

/// The browser's decisions, asserted without a terminal.
///
/// ⚠ These are the assertions the old browser could only make by pressing a
/// key: "does this filter admit that issue" lived inside a keyboard loop, so
/// testing it meant driving the loop. They are pure functions now.
func browserTests() {
    Harness.suite("Issues browser — the decisions, without a terminal") {
        let issues = [
            IssueRow(
                id: "1", severity: "BLOCKER", file: "src/Main.swift", line: 12,
                rule: "swift:S101", message: "Rename this class"),
            IssueRow(
                id: "2", severity: "MINOR", file: "src/Util.swift", line: nil,
                rule: "swift:S1128", message: "Remove this unused import"),
            IssueRow(
                id: "3", severity: "MAJOR", file: "test/UtilTests.swift", line: 4,
                rule: "swift:S1murk", message: "Complete the task"),
        ]

        Harness.test("an empty filter admits everything") {
            Harness.expectEqual(IssueFilter().apply(to: issues).count, 3, "the empty filter cut")
        }

        Harness.test("a filter reads the path, the message and the rule") {
            Harness.expectEqual(
                IssueFilter(needle: "util").apply(to: issues).count, 2, "the path is not searched")
            Harness.expectEqual(
                IssueFilter(needle: "unused").apply(to: issues).count, 1,
                "the message is not searched")
            Harness.expectEqual(
                IssueFilter(needle: "S101").apply(to: issues).count, 1, "the rule is not searched")
        }

        Harness.test("a filter ignores case, because nobody types the key exactly") {
            Harness.expectEqual(
                IssueFilter(needle: "MAIN.SWIFT").apply(to: issues).count, 1, "case was honoured")
        }

        Harness.test("a severity and a needle both narrow") {
            let both = IssueFilter(severity: "MINOR", needle: "util").apply(to: issues)
            Harness.expectEqual(both.count, 1, "the two filters did not compose")
            Harness.expectEqual(both.first?.id, "2", "the wrong issue survived")
        }

        // ⚠ An issue with no line is not a bug, it is a file-level finding.
        // The old screen printed `src/Util.swift:nil` once.
        Harness.test("an issue with no line names the file alone") {
            Harness.expectEqual(issues[1].place, "src/Util.swift", "a missing line was printed")
            Harness.expectEqual(issues[0].place, "src/Main.swift:12", "a line was dropped")
        }

        // ⚠ SonarQube ships two severity vocabularies and has added words to
        // both. A switch over today's words paints tomorrow's as unremarkable,
        // which is the quietest way for a BLOCKER to look like a footnote.
        Harness.test("every severity either has a tone or reads as ordinary text") {
            for severity in ["BLOCKER", "CRITICAL", "HIGH", "MAJOR", "MEDIUM", "MINOR", "LOW"] {
                Harness.expectTrue(
                    IssuesBrowser.tone(severity) != Role.body,
                    "\(severity) is drawn as unremarkable body text")
            }
            Harness.expectTrue(
                IssuesBrowser.tone("SOMETHING_SONAR_ADDED") == Role.body,
                "an unknown severity was quietly filed as a footnote")
        }

        // ⚠ Ported from the old browser's suite rather than dropped with it.
        // Cycling severities was a feature, and deleting the loop that drew it
        // would have deleted the feature silently.
        Harness.test("cycling severity comes back to everything") {
            let words = ["BLOCKER", "MAJOR", "MINOR"]
            var filter = IssueFilter()
            var seen: [String?] = []
            for _ in 0...words.count {
                filter = filter.cycled(through: words)
                seen.append(filter.severity)
            }
            Harness.expectEqual(
                seen.map { $0 ?? "everything" },
                ["BLOCKER", "MAJOR", "MINOR", "everything"],
                "the cycle does not return to everything")
        }

        Harness.test("cycling an unknown severity starts the cycle over") {
            let cycled = IssueFilter(severity: "SOMETHING_ELSE")
                .cycled(through: ["BLOCKER", "MAJOR"])
            Harness.expectEqual(
                cycled.severity, "BLOCKER", "an unknown severity left the cycle stuck")
        }

        // ⚠ Ported from the old suite. Narrowing can hide the selected row,
        // and a detail pane still describing it shows a reader one issue
        // while their cursor sits on another.
        Harness.test("narrowing puts the cursor somewhere that exists") {
            let narrowed = IssueFilter(needle: "util").apply(to: issues)
            let focused = IssuesBrowser.focus("1", in: narrowed)
            Harness.expectTrue(
                focused != nil, "narrowing left nothing focused")
            Harness.expectTrue(
                narrowed.contains(where: { $0.id == focused?.id }),
                "the cursor points at a row that is no longer shown")
        }

        Harness.test("an empty list focuses nothing rather than the wrong thing") {
            Harness.expectNil(
                IssuesBrowser.focus("1", in: []), "an empty list still focused a row")
        }

        Harness.test("an untouched cursor starts at the top") {
            Harness.expectEqual(
                IssuesBrowser.focus(nil, in: issues)?.id, "1", "the cursor did not start at the top")
        }

        Harness.test("the count says how much was hidden") {
            Harness.expectEqual(
                IssuesBrowser.counted(3, of: 3), "3 issues", "an unfiltered count was qualified")
            Harness.expectEqual(
                IssuesBrowser.counted(1, of: 3), "1 of 3", "a filtered count hid the total")
        }
    }
}
