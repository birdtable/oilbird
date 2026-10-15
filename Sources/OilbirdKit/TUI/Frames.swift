import Foundation
import OilbirdCore
import OilbirdModel
import SwiftTUIArguments
import SwiftTUICLI
import SwiftTUIRuntime

/// One committed frame of a screen, as text.
///
/// ⚠ The clients never see SwiftTUI. `OilbirdCLI` is composition only — argv
/// in, a Kit call, a shape out — and the `targets` check holds it there. A CLI that
/// imported the UI framework to build a view would be holding logic in the one
/// target no test can reach.
///
/// ⚠ And this renders, it does not print. `RenderOnce` owns nothing: no
/// alternate screen, no signal handlers, no run loop. That is what keeps
/// `oilbird scan . --json | jq` working, because the caller decides where the
/// string goes and stdout stays clear for the JSON.
public enum Frames {
    /// The width to lay out for, in terminal cells.
    ///
    /// ⚠ **Zero is not a width, it is "we do not know".** `UI.columns` is 0
    /// whenever stdout is not a terminal, which is how the rest of the CLI
    /// asks "do we know how wide the screen is?" — and passing it through
    /// produced a frame laid out for no columns at all. The table still drew,
    /// because its cells carry their own widths, and the trailing line that
    /// names the next command was silently dropped: `oilbird projects | cat`
    /// lost its last row and nothing failed.
    ///
    /// 80 is the same floor `RenderOnce` falls back to, so a piped frame and
    /// a redirected one agree.
    public static func width(_ columns: Int?) -> Int {
        guard let columns, columns > 0 else { return 80 }
        return columns
    }

    @MainActor public static func projects(
        _ projects: [ProjectsScreen.Project], width columns: Int? = nil
    ) -> String {
        render(ProjectsScreen(projects: projects), width: width(columns))
    }

    @MainActor public static func summary(
        _ model: SummaryScreen.Model, width columns: Int? = nil
    ) -> String {
        render(SummaryScreen(model: model), width: width(columns))
    }

    /// A summary, arranged for the screen.
    ///
    /// ⚠ Here rather than in the client, because the arrangement carries
    /// knowledge the client has no business holding. The families are the
    /// ones the SERVER judges by: asking for the legacy taxonomy on a server
    /// running MQR — which 26.9 does out of the box — printed
    /// `reliability 34` beside Oilbird's own embedded dashboard reading 111,
    /// for the same project, in the same window. Neither number was wrong.
    /// They count different things.
    @MainActor public static func summary(
        of summary: Oilbird.Summary, width columns: Int? = nil
    ) -> String {
        let families =
            summary.taxonomy == .mqr
            ? [
                ("security", "SECURITY", "security_rating"),
                ("reliability", "RELIABILITY", "reliability_rating"),
                ("maintainability", "MAINTAINABILITY", "sqale_rating"),
            ]
            : [
                ("security", "VULNERABILITY", "security_rating"),
                ("reliability", "BUG", "reliability_rating"),
                ("maintainability", "CODE_SMELL", "sqale_rating"),
            ]
        var left = families.map { label, family, rating in
            SummaryScreen.Family(
                label: label,
                rating: Oilbird.ratingLetter(summary.measures[rating]) ?? "—",
                count: summary.types[family].map(String.init) ?? "—")
        }
        // ⚠ Hotspots are never a count of problems. SonarQube reports how
        // many need REVIEWING, and printing the bare number beside three
        // issue counts reads as "and this many more bugs".
        left.append(
            SummaryScreen.Family(
                label: "hotspots",
                rating: Oilbird.ratingLetter(summary.measures["security_review_rating"]) ?? "—",
                count: summary.measures["security_hotspots"].map { "\($0) to review" } ?? "—"))

        let right = [
            ("coverage", "coverage", "%"), ("duplicated_lines_density", "duplication", "%"),
            ("sqale_index", "debt", " min"), ("cognitive_complexity", "complexity", ""),
        ].map { key, label, suffix in
            SummaryScreen.Measure(
                label: label,
                value: summary.measures[key].map { $0 + suffix } ?? "—")
        }

        let failed = summary.gate.gate == .error || !summary.gate.gate.isRecognised
        return self.summary(
            SummaryScreen.Model(
                project: summary.project,
                size: summary.measures["ncloc"].map { $0 + " lines" },
                verdict: failed ? "FAILED" : summary.gate.gate.rawValue,
                verdictIsFailure: failed,
                judgedNothing: summary.gate.judgedNothing,
                readNothing: summary.gate.readNothing,
                conditions: summary.gate.conditions.map {
                    .init(
                        metric: $0.metricKey, comparator: $0.comparator,
                        threshold: $0.errorThreshold, actual: $0.actualValue,
                        failed: $0.status.uppercased() == "ERROR")
                },
                failedCount: summary.gate.failed.count,
                families: left, measures: right),
            width: columns)
    }

