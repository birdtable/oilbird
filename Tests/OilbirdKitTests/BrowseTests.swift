import Foundation
import OilbirdCore
import OilbirdKit

/// What survived the browser.
///
/// ⚠ The browser this file was written for is gone: the cursor, the window
/// and the repaint belong to the framework's `List` now, and its own suite
/// lives in `BrowserTests`. What is left here covers code the browser only
/// happened to be the first caller of — `shorten` and `worst` — and deleting
/// the file wholesale would have taken both with it.
func browseTests() {
    let plain = UI.piped

    func issue(
        _ rule: String, _ severity: String, _ file: String, _ line: Int, _ impact: String? = nil
    ) -> SonarAPI.Issue {
        SonarAPI.Issue(
            key: rule + file, rule: rule, severity: severity, type: "CODE_SMELL",
            component: "demo:" + file, line: line, message: "Fix " + rule,
            impacts: impact.map { [.init(softwareQuality: "MAINTAINABILITY", severity: $0)] } ?? [])
    }

    Harness.suite("Browse — the one screen that repaints") {
        Harness.test("a path too long to fit keeps the end that identifies it") {
            let long = "src/features/accounts/components/settings/SettingsTreeRow.tsx:52"
            let cut = UI.elide(long, to: 40)
            Harness.expectTrue(plain.cells(cut) <= 40, "the elision did not fit: \\(cut)")
            Harness.expectTrue(cut.hasSuffix("SettingsTreeRow.tsx:52"), "the filename was cut off")
            Harness.expectTrue(cut.hasPrefix("…/"), "it does not read as a path")
            // Short enough already: untouched, not decorated.
            Harness.expectEqual(UI.elide("src/a.ts:1", to: 40), "src/a.ts:1")
            // One component with no separator to cut at still fits.
            let single = String(repeating: "x", count: 60)
            Harness.expectTrue(plain.cells(UI.elide(single, to: 20)) <= 20, "a long name overflowed")
        }

        Harness.test("the worst issues are the ones that survive the bound") {
            // Deliberately arranged so the blockers are LAST in the input.
            let ordered = [
                issue("ts:a", "MINOR", "src/a.ts", 1, "LOW"),
                issue("ts:b", "MINOR", "src/b.ts", 2, "LOW"),
                issue("ts:c", "MAJOR", "src/c.ts", 3, "MEDIUM"),
                issue("ts:d", "CRITICAL", "src/d.ts", 4, "HIGH"),
                issue("ts:e", "BLOCKER", "src/e.ts", 5, "BLOCKER"),
            ]
            let two = Oilbird.worst(ordered, taxonomy: .mqr, limit: 2)
            Harness.expectEqual(two.count, 2)
            Harness.expectEqual(
                two.map { $0.severity(in: .mqr) }, ["BLOCKER", "HIGH"],
                "the bound kept the first two rather than the worst two")

            // 0 is "all of them", for an agent that asked knowing the size.
            Harness.expectEqual(
                Oilbird.worst(ordered, taxonomy: .mqr, limit: 0).count, ordered.count)
            // A limit past the end is not an error and does not pad.
            Harness.expectEqual(
                Oilbird.worst(ordered, taxonomy: .mqr, limit: 99).count, ordered.count)
            Harness.expectEqual(Oilbird.worst([], taxonomy: .mqr, limit: 10).count, 0)

            // And under the legacy taxonomy the order is the legacy one.
            Harness.expectEqual(
                Oilbird.worst(ordered, taxonomy: .standard, limit: 2)
                    .map { $0.severity(in: .standard) },
                ["BLOCKER", "CRITICAL"],
                "a standard server was ranked by MQR's words")
        }
    }
}
