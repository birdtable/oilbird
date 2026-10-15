import Foundation
import OilbirdCore
import OilbirdKit
import SwiftTUIArguments
import SwiftTUICLI

// A frame is a pure function of the view tree and a size proposal, so a screen
// asserts as a string with no terminal and no server. Every environmental input
// is pinned, or the frame differs on every machine.
func screenFrameTests() {
    Harness.suite("Screens — rendered, not described") {
        // ⚠ A key is a directory name and a hash, so it is as long as the
        // directory was. `screens` cannot see this: it drives only the verbs
        // that need no engine, and `projects` needs one.
        Harness.test("one enormous key does not take the whole row with it") {
            onMain {
                let huge = String(repeating: "L", count: 205)
                let frame = rendered(
                    ProjectsScreen(projects: [
                        .init(id: huge, name: huge),
                        .init(id: "billing-api-dc9b69b1", name: "billing-api"),
                    ]),
                    width: 96)
                for row in frame.split(separator: "\n", omittingEmptySubsequences: false) {
                    Harness.expectTrue(
                        row.count <= 96,
                        "a row is \(row.count) cells against a 96-column terminal: \(row.prefix(60))")
                }
                Harness.expectTrue(
                    frame.contains("billing-api"),
                    "the long key squeezed the other column out entirely:\n\(frame)")
            }
        }

        Harness.test("the project list draws its columns aligned") {
            onMain {
                let frame = rendered(
                    ProjectsScreen(projects: [
                        .init(id: "payments-service-4a30", name: "payments-service-4a30"),
                        .init(id: "infra-tools-9422", name: "infra-tools-9422"),
                        .init(id: "web-app-deaa", name: "web-app"),
                    ]))
                let rows = frame.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                guard let header = rows.first(where: { $0.contains("project") }) else {
                    Harness.expectTrue(false, "no header row in:\n\(frame)")
                    return
                }
                guard let column = header.range(of: "name")?.lowerBound else {
                    Harness.expectTrue(false, "no name column in the header")
                    return
                }
                let offset = header.distance(from: header.startIndex, to: column)
                // Every body cell starts in the same column as its header. This is
                // the assertion the old gate could not make.
                for row in rows where row.contains("infra-tools-9422") {
                    guard
                        let second = row.range(of: "infra-tools-9422", options: .backwards)?
                            .lowerBound
                    else { continue }
                    Harness.expectEqual(
                        row.distance(from: row.startIndex, to: second), offset,
                        "the name column does not line up with its header")
                }
            }
        }

        // ⚠ `UI.columns` is 0 when stdout is not a terminal, the CLI's way of
        // saying "unknown". Passed through as a width it lays the screen out
        // for no columns and drops the trailing line, with every table intact.
        Harness.test("an unknown width is a floor, never zero") {
            Harness.expectEqual(Frames.width(0), 80, "zero was taken as a width")
            Harness.expectEqual(Frames.width(nil), 80, "unknown was taken as a width")
            Harness.expectEqual(Frames.width(-1), 80, "a negative width was honoured")
            Harness.expectEqual(Frames.width(120), 120, "a real width was overridden")
        }

        Harness.test("a screen laid out for an unknown width keeps its last line") {
            onMain {
                let frame = RenderOnce.render(
                    ProjectsScreen(projects: [.init(id: "a", name: "b")]),
                    width: Frames.width(0),
                    options: try? SwiftTUIOptions.parse([]),
                    environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"],
                    isStdoutTTY: false)
                Harness.expectTrue(
                    frame.contains("oilbird summary"),
                    "the closing line was dropped when the width was unknown: \(frame)")
            }
        }

        // ⚠ Alignment and chrome are different claims: a table can align its
        // columns perfectly and still draw a full box-drawing grid, and every
        // alignment test passes either way.
        Harness.test("no table rules are drawn") {
            onMain {
                let frame = rendered(
                    ProjectsScreen(projects: [.init(id: "a", name: "b")]))
                let rules = "─│┌┐└┘├┤┬┴┼╭╮╰╯━┃┏┓┗┛"
                let found = frame.filter { rules.contains($0) }
                Harness.expectTrue(
                    found.isEmpty,
                    "the table drew rules Oilbird's tables never have: \(found)")
            }
        }

        // ⚠ `Text` has no `+`: concatenating into a `String` compiles and
        // stringifies the view at the reader. And a command must survive on
        // ONE line, or it reflows and pastes wrong.
        Harness.test("the project list names whole commands, one per line") {
            onMain {
                let frame = rendered(ProjectsScreen(projects: [.init(id: "a", name: "b")]))
                Harness.expectTrue(
                    frame.contains("oilbird summary"), "the next command is not named")
                Harness.expectTrue(
                    frame.contains("oilbird issues"), "the other next command is not named")
                Harness.expectTrue(
                    !frame.contains("ExplicitlyCleared"),
                    "a Text was stringified into the copy: \(frame)")
                for command in ["oilbird summary <key>", "oilbird issues <key>"] {
                    Harness.expectTrue(
                        frame.split(separator: "\n").contains(where: { $0.contains(command) }),
                        "`\(command)` is broken across lines and cannot be copied")
                }
            }
        }

        // ⚠ A screen with nothing to show still says what to do next.
        Harness.test("an empty project list names the way out") {
            onMain {
                let frame = rendered(ProjectsScreen(projects: []))
                Harness.expectTrue(
                    frame.contains("nothing has been scanned"), "it does not say it is empty")
                Harness.expectTrue(
                    frame.contains("oilbird scan"), "it does not name the way out: \(frame)")
            }
        }

        // No colour anywhere: NO_COLOR is pinned, so the frame is plain text
        // and a diff of two frames is a diff of the LAYOUT.
        Harness.test("a pinned frame carries no escape sequences") {
            onMain {
                let frame = rendered(ProjectsScreen(projects: [.init(id: "a", name: "b")]))
                Harness.expectTrue(
                    !frame.contains("\u{1B}"), "an escape sequence reached a pinned frame")
            }
        }
    }
}