    @MainActor public static func gate(
        project: String, result: SonarAPI.GateResult, width columns: Int? = nil
    ) -> String {
        let verdict: GateScreen.Verdict
        if result.readNothing {
            verdict = .readNothing(said: result.gate.rawValue)
        } else if result.judgedNothing {
            verdict = .judgedNothing(said: result.gate.rawValue)
        } else {
            verdict = .judged(
                failed: result.gate == .error || !result.gate.isRecognised,
                failedCount: result.failed.count,
                conditions: result.conditions.map {
                    .init(
                        metric: $0.metricKey, comparator: $0.comparator,
                        threshold: $0.errorThreshold, actual: $0.actualValue,
                        failed: $0.status.uppercased() == "ERROR")
                })
        }
        return render(
            GateScreen(project: project, verdict: verdict), width: width(columns))
    }

    @MainActor public static func history(
        project: String, snapshots: [SonarAPI.Snapshot], changes: [String],
        width columns: Int? = nil
    ) -> String {
        let shown = min(snapshots.count, Oilbird.historyWindow)
        let points = snapshots.suffix(shown).map { snapshot in
            HistoryScreen.Point(
                analysed: String(snapshot.date.prefix(19)),
                issues: snapshot.measures["violations"] ?? "—",
                coverage: snapshot.measures["coverage"].map { $0 + "%" } ?? "—",
                issueCount: snapshot.measures["violations"].flatMap(Double.init))
        }
        return render(
            HistoryScreen(
                project: project, points: Array(points), total: snapshots.count,
                changes: changes),
            width: width(columns))
    }

    @MainActor public static func version(
        build: String, commit: String?, rows: [Oilbird.VersionRow], width columns: Int? = nil
    ) -> String {
        render(
            VersionScreen(
                build: build, commit: commit,
                rows: rows.map { row in
                    // ⚠ `installed` is a stronger claim than `detected`, and
                    // the two are not the same alphabet. A recorded difference
                    // is a real bump and earns amber; a detected one is dim.
                    if let recorded = row.installed {
                        return .init(
                            id: row.id, pinned: row.pinned,
                            installed: recorded == row.pinned ? "same" : recorded,
                            installedRole: recorded == row.pinned ? Role.ok : Role.warn,
                            licence: row.licence, differs: row.differs)
                    }
                    guard let found = row.detected else {
                        return .init(
                            id: row.id, pinned: row.pinned, installed: "—",
                            installedRole: Role.dim, licence: row.licence, differs: false)
                    }
                    return .init(
                        id: row.id, pinned: row.pinned,
                        installed: found == row.pinned ? "same" : found,
                        installedRole: found == row.pinned ? Role.ok : Role.dim,
                        licence: row.licence, differs: false)
                }),
            width: width(columns))
    }

    @MainActor public static func scans(
        _ entries: [Scans.Entry], width columns: Int? = nil
    ) -> String {
        let running = entries.filter { $0.state == .running }
        let over = entries.filter { $0.state != .running }
        let shown = Array(over.prefix(10))
        return render(
            ScansScreen(
                running: running.map {
                    .init(
                        key: $0.key, verdict: $0.verdict, verdictRole: Role.typed,
                        when: Oilbird.humanDuration($0.elapsed),
                        detail: Oilbird.displayPath($0.path))
                },
                finished: shown.map {
                    .init(
                        key: $0.key, verdict: $0.verdict, verdictRole: verdictRole($0.verdict),
                        when: Oilbird.humanAgo($0.finished ?? $0.started), detail: $0.read)
                },
                finishedTotal: over.count),
            width: width(columns))
    }

    /// ⚠ Anything that is not OK or FAILED is amber, never dim. A scan that
    /// was interrupted or read nothing is a thing to look at, and filing an
    /// unfamiliar verdict as a footnote is how it stops being looked at.
    nonisolated public static func verdictRole(_ verdict: String) -> Int {
        switch verdict {
        case "OK": Role.ok
        case "FAILED": Role.fail
        default: Role.warn
        }
    }