func summaryScreenTests() {
    /// A gate result as the server gives it, with however much source the
    /// facade found. `lines` nil is the state that caused this: a field
    /// nobody filled, read as "code was read".
    func gate(conditions: Int, lines: Int?) -> SonarAPI.GateResult {
        var result = SonarAPI.GateResult(
            gate: .ok,
            conditions: (0..<conditions).map { _ in
                SonarAPI.GateResult.Condition(
                    status: "OK", metricKey: "new_violations", comparator: "GT",
                    errorThreshold: "0", actualValue: "0")
            })
        result.linesAnalysed = lines
        return result
    }

    Harness.suite("Summary — a verdict about nothing says so") {
        // ⚠ The case that shipped. From the SECOND scan of a project nothing
        // read, SonarQube supplies conditions, so `judgedNothing` is false —
        // and `summary` reported gate OK, A ratings and 0 issues.
        Harness.test("a project that read nothing is not summarised as a pass") {
            onMain {
                let drawn = Frames.summary(
                    of: Oilbird.Summary(
                        project: "empty-1234", gate: gate(conditions: 1, lines: 0),
                        measures: [:], severities: [:], types: [:], total: 0,
                        taxonomy: .mqr),
                    width: 96)
                Harness.expectTrue(
                    drawn.contains("NO CODE WAS READ"),
                    "a summary of unread code did not say so: \(drawn.prefix(200))")
            }
        }

        // ⚠ And the two facts stay apart. "no baseline yet" tells a reader to
        // scan again, which is right for one of these and useless for the
        // other.
        Harness.test("no baseline and no code are different sentences") {
            onMain {
                let noBaseline = Frames.summary(
                    of: Oilbird.Summary(
                        project: "fresh-1234", gate: gate(conditions: 0, lines: 703),
                        measures: ["ncloc": "703"], severities: [:], types: [:], total: 0,
                        taxonomy: .mqr),
                    width: 96)
                Harness.expectTrue(
                    noBaseline.contains("no baseline yet"),
                    "a first analysis did not say why it judged nothing")
                Harness.expectTrue(
                    !noBaseline.contains("NO CODE WAS READ"),
                    "a project with 703 lines was reported as having read nothing")
            }
        }
    }

    Harness.suite("Summary — the gate, drawn against what judges it") {
        // ⚠ The comparator decides which end fails: `LT` below the threshold
        // (coverage under 80), `GT` above it (duplication over 3). Backwards,
        // a healthy project is red and a failing one green.
        Harness.test("a coverage floor is critical below the threshold") {
            let bands = GateConditionRow.bands(
                threshold: 80, total: 100, comparator: "LT")
            Harness.expectEqual(bands.count, 2, "wrong number of bands")
            Harness.expectEqual(bands[0].upperBound, 80, "the band does not end at the threshold")
            Harness.expectTrue(
                bands[0].tone == .critical, "below a coverage floor was not drawn as a failure")
            Harness.expectTrue(
                bands[1].tone == .success, "above a coverage floor was not drawn as a pass")
        }

        Harness.test("a duplication ceiling is critical above the threshold") {
            let bands = GateConditionRow.bands(
                threshold: 3, total: 100, comparator: "GT")
            Harness.expectTrue(
                bands[0].tone == .success, "below a ceiling was not drawn as a pass")
            Harness.expectTrue(
                bands[1].tone == .critical, "above a ceiling was not drawn as a failure")
        }

        // ⚠ A gauge needs a denominator. `new_violations` has none — three
        // issues against a threshold of zero is not three percent of anything
        // — so it must not be drawn as a bar whose fullness is invented.
        Harness.test("a metric with no scale is not drawn as a bar") {
            let counted = GateConditionRow.Condition(
                metric: "new_violations", comparator: "GT", threshold: "0",
                actual: "3", failed: true)
            Harness.expectNil(counted.scale, "a count was given a percentage scale")

            let percentage = GateConditionRow.Condition(
                metric: "new_coverage", comparator: "LT", threshold: "80",
                actual: "64.2", failed: true)
            Harness.expectEqual(percentage.scale, 100, "a percentage was denied its scale")
        }

        // ⚠ The halves are different lengths: four measures beside three
        // families and a hotspot line. Zipping drops the longer side's rows
        // silently, which is how a measure disappears for a month.
        Harness.test("the two halves pad rather than truncate") {
            let rows = SummaryScreen.halves(
                [.init(label: "security", rating: "A", count: "0")],
                [
                    .init(label: "coverage", value: "64.2%"),
                    .init(label: "duplication", value: "1.1%"),
                    .init(label: "debt", value: "12 min"),
                ])
            Harness.expectEqual(rows.count, 3, "the longer half was truncated")
            Harness.expectEqual(rows[0][0].text, "security", "the family is missing")
            Harness.expectEqual(rows[2][4].text, "debt", "the third measure was dropped")
            Harness.expectEqual(rows[2][0].text, "", "a missing family invented a label")
        }

        Harness.test("a gate that judged nothing does not read as a pass") {
            onMain {
                let frame = renderedSummary(
                    .init(
                        project: "web-app-deaa", size: nil, verdict: "OK",
                        verdictIsFailure: false, judgedNothing: true, conditions: [],
                        failedCount: 0, families: [], measures: []))
                Harness.expectTrue(
                    frame.contains("nothing was checked"),
                    "an unjudged gate printed a bare OK: \(frame)")
            }
        }

        Harness.test("a failing condition names the threshold it missed") {
            onMain {
                let frame = renderedSummary(
                    .init(
                        project: "web-app-deaa", size: "1,204 lines", verdict: "FAILED",
                        verdictIsFailure: true, judgedNothing: false,
                        conditions: [
                            .init(
                                metric: "new_violations", comparator: "GT", threshold: "0",
                                actual: "3", failed: true)
                        ], failedCount: 1,
                        families: [.init(label: "security", rating: "A", count: "0")],
                        measures: [.init(label: "coverage", value: "64.2%")]))
                Harness.expectTrue(
                    frame.contains("New violations"), "the metric is not named: \(frame)")
                Harness.expectTrue(
                    frame.contains("3"), "the measured value is missing")
                Harness.expectTrue(
                    frame.contains("0"), "the threshold is missing")
            }
        }
    }
}