    /// One `doctor` row, as its check finishes.
    @MainActor public static func diagnosis(
        _ entry: Oilbird.Diagnosis, width columns: Int? = nil
    ) -> String {
        let state: DiagnosisRow.State =
            switch entry.outcome {
            case .checked(.present(let version)): .working(version)
            case .checked(.missing):
                .failed("Nothing is installed. `oilbird install` fetches it.")
            case .checked(.corrupt(let reason)): .failed(reason)
            case .unverifiable(let blocked, let onDisk):
                .waiting(
                    found: { if case .present(let v) = onDisk { v } else { "" } }(),
                    why: blocked.detail, next: blocked.recovery.actionLabel)
            }
        return render(
            DiagnosisRow(dependency: entry.id.rawValue, state: state), width: width(columns))
    }

    @MainActor public static func configuration(
        _ current: Oilbird.Configuration, width columns: Int? = nil
    ) -> String {
        let settings: [ConfigurationScreen.Setting] = [
            .init(
                label: "name",
                value: current.chosenName.map { "\($0)   at the next scan" }
                    ?? "after its directory",
                chosen: current.chosenName != nil),
            .init(
                label: "tags",
                value: current.tags.isEmpty ? "none" : current.tags.joined(separator: ", "),
                chosen: !current.tags.isEmpty),
            .init(
                label: "new code",
                value: current.newCode.map {
                    $0 + (current.newCodeInherited ? "   inherited" : "")
                } ?? "the server's default",
                chosen: current.newCode != nil && !current.newCodeInherited),
            .init(
                label: "branch", value: current.branch ?? "not analysed yet",
                chosen: current.branch != nil),
            .init(
                label: "excluded",
                value: current.exclusions.isEmpty
                    ? "nothing beyond the global list" : current.exclusions.joined(separator: ", "),
                chosen: !current.exclusions.isEmpty),
        ]
        return render(
            ConfigurationScreen(
                project: current.project, settings: settings,
                offers: [
                    .init(
                        command: "oilbird configure \(current.project) --name \"A Name\"",
                        what: "what it is called"),
                    .init(
                        command: "oilbird configure \(current.project) --tags a,b",
                        what: "how you group it"),
                    .init(
                        command: "oilbird configure \(current.project) --new-code 30",
                        what: "what counts as new"),
                    .init(
                        command: "oilbird configure \(current.project) --exclude 'gen/**'",
                        what: "what it skips"),
                ]),
            width: width(columns))
    }

    @MainActor public static func apiServices(
        _ catalogue: APICatalogue, width columns: Int? = nil
    ) -> String {
        render(APIServicesScreen(catalogue: catalogue), width: width(columns))
    }

    @MainActor public static func apiEndpoints(
        _ endpoints: [APICatalogue.Endpoint], title: String, about: String = "",
        width columns: Int? = nil
    ) -> String {
        render(
            APIEndpointsScreen(endpoints: endpoints, title: title, about: about),
            width: width(columns))
    }

    @MainActor public static func apiEndpoint(
        _ endpoint: APICatalogue.Endpoint, width columns: Int? = nil
    ) -> String {
        render(APIEndpointScreen(endpoint: endpoint), width: width(columns))
    }

    @MainActor public static func status(
        _ state: StatusScreen.State, width columns: Int? = nil
    ) -> String {
        render(StatusScreen(state: state), width: width(columns))
    }

    @MainActor public static func scanResult(
        project: String, outcome: ScanResultScreen.Outcome, width columns: Int? = nil
    ) -> String {
        render(
            ScanResultScreen(project: project, outcome: outcome), width: width(columns))
    }

    @MainActor public static func error(
        _ what: String, advice: [Offers.Offer] = [], note: String = "",
        width columns: Int? = nil
    ) -> String {
        render(
            ErrorScreen(what: what, advice: advice, note: note), width: width(columns))
    }

    @MainActor public static func readNothing(
        path: String, because: String, width columns: Int? = nil
    ) -> String {
        render(ReadNothingScreen(path: path, because: because), width: width(columns))
    }

    /// Every verb, grouped by what it costs to run.
    ///
    /// ⚠ The table lives here and nowhere else. the `parity` check holds it
    /// against the switch that dispatches, because `configure` once shipped
    /// dispatched, in `Usage.verbs`, with an MCP twin and every gate green —
    /// and absent from `--help`, which is the only place anyone would have
    /// looked for it.
    @MainActor public static func help(build: String, width columns: Int? = nil) -> String {
        render(
            HelpScreen(
                build: build,
                sections: [
                    .init(
                        title: "LOOK AT CODE",
                        verbs: [
                            .init(command: "scan <path>", what: "analyse a directory"),
                            .init(command: "issues <key>", what: "what the last scan found"),
                            .init(
                                command: "gate <key>",
                                what: "the quality gate's verdict (exit 4 if it failed)"),
                            .init(command: "summary <key>", what: "gate, measures, issue counts"),
                            .init(
                                command: "history <key>",
                                what: "how it changed, analysis by analysis"),
                            .init(command: "projects", what: "everything scanned so far"),
                            .init(
                                command: "forget <key>", what: "remove a project and its results"),
                            .init(
                                command: "api [call] [k=v]",
                                what: "every other call this SonarQube has (302 of them)"),
                        ]),
                    .init(
                        title: "LOOK AT OILBIRD",
                        verbs: [
                            .init(command: "status", what: "what is running, if anything"),
                            .init(
                                command: "doctor", what: "check every dependency by running it"),
                            .init(
                                command: "version", what: "this build, and the versions it pins"),
                            .init(command: "log [lines]", what: "the log every failure points at"),
                            .init(command: "scans", what: "what is running, and what has run"),
                            .init(
                                command: "follow <key>",
                                what: "attach to a running scan, or read a finished one"),
                            .init(command: "configure <key>", what: "what a project is called"),
                        ]),
                    .init(
                        title: "RUN IT",
                        verbs: [
                            .init(command: "up | down", what: "start or stop the engine"),
                            .init(command: "idle [45|2h|never]", what: "when it stops itself"),
                            .init(command: "install", what: "download and unpack what is missing"),
                            .init(command: "cli-install", what: "put oilbird on your PATH"),
                            .init(
                                command: "watch",
                                what: "supervise a running engine and stop it when idle"),
                        ]),
                ]),
            width: width(columns))
    }

    @MainActor public static func welcome(
        items: [WelcomeScreen.Item], total: String, width columns: Int? = nil
    ) -> String {
        render(WelcomeScreen(items: items, total: total), width: width(columns))
    }

    @MainActor public static func paused(
        retrying: String, idle: String, width columns: Int? = nil
    ) -> String {
        render(PausedScreen(retrying: retrying, idle: idle), width: width(columns))
    }

    @MainActor public static func notice(
        _ notice: Notice, width columns: Int? = nil
    ) -> String {
        render(notice, width: width(columns))
    }

    /// A frame from a synchronous caller, or nil when it cannot be had.
    ///
    /// ⚠ The renderer is `@MainActor` and some of the callers that most need
    /// it are not: `die` returns `Never`, so it can neither `await` nor be
    /// made async without changing thirty call sites. `assumeIsolated` would
    /// reach it, and would TRAP when the caller is off the main actor — in
    /// the error path, which is the one place a crash instead of an
    /// explanation is unforgivable.
    ///
    /// So this asks rather than asserts, and returns nil when the answer is
    /// no. The caller keeps its old renderer for that case: two renderers for
    /// one screen is a real cost, and it is smaller than either a trap or a
    /// thirty-site refactor of the failure path.
    public static func ifOnMain(_ build: @MainActor () -> String) -> String? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { build() }
    }

    @MainActor static func render(_ screen: some View, width: Int) -> String {
        // ⚠ PUBLISHED as well as proposed. A proposal reaches the layout, not
        // a view deciding its own column widths before being measured, and the
        // framework's default `terminalSize` is 80 by 24.
        let snapshot = DefaultRenderer().render(
            screen.environment(\.terminalSize, CellSize(width: width, height: 0)),
            proposal: ProposedSize(width: width, height: nil))
        return TerminalSurfaceRenderer(capabilityProfile: capability())
            .render(snapshot.rasterSurface)
    }

    /// What this terminal can do, capped at sixteen colours.
    ///
    /// ⚠ **Capped, not detected-and-used.** The framework negotiates upward
    /// and will happily emit `38;5;163` on a 256-colour terminal. Oilbird has
    /// always painted with the terminal's own palette SLOTS — `36` is "the
    /// colour this reader chose for cyan", not a colour Oilbird picked — so
    /// the same screen suits a light terminal, a dark one and a Solarized
    /// one without Oilbird knowing which it is. A chosen RGB overrides the
    /// reader's theme, and the `screens` check catches it because that rule
    /// predates this renderer.
    ///
    /// Everything else is still detected: `NO_COLOR`, a dumb terminal and the
    /// locale's glyph policy all come from the environment, so the cap lowers
    /// the ceiling and never raises the floor.
    static func capability() -> TerminalCapabilityProfile {
        var profile = TerminalCapabilityProfile.detect(
            environment: ProcessInfo.processInfo.environment,
            isTTY: RenderOnce.standardOutputIsTTY())
        if profile.colorLevel == .ansi256 || profile.colorLevel == .trueColor {
            profile.colorLevel = .ansi16
        }
        return profile
    }
}