func gateScreenTests() {
    Harness.suite("Gate — three answers, not one with footnotes") {
        // ⚠ Each of these is a screen a CI author reads while deciding what
        // to branch on, so each names its own exit code. The two that are not
        // failures are the dangerous ones: both once printed OK and exited 0.
        Harness.test("an analysis that read nothing says so, and names exit 3") {
            onMain {
                let frame = renderedGate(project: "web-app-deaa", .readNothing(said: "OK"))
                Harness.expectTrue(
                    frame.contains("read nothing"), "it does not say it read nothing")
                Harness.expectTrue(
                    frame.contains("exit 3"), "it does not name the exit code: \(frame)")
                Harness.expectTrue(
                    !frame.split(separator: "\n").contains(where: {
                        $0.trimmingCharacters(in: .whitespaces) == "OK"
                    }),
                    "a bare OK is on screen for an analysis that read nothing")
            }
        }

        Harness.test("a gate with no baseline says so, and names exit 3") {
            onMain {
                let frame = renderedGate(project: "web-app-deaa", .judgedNothing(said: "OK"))
                Harness.expectTrue(
                    frame.contains("nothing was checked"), "it does not say nothing was checked")
                Harness.expectTrue(frame.contains("exit 3"), "it does not name the exit code")
                Harness.expectTrue(
                    frame.contains("Scan again"), "it does not name the way out")
            }
        }

        // ⚠ Only the failures are drawn. A passing gate with twelve
        // conditions is a wall of bars saying nothing; the question `gate`
        // answers is "what stopped me".
        Harness.test("a real verdict draws the failures and not the passes") {
            onMain {
                let frame = renderedGate(
                    project: "web-app-deaa",
                    .judged(
                        failed: true, failedCount: 1,
                        conditions: [
                            .init(
                                metric: "new_coverage", comparator: "LT", threshold: "80",
                                actual: "64.2", failed: true),
                            .init(
                                metric: "new_duplicated_lines_density", comparator: "GT",
                                threshold: "3", actual: "0.0", failed: false),
                        ]))
                Harness.expectTrue(frame.contains("FAILED"), "the verdict is missing")
                Harness.expectTrue(
                    frame.contains("New coverage"), "the failing condition is not named")
                Harness.expectTrue(
                    !frame.contains("New duplicated"),
                    "a passing condition was drawn: \(frame)")
            }
        }
    }
}

func historyScreenTests() {
    Harness.suite("History — the trend, before the figures") {
        func point(_ date: String, _ issues: String) -> HistoryScreen.Point {
            .init(
                analysed: date, issues: issues, coverage: "0.0%",
                issueCount: Double(issues))
        }

        // ⚠ A sparkline of one value is a dot that reads as a trend. A
        // project scanned once has no trend, and drawing one implies a
        // direction nobody measured.
        Harness.test("one analysis is not a trend") {
            Harness.expectNil(
                HistoryScreen.trend([point("a", "3")]), "a single point was drawn as a line")
            Harness.expectTrue(
                HistoryScreen.trend([point("a", "3"), point("b", "1")]) != nil,
                "two points were not enough for a line")
        }

        // ⚠ A measure that did not report is not a zero. One missing count
        // among five would otherwise draw a cliff to the floor that never
        // happened.
        Harness.test("a missing count suppresses the line rather than reading as zero") {
            let mixed = [
                point("a", "3"),
                HistoryScreen.Point(analysed: "b", issues: "—", coverage: "—", issueCount: nil),
                point("c", "1"),
            ]
            Harness.expectNil(
                HistoryScreen.trend(mixed), "a gap in the counts was drawn as a line")
        }

        // ⚠ Fewer issues than we started with is good news, and the line
        // should say so before the numbers are read. End to end, not against
        // the last step: one noisy analysis in the middle is not the story.
        Harness.test("the tone follows the whole run, not the last step") {
            Harness.expectTrue(
                HistoryScreen.tone([5, 9, 2]) == .success, "an improvement was not good news")
            Harness.expectTrue(
                HistoryScreen.tone([2, 1, 5]) == .warning, "a regression was not flagged")
            Harness.expectTrue(
                HistoryScreen.tone([3, 7, 3]) == .info, "no change was given a direction")
        }

        // ⚠ "One analysis is not a trend" above, applied to the SENTENCE as
        // well as the sparkline: with one analysis there is nothing before
        // it, and "nothing changed" reads as "no regressions".
        Harness.test("one analysis has nothing to compare against, and says that") {
            onMain {
                @MainActor func frame(_ points: [HistoryScreen.Point], total: Int) -> String {
                    RenderOnce.render(
                        HistoryScreen(
                            project: "crawler-121343c9", points: points, total: total,
                            changes: []),
                        width: 96, options: try? SwiftTUIOptions.parse([]),
                        environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"],
                        isStdoutTTY: false)
                }
                let only = frame([point("a", "18")], total: 1)
                Harness.expectTrue(
                    only.contains("only analysis"),
                    "a single analysis did not say it had nothing to compare with: \(only)")
                Harness.expectTrue(
                    !only.contains("Nothing changed"),
                    "a single analysis was reported as unchanged: \(only)")
                let two = frame([point("a", "18"), point("b", "18")], total: 2)
                Harness.expectTrue(
                    two.contains("Nothing changed"),
                    "two equal analyses were not reported as unchanged: \(two)")
            }
        }

        Harness.test("a window says it is one") {
            onMain {
                let frame = RenderOnce.render(
                    HistoryScreen(
                        project: "web-app-deaa",
                        points: [point("a", "1"), point("b", "2")], total: 21, changes: []),
                    width: 96, options: try? SwiftTUIOptions.parse([]),
                    environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"], isStdoutTTY: false)
                Harness.expectTrue(
                    frame.contains("last 2 of 21"), "a window did not say so: \(frame)")
            }
        }
    }
}

func scansScreenTests() {
    Harness.suite("Scans — what is running and what has run") {
        func row(_ key: String, _ verdict: String, _ role: Int) -> ScansScreen.Row {
            .init(key: key, verdict: verdict, verdictRole: role, when: "2m", detail: "~/code")
        }

        Harness.test("nothing scanned names both ways to start one") {
            onMain {
                let frame = renderedScans(.init(running: [], finished: [], finishedTotal: 0))
                Harness.expectTrue(frame.contains("nothing has been scanned"), "it does not say so")
                for command in ["oilbird scan <path>", "oilbird scan <path> --detach"] {
                    Harness.expectTrue(
                        frame.split(separator: "\n").contains(where: { $0.contains(command) }),
                        "`\(command)` is missing or broken across lines")
                }
            }
        }

        // ⚠ A bounded list that does not say it is bounded is a list that
        // silently lost rows. `history` learned this and so did this screen.
        Harness.test("a truncated list says how many it is hiding") {
            onMain {
                let frame = renderedScans(
                    .init(
                        running: [], finished: [row("a", "OK", Role.ok)], finishedTotal: 24))
                Harness.expectTrue(
                    frame.contains("23 more"), "a truncated list hid the remainder: \(frame)")
            }
        }

        Harness.test("a complete list says nothing about a remainder") {
            onMain {
                let frame = renderedScans(
                    .init(running: [], finished: [row("a", "OK", Role.ok)], finishedTotal: 1))
                Harness.expectTrue(
                    !frame.contains("more —"), "a complete list claimed a remainder")
            }
        }

        // ⚠ Anything that is not OK or FAILED is amber, never dim: an
        // interrupted scan is a thing to look at, and filing an unfamiliar
        // verdict as a footnote is how it stops being looked at.
        Harness.test("an unfamiliar verdict is flagged rather than filed away") {
            Harness.expectEqual(Frames.verdictRole("OK"), Role.ok, "OK was not good news")
            Harness.expectEqual(Frames.verdictRole("FAILED"), Role.fail, "FAILED was not bad news")
            Harness.expectEqual(
                Frames.verdictRole("interrupted"), Role.warn,
                "an unfamiliar verdict was filed as a footnote")
            Harness.expectEqual(
                Frames.verdictRole("read nothing"), Role.warn,
                "an unfamiliar verdict was filed as a footnote")
        }
    }
}

func diagnosisRowTests() {
    Harness.suite("Doctor — one row, as its check finishes") {
        // ⚠ `wait` is its own token and NOT a failure: the scanner cannot be
        // checked until the server is up, and FAIL beside a correct dependency
        // sends people off to reinstall it.
        Harness.test("waiting is not failing") {
            onMain {
                let frame = renderedDiagnosis(
                    "scanner",
                    .waiting(found: "7.3.0", why: "the server is not up", next: "oilbird up"))
                Harness.expectTrue(frame.contains("wait"), "it does not say it is waiting")
                Harness.expectTrue(
                    !frame.contains("FAIL"), "a waiting check was drawn as a failure: \(frame)")
                Harness.expectTrue(
                    frame.contains("oilbird up"), "it does not name the way out")
            }
        }

        // ⚠ The token carries severity by CASE as well as colour, which is
        // what survives NO_COLOR, a monochrome terminal and a screenshot, and
        // why `grep -c ok` works on the piped form.
        Harness.test("the token shouts or does not, without colour") {
            onMain {
                Harness.expectTrue(
                    renderedDiagnosis("jdk", .working("21.0.12")).contains("ok"),
                    "a healthy row does not read ok")
                Harness.expectTrue(
                    renderedDiagnosis("jdk", .failed("nothing installed")).contains("FAIL"),
                    "a failure does not shout")
            }
        }

        Harness.test("every row is indented like the page it lands in") {
            onMain {
                for state: DiagnosisRow.State in [
                    .working("1"), .failed("x"), .waiting(found: "", why: "y", next: "z"),
                ] {
                    let first = renderedDiagnosis("jdk", state).split(separator: "\n").first ?? ""
                    Harness.expectTrue(
                        first.hasPrefix("  "), "a row is flush to the margin: [\(first)]")
                }
            }
        }
    }
}

@MainActor func renderedDiagnosis(
    _ dependency: String, _ state: DiagnosisRow.State, width: Int = 76
) -> String {
    RenderOnce.render(
        DiagnosisRow(dependency: dependency, state: state), width: width,
        options: try? SwiftTUIOptions.parse([]),
        environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"], isStdoutTTY: false)
}

func statusScreenTests() {
    Harness.suite("Status — five states, each with its own answer") {
        // ⚠ The facts must reflow WITH the word, not around it. An `HStack`
        // wrapped each independently and put `127.0.0.1:56434 · up 8m …`
        // ABOVE the word `running` it described.
        Harness.test("the state word comes before the facts it describes") {
            onMain {
                for width in [96, 80, 60] {
                    let frame = renderedStatus(
                        .running(
                            facts: [
                                "127.0.0.1:56434", "up 1h 19m", "316 MB",
                                "stops after 30 minutes unused",
                            ], dashboard: "http://127.0.0.1:56434"),
                        width: width)
                    let lines = frame.split(separator: "\n").map(String.init)
                    guard let word = lines.firstIndex(where: { $0.contains("running") }),
                        let fact = lines.firstIndex(where: { $0.contains("127.0.0.1:56434") })
                    else {
                        Harness.expectTrue(false, "the state or its facts are missing")
                        return
                    }
                    Harness.expectTrue(
                        word <= fact,
                        "at \(width) columns the facts came before the state: \(frame)")
                }
            }
        }

        // ⚠ Its own state AND its own exit code. A script treating this as
        // running makes the next call fail for no visible reason; one
        // treating it as stopped never repairs it.
        Harness.test("not answering names its exit code and the way out") {
            onMain {
                let frame = renderedStatus(.unresponsive(address: "127.0.0.1:56434"))
                Harness.expectTrue(frame.contains("NOT ANSWERING"), "the state is missing")
                Harness.expectTrue(frame.contains("exit 3"), "the exit code is not named")
                Harness.expectTrue(
                    frame.split(separator: "\n").contains(where: { $0.contains("oilbird up") }),
                    "the way out is missing or broken across lines")
            }
        }

        // ⚠ No invented reason. The lock this is derived from carries none
        // across processes, so it states the RULE whether the watchdog
        // stopped it or someone typed `down` a moment ago.
        Harness.test("paused states the rule rather than a reason") {
            onMain {
                let frame = renderedStatus(.paused(rule: "stops after 30 minutes unused"))
                Harness.expectTrue(frame.contains("stops after 30 minutes"), "the rule is missing")
                Harness.expectTrue(
                    !frame.lowercased().contains("because"), "a reason was invented: \(frame)")
            }
        }

        Harness.test("not set up says what it would fetch, and what it needs") {
            onMain {
                let frame = renderedStatus(.notInstalled)
                Harness.expectTrue(frame.contains("no Java"), "it does not say it needs nothing")
                for command in ["oilbird up", "oilbird version"] {
                    Harness.expectTrue(
                        frame.split(separator: "\n").contains(where: { $0.contains(command) }),
                        "`\(command)` is missing or broken across lines")
                }
            }
        }
    }
}

@MainActor func renderedStatus(_ state: StatusScreen.State, width: Int = 76) -> String {
    RenderOnce.render(
        StatusScreen(state: state), width: width, options: try? SwiftTUIOptions.parse([]),
        environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"], isStdoutTTY: false)
}

@MainActor func renderedScans(_ screen: ScansScreen, width: Int = 76) -> String {
    RenderOnce.render(
        screen, width: width, options: try? SwiftTUIOptions.parse([]),
        environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"], isStdoutTTY: false)
}

@MainActor func renderedGate(
    project: String, _ verdict: GateScreen.Verdict, width: Int = 76
) -> String {
    RenderOnce.render(
        GateScreen(project: project, verdict: verdict), width: width,
        options: try? SwiftTUIOptions.parse([]),
        environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"],
        isStdoutTTY: false)
}

@MainActor func renderedSummary(_ model: SummaryScreen.Model, width: Int = 76) -> String {
    RenderOnce.render(
        SummaryScreen(model: model), width: width,
        options: try? SwiftTUIOptions.parse([]),
        environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"],
        isStdoutTTY: false)
}

/// ⚠ `assumeIsolated`, not a hop. `View` is `@MainActor` and the suites are
/// driven from `main.swift`, whose top-level code already runs on the main
/// actor — so this asserts a fact rather than changing one. A hop would
/// deadlock here, because the harness is synchronous.
func onMain(_ body: @MainActor () -> Void) { MainActor.assumeIsolated(body) }

/// One frame, with every environmental input pinned.
@MainActor func rendered(_ screen: ProjectsScreen, width: Int = 76) -> String {
    RenderOnce.render(
        screen, width: width,
        options: try? SwiftTUIOptions.parse([]),
        environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"],
        isStdoutTTY: false)
}
