import Foundation
import OilbirdModel

/// Names the SonarQube HTTP API — nothing else may.
///
/// Imports `Model` and nothing more, deliberately: its inputs are a base URL
/// and a token, passed in. It knows nothing about how the server got there,
/// which is what makes it testable against a fixture and reusable against a
/// remote SonarQube later.
public enum SonarAPI {
    /// The server's own vocabulary, verbatim.
    ///
    /// A poller sees three normal states in sequence: **connection refused**
    /// (Tomcat has not bound yet), then `starting`, then `up`. `down` is
    /// terminal and means a migration failed — surface the log rather than
    /// keep polling.
    public enum Status: String, Sendable, Decodable {
        case starting = "STARTING"
        case up = "UP"
        case down = "DOWN"
        case restarting = "RESTARTING"
        case migrationNeeded = "DB_MIGRATION_NEEDED"
        case migrationRunning = "DB_MIGRATION_RUNNING"

        /// Polling should stop: it will not become `up` on its own.
        public var isTerminal: Bool {
            self == .down || self == .migrationNeeded
        }
    }

    public struct SystemStatus: Sendable, Decodable {
        /// Optional because 26.10 omits it while the database needs migrating.
        /// Nothing reads it, and a required field the server drops makes every
        /// poll nil, so an upgrade never sees `DB_MIGRATION_NEEDED` and times out.
        public let id: String?
        public let version: String
        /// Exactly what the server said, decoded or not.
        ///
        /// ⚠ A raw string with a computed `status`, the same shape `Migration`
        /// was given for the same reason. As a non-optional enum, one word
        /// SonarQube had not used before made the WHOLE response undecodable,
        /// `systemStatus()` swallowed it with `try?` and returned nil, and the
        /// readiness poll could not tell "not up yet" from "up, and saying
        /// something I do not understand" — so it polled for 180 seconds and
        /// blamed a timeout. SonarQube has added states to this field before;
        /// that is why `RESTARTING` and the two migration states exist.
        public let state: String

        public var status: Status? { Status(rawValue: state) }

        private enum CodingKeys: String, CodingKey {
            case id, version
            case state = "status"
        }

        public init(id: String? = nil, version: String, state: String) {
            self.id = id
            self.version = version
            self.state = state
        }
    }

    /// Unauthenticated and available before the server is fully up, which is
    /// why it is the readiness endpoint.
    ///
    /// ⚠ Never probe `/setup`. It is a single-page-app route that returns 200
    /// unconditionally, so it answers "fine" for a server that is not.
    public static func systemStatus(base: URL) async -> SystemStatus? {
        var request = URLRequest(url: base.appending(path: "api/system/status"))
        request.timeoutInterval = 4
        guard let (data, response) = try? await HTTP.session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(SystemStatus.self, from: data)
    }
}

extension SonarAPI {
    public struct Issue: Sendable, Decodable, Equatable {
        public init(
            key: String, rule: String, severity: String, type: String?, component: String,
            line: Int?, message: String
        ) {
            self.init(
                key: key, rule: rule, severity: severity, type: type, component: component,
                line: line, message: message, impacts: [])
        }

        /// ⚠ A second initialiser rather than a defaulted parameter on the
        /// one above. A default argument changes the mangled symbol of what
        /// it is added to, and `swift build` did not rebuild the test target
        /// afterwards — it failed at the LINKER, looking for the seven-
        /// argument `init` that had just stopped existing. The same hazard
        /// `ensureRunning(onPhase:)` and `doctor(reporting:)` carry, met a
        /// third time.
        public init(
            key: String, rule: String, severity: String, type: String?, component: String,
            line: Int?, message: String, impacts: [Impact]
        ) {
            self.key = key
            self.rule = rule
            self.severity = severity
            self.type = type
            self.component = component
            self.line = line
            self.message = message
            self.rawImpacts = impacts
            self.effort = nil
        }

        /// What this issue threatens, and how badly, in MQR's terms.
        public struct Impact: Sendable, Decodable, Equatable {
            public let softwareQuality: String
            public let severity: String

            public init(softwareQuality: String, severity: String) {
                self.softwareQuality = softwareQuality
                self.severity = severity
            }
        }

        public let key: String
        public let rule: String
        /// The LEGACY severity, which is the only one this carried.
        ///
        /// ⚠ Both are in every payload and they disagree: the same issue is
        /// `severity: CRITICAL` and `impacts: [{severity: HIGH}]`. Oilbird
        /// printed the first while its own embedded dashboard showed the
        /// second, so `--severity HIGH` listed rows every one of which read
        /// CRITICAL. Read through `severity(in:)` rather than directly.
        public let severity: String
        /// ⚠ Decoded as OPTIONAL and exposed as a list. A synthesised
        /// decoder throws on a missing key, so a non-optional `[Impact]`
        /// would have made every issue from a server that does not send
        /// impacts undecodable — turning a cosmetic difference into "the
        /// server did not answer".
        private let rawImpacts: [Impact]?

        /// Empty on a server old enough not to send them.
        public var impacts: [Impact] { rawImpacts ?? [] }

        /// SonarQube's own estimate, like `15min` or `1h30min`. Absent on
        /// hotspots and on rules that carry no estimate.
        public let effort: String?

        private enum CodingKeys: String, CodingKey {
            case key, rule, severity, type, component, line, message, effort
            case rawImpacts = "impacts"
        }

        /// The severity this issue has in the taxonomy the server judges by.
        public func severity(in taxonomy: Taxonomy) -> String {
            guard taxonomy == .mqr, let worst = impacts.map(\.severity).min(by: rankedBefore)
            else { return severity }
            return worst
        }

        /// Worst first. An issue with two impacts takes the worse of them:
        /// showing the milder one beside a filter that matched on the
        /// harsher is how a row comes to contradict the command that found
        /// it.
        private func rankedBefore(_ a: String, _ b: String) -> Bool {
            let order = Taxonomy.mqr.severities
            return (order.firstIndex(of: a) ?? order.count)
                < (order.firstIndex(of: b) ?? order.count)
        }
        /// BUG, VULNERABILITY or CODE_SMELL.
        ///
        /// Dropped at the decoder until now, which made a security
        /// vulnerability indistinguishable from a naming quibble inside a
        /// list of fifteen hundred. On one real project the server knew
        /// about 22 vulnerabilities and 34 bugs and there was no way to
        /// find them.
        public let type: String?
        public let component: String
        public let line: Int?
        public let message: String
    }

    public struct Project: Sendable, Decodable {
        public let key: String
        public let name: String
    }

    /// The quality gate's own verdict. `none` means the project has never been
    /// analysed, which is different from failing.
    /// The quality gate's verdict, carrying whatever the server said.
    ///
    /// ⚠ A struct rather than an enum so that an unrecognised verdict
    /// survives instead of collapsing. `Gate(rawValue:) ?? .none` mapped any
    /// new status word to "never analysed", and `.none` is not a failure
    /// anywhere it is read, so `oilbird gate $KEY && deploy` would exit 0 and
    /// deploy. That is the third variant of this defect in this file: see
    /// `judgedNothing` and `linesAnalysed` above for the first two.
    public struct Gate: Sendable, Equatable {
        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue }

        public static let ok = Gate(rawValue: "OK")
        public static let error = Gate(rawValue: "ERROR")
        public static let none = Gate(rawValue: "NONE")

        /// Whether this is a verdict Oilbird knows how to read.
        ///
        /// A caller that treats anything but `.error` as a pass must ask this
        /// too, or a renamed verdict passes silently.
        public var isRecognised: Bool {
            self == .ok || self == .error || self == .none
        }
    }

    /// The URL an issue search uses.
    ///
    /// Split out so the query can be asserted without a server. The bug this
    /// exists to prevent was invisible from the outside: the call worked, it
    /// returned issues, and they were the wrong issues.
    /// Issues, and how many there really are.
    ///
    /// ⚠ The count is not `issues.count`. `api/issues/search` pages, and
    /// caps at 10,000 addressable results — so on a large project the
    /// honest answer is "N of M", and pretending otherwise is what this
    /// type exists to prevent.
    public struct Issues: Sendable {
        public let issues: [Issue]
        /// What the server says exists, which is the number a person wants.
        public let total: Int
        /// The taxonomy these were read in, so a row can be labelled the way
        /// the server judged it rather than the way the payload happens to
        /// spell the legacy field.
        public let taxonomy: Taxonomy
        public var truncated: Bool { issues.count < total }

        public init(issues: [Issue], total: Int) {
            self.init(issues: issues, total: total, taxonomy: .standard)
        }

        /// ⚠ A second initialiser, not a defaulted parameter — see `Issue`.
        public init(issues: [Issue], total: Int, taxonomy: Taxonomy) {
            self.issues = issues
            self.total = total
            self.taxonomy = taxonomy
        }
    }

    public static func issuesURL(
        base: URL, projectKey: String, severities: [String], page: Int = 1
    ) -> URL {
        var query = [
            URLQueryItem(name: "componentKeys", value: projectKey),
            // ⚠ Without this SonarQube returns CLOSED and FIXED issues too, so
            // scan-fix-rescan reports no change. The only tell is cosmetic: a
            // closed issue has no line and renders as `file.py:0`.
            URLQueryItem(name: "resolved", value: "false"),
            URLQueryItem(name: "ps", value: "500"),
            URLQueryItem(name: "p", value: String(page)),
        ]
        if !severities.isEmpty {
            query.append(
                URLQueryItem(
                    name: Taxonomy.parameter(narrowingBy: severities),
                    value: severities.joined(separator: ",")))
        }
        return base.appending(path: "api/issues/search").appending(queryItems: query)
    }

    /// Every issue, not the first page of them.
    ///
    /// ⚠ This asked for one page of 500, sent no page number, and threw the
    /// server's own `total` away — so a project with 1,559 issues was
    /// reported as having 500, and the 500 were not even the worst: 116 of
    /// its 187 BLOCKER and CRITICAL findings sat behind a confident number.
    /// Measured on a real 189k-line project.
    ///
    /// A wrong list with a plausible count is worse than a truncated one
    /// that says so, because nothing prompts anyone to look further.
    public static func issues(
        base: URL, token: String, projectKey: String, severities: [String] = []
    ) async throws -> Issues {
        struct Response: Decodable {
            struct Paging: Decodable { let total: Int }
            let issues: [Issue]
            let paging: Paging
        }
        var collected: [Issue] = []
        var total = 0
        // SonarQube refuses beyond 10,000 addressable results. Stopping
        // there and reporting the real total is honest; calling the first
        // page the whole is not.
        for page in 1...20 {
            let response = try await get(
                issuesURL(
                    base: base, projectKey: projectKey, severities: severities, page: page),
                token: token, as: Response.self)
            total = response.paging.total
            collected += response.issues
            if response.issues.isEmpty || collected.count >= total { break }
        }
        return Issues(issues: collected, total: total)
    }

    /// A gate verdict, and what it was actually judging.
    ///
    /// ⚠ `OK` with an empty condition list means **nothing was
    /// checked** — SonarQube's default gate scores *new* code, and a first
    /// analysis has no baseline to compare against. Oilbird reported that
    /// identically to a real pass, so `oilbird gate $KEY && deploy` would
    /// deploy anything, for ever, and never say why. Measured on a
    /// 111k-line project: `"conditions": []`, verdict `OK`.
    public struct GateResult: Sendable {
        public struct Condition: Sendable, Decodable {
            public let status: String
            public let metricKey: String
            public let comparator: String?
            public let errorThreshold: String?
            public let actualValue: String?

            public init(
                status: String, metricKey: String, comparator: String?,
                errorThreshold: String?, actualValue: String?
            ) {
                self.status = status
                self.metricKey = metricKey
                self.comparator = comparator
                self.errorThreshold = errorThreshold
                self.actualValue = actualValue
            }
        }
        public let gate: Gate
        public let conditions: [Condition]

        public init(gate: Gate, conditions: [Condition]) {
            self.gate = gate
            self.conditions = conditions
        }
        /// A pass that checked nothing is not a pass, and must not read
        /// like one.
        public var judgedNothing: Bool { conditions.isEmpty }
        /// How much source the last analysis read, filled in by the facade.
        ///
        /// ⚠ Not decoded — the gate endpoint does not know it, and that is
        /// exactly how `gate OK` came to be printed for projects nothing had
        /// ever read. `judgedNothing` only catches the FIRST analysis of
        /// such a project, because it keys off an empty condition list; from
        /// the second scan onward SonarQube supplies conditions, evaluates
        /// them against nothing, and passes them all. So
        /// `oilbird gate $KEY && deploy` deployed.
        public var linesAnalysed: Int?
        /// The analysis read no source. Distinct from `judgedNothing`: one
        /// means nothing was checked, this means there was nothing to check.
        public var readNothing: Bool { linesAnalysed == 0 }
        public var failed: [Condition] { conditions.filter { $0.status == "ERROR" } }
    }

    public static func qualityGate(base: URL, token: String, projectKey: String) async throws
        -> GateResult
    {
        let url = base.appending(path: "api/qualitygates/project_status")
            .appending(queryItems: [URLQueryItem(name: "projectKey", value: projectKey)])
        struct Status: Decodable {
            let status: String
            let conditions: [GateResult.Condition]?
        }
        struct Response: Decodable { let projectStatus: Status }
        let response = try await get(url, token: token, as: Response.self)
        return GateResult(
            gate: Gate(rawValue: response.projectStatus.status),
            conditions: response.projectStatus.conditions ?? [])
    }

    /// Does this project exist at all?
    ///
    /// ⚠ An unknown key is not an error to `api/issues/search` — it returns
    /// an empty list, so `oilbird issues definitely-not-a-project` printed
    /// `0 issue(s)` and exited 0. A typo was indistinguishable from a clean
    /// project, which in CI is a green build for something that was never
    /// analysed.
    ///
    /// Only asked when the result is empty, so the common case pays nothing.
    public static func projectExists(base: URL, token: String, projectKey: String) async
        -> Bool
    {
        let url = base.appending(path: "api/components/show")
            .appending(queryItems: [URLQueryItem(name: "component", value: projectKey)])
        struct Response: Decodable {
            struct Component: Decodable { let key: String }
            let component: Component
        }
        return (try? await get(url, token: token, as: Response.self)) != nil
    }

    /// The measures the server computed during the analysis.
    ///
    /// ⚠ Oilbird ran the analysis that produced every one of
    /// these and then called `api/measures/component` nowhere. On a real
    /// project that meant 23.3% duplication, 0% coverage on 179 test files,
    /// and 43 hours of debt were all computed, stored, and unreadable.
    /// How much source the last analysis actually read.
    ///
    /// ⚠ Its own call, and not folded into `measures`, because this is the
    /// question every other answer depends on. Oilbird never asked it, so
    /// "nothing was read" and "your code is clean" were the same output: a
    /// directory whose name begins with a dot is indexed and then skipped by
    /// every sensor, and `scan` printed success, `issues` printed 0, and
    /// `gate` printed OK with exit 0 — while a byte-identical copy one
    /// directory up reported a CRITICAL. The same green result came from an
    /// empty directory, a docs-only directory, a tests-only repository, and
    /// a project whose only file was over the scanner's 20 MB ceiling.
    ///
    /// Absent is distinct from zero and both are returned as zero: SonarQube
    /// omits the measure entirely for a component it has no lines for, which
    /// is precisely the case this exists to catch.
    public static func analysedSize(base: URL, token: String, projectKey: String) async
        -> (files: Int, lines: Int)
    {
        let found = await measures(
            base: base, token: token, projectKey: projectKey, keys: ["files", "ncloc"])
        return (Int(found["files"] ?? "") ?? 0, Int(found["ncloc"] ?? "") ?? 0)
    }

    /// Which taxonomy this server judges by.
    ///
    /// ⚠ **SonarQube has two, and Oilbird read the wrong one.** Community
    /// Build 26.9 runs Multi-Quality Rule mode out of the box, and the
    /// embedded dashboard in Oilbird's own window shows it — while the CLI
    /// asked for the legacy family and printed `reliability 34` beside a
    /// dashboard reading 111, for the same project, in the same app. Both
    /// numbers are the server's; they count different things.
    ///
    /// ⚠ Read from the server, never assumed and never SET. The mode is the
    /// server admin's to choose — Oilbird reports what SonarQube is doing rather
    /// than deciding what it ought to do — and it is a setting a person can
    /// change under Oilbird at any time.
    public enum Taxonomy: String, Sendable, Equatable {
        /// Impacts and software qualities: what 26.9 does unless told not to.
        case mqr = "MQR"
        /// Bugs, vulnerabilities, code smells, and the five severities.
        case standard = "STANDARD"

        /// The measure keys that count issues, in this taxonomy.
        public var issueKeys: [String] {
            switch self {
            case .mqr:
                [
                    "software_quality_security_issues", "software_quality_reliability_issues",
                    "software_quality_maintainability_issues",
                ]
            case .standard: ["vulnerabilities", "bugs", "code_smells"]
            }
        }

        /// The issue facet that answers "what do I fix first".
        public var severityFacet: String {
            self == .mqr ? "impactSeverities" : "severities"
        }

        /// The facet that splits issues by what they threaten.
        public var familyFacet: String {
            self == .mqr ? "impactSoftwareQualities" : "types"
        }

        /// Worst first, which is the order the answer is read in.
        public var severities: [String] {
            self == .mqr
                ? ["BLOCKER", "HIGH", "MEDIUM", "LOW", "INFO"]
                : ["BLOCKER", "CRITICAL", "MAJOR", "MINOR", "INFO"]
        }

        /// The parameter that answers a set of severities.
        ///
        /// ⚠ **`--severity HIGH` was refused by a build whose own `summary`
        /// screen had just printed `high 186`.** The two vocabularies live under
        /// two query parameters — `severities` takes CRITICAL, MAJOR, MINOR;
        /// `impactSeverities` takes HIGH, MEDIUM, LOW — and both answer on an MQR
        /// server. Routed by what was ASKED rather than by the mode, so every
        /// value that worked before still works and the ones the screen now
        /// offers work too.
        ///
        /// BLOCKER and INFO are in both, so a set of only those goes to the
        /// legacy parameter: it is the one that answers on either kind of
        /// server.
        public static func parameter(narrowingBy severities: [String]) -> String {
            let mqrOnly: Set<String> = ["HIGH", "MEDIUM", "LOW"]
            return severities.contains { mqrOnly.contains($0.uppercased()) }
                ? "impactSeverities" : "severities"
        }
    }

    /// ⚠ Defaults to `.standard` and not to `.mqr` when the server cannot be
    /// asked, because `.standard`'s keys exist on BOTH kinds of server and
    /// `.mqr`'s do not: `api/measures/component` fails the whole request over
    /// one unknown key, so guessing MQR at a standard server loses every
    /// measure rather than showing the wrong family.
    public static func taxonomy(base: URL, token: String) async -> Taxonomy {
        struct Response: Decodable { let mode: String }
        guard
            let response = try? await get(
                base.appending(path: "api/v2/clean-code-policy/mode"), token: token,
                as: Response.self)
        else { return .standard }
        return Taxonomy(rawValue: response.mode) ?? .standard
    }

    /// The measures every `summary` shows, in the taxonomy the server judges
    /// by.
    ///
    /// ⚠ The legacy keys are asked for under MQR TOO, and deliberately.
    /// `summary --json` publishes this map verbatim and agents read it, so
    /// this call may add keys and must not remove them — a consumer keyed on
    /// `bugs` keeps working, and gains `software_quality_reliability_issues`
    /// beside it.
    public static func summaryKeys(_ taxonomy: Taxonomy) -> [String] {
        [
            "ncloc", "coverage", "duplicated_lines_density", "cognitive_complexity",
            "sqale_index", "security_hotspots",
            // The ratings the dashboard leads with, and the CLI never asked
            // for: a project the window rates D showed no rating at all.
            "reliability_rating", "security_rating", "sqale_rating", "security_review_rating",
        ] + Taxonomy.standard.issueKeys + (taxonomy == .mqr ? Taxonomy.mqr.issueKeys : [])
    }

    public static func measures(
        base: URL, token: String, projectKey: String, keys: [String]? = nil
    ) async
        -> [String: String]
    {
        let keys = keys ?? summaryKeys(.standard)
        let url = base.appending(path: "api/measures/component")
            .appending(queryItems: [
                URLQueryItem(name: "component", value: projectKey),
                URLQueryItem(name: "metricKeys", value: keys.joined(separator: ",")),
            ])
        struct Measure: Decodable {
            let metric: String
            let value: String?
        }
        struct Component: Decodable { let measures: [Measure] }
        struct Response: Decodable { let component: Component }
        guard
            let response = try? await get(url, token: token, as: Response.self)
        else { return [:] }
        return Dictionary(
            response.component.measures.compactMap { m in m.value.map { (m.metric, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// What this project looked like at each past analysis.
    ///
    /// ⚠ The server keeps every analysis and every metric at each one —
    /// eighteen of them on a project scanned during one afternoon — and
    /// Oilbird could see none of it. So the question that matters most
    /// after a change, *"is this better than it was?"*, had no answer: an
    /// agent that fixed two issues could only count what was left and hope.
    ///
    /// Oldest first, so a reader and a diff both go forwards.
    public struct Snapshot: Sendable {
        public let date: String
        public let measures: [String: String]
    }

    public static func history(
        base: URL, token: String, projectKey: String,
        metrics: [String] = [
            "violations", "blocker_violations", "critical_violations", "coverage",
            "duplicated_lines_density", "ncloc",
        ]
    ) async -> [Snapshot] {
        struct Point: Decodable {
            let date: String
            let value: String?
        }
        struct Measure: Decodable {
            let metric: String
            let history: [Point]
        }
        struct Paging: Decodable { let total: Int }
        struct Response: Decodable {
            let measures: [Measure]
            let paging: Paging?
        }

        func page(_ index: Int) async -> Response? {
            let url = base.appending(path: "api/measures/search_history")
                .appending(queryItems: [
                    URLQueryItem(name: "component", value: projectKey),
                    URLQueryItem(name: "metrics", value: metrics.joined(separator: ",")),
                    // 1000 is the server's own ceiling; 1001 is refused by name.
                    URLQueryItem(name: "ps", value: String(pageSize)),
                    URLQueryItem(name: "p", value: String(index)),
                ])
            return try? await get(url, token: token, as: Response.self)
        }

        guard let first = await page(1) else { return [] }
        // ⚠ Page one is the OLDEST analyses, so without `p` a project past the
        // page size reports the beginning of its life as its history and
        // `changeSinceLast` diffs two ancient snapshots.
        var collected = [first]
        for index in pagesAfterTheFirst(total: first.paging?.total ?? 0) {
            if let more = await page(index) { collected.append(more) }
        }
        // The API returns one series per metric; a reader wants one row per
        // analysis, so transpose by date.
        var byDate: [String: [String: String]] = [:]
        for response in collected {
            for measure in response.measures {
                for point in measure.history {
                    guard let value = point.value else { continue }
                    byDate[point.date, default: [:]][measure.metric] = value
                }
            }
        }
        return byDate.keys.sorted().map { Snapshot(date: $0, measures: byDate[$0] ?? [:]) }
    }

    /// The server's own ceiling for `search_history`, which refuses 1001 by
    /// name. Named rather than written at the call site so the paging
    /// arithmetic below cannot drift from the number actually sent.
    public static let pageSize = 1000

    /// Which further pages to read, given what page one reported.
    ///
    /// ⚠ Separated from the request so it can be TESTED. The defect it fixes
    /// was pure arithmetic — a page number that was never sent — and it
    /// survived because the only way to see it was to have more analyses
    /// than the page size, which no test and no developer's machine had.
    ///
    /// The last page and the one before it. `history` draws a window from
    /// the end and `changeSinceLast` needs two ADJACENT points, so a last
    /// page holding a single analysis would otherwise have nothing to
    /// compare it against, and would read as "nothing changed".
    public static func pagesAfterTheFirst(total: Int, pageSize: Int = pageSize) -> [Int] {
        guard pageSize > 0, total > pageSize else { return [] }
        let last = (total + pageSize - 1) / pageSize
        return [last - 1, last].filter { $0 > 1 }
    }

    /// Counts by severity and type, in one request.
    ///
    /// ⚠ Without it a caller rebuilt exactly this from 152,638 bytes of
    /// JSON in Python, because the tool would only hand it a list. The
    /// server computes it: `facets` with `ps=1` returns the whole breakdown
    /// What a project's issues are, counted by the server rather than fetched.
    ///
    /// ⚠ A named type and not a tuple, because `severities` and `types` are
    /// both `[String: Int]` and a caller that swapped them would compile.
    public struct IssueFacets: Sendable, Equatable {
        /// How many issues at each severity word.
        public let severities: [String: Int]
        /// How many of each kind: bug, vulnerability, code smell, or the MQR
        /// software qualities, depending on which taxonomy was asked.
        public let types: [String: Int]
        /// Every issue, which is not the sum of either map: one issue carries
        /// a severity and a kind, so it is counted in both.
        public let total: Int

        public init(severities: [String: Int], types: [String: Int], total: Int) {
            self.severities = severities
            self.types = types
            self.total = total
        }
    }

    /// of 1,559 issues without transferring one of them.
    public static func issueFacets(base: URL, token: String, projectKey: String) async
        -> IssueFacets
    {
        await issueFacets(base: base, token: token, projectKey: projectKey, taxonomy: .standard)
    }

    /// The same, counted the way the server judges.
    ///
    /// ⚠ A separate function and not a defaulted parameter, for the reason
    /// `ensureRunning(onPhase:)` carries.
    ///
    /// ⚠ The whole point of taking a taxonomy: on an MQR server the legacy
    /// facets still ANSWER — `severities` returns CRITICAL 182, MAJOR 496 —
    /// so nothing failed and nothing looked wrong. The dashboard beside it
    /// read HIGH 186, MEDIUM 540. Two true answers to two different
    /// questions, and Oilbird was asking the one its own window does not.
    public static func issueFacets(
        base: URL, token: String, projectKey: String, taxonomy: Taxonomy
    ) async -> IssueFacets {
        let url = base.appending(path: "api/issues/search")
            .appending(queryItems: [
                URLQueryItem(name: "componentKeys", value: projectKey),
                URLQueryItem(name: "resolved", value: "false"),
                URLQueryItem(name: "ps", value: "1"),
                URLQueryItem(
                    name: "facets",
                    value: taxonomy.severityFacet + "," + taxonomy.familyFacet),
            ])
        struct Facet: Decodable {
            struct Value: Decodable {
                let val: String
                let count: Int
            }
            let property: String
            let values: [Value]
        }
        struct Response: Decodable {
            let total: Int
            let facets: [Facet]
        }
        guard
            let response = try? await get(url, token: token, as: Response.self)
        else { return IssueFacets(severities: [:], types: [:], total: 0) }
        func counts(_ property: String) -> [String: Int] {
            Dictionary(
                (response.facets.first { $0.property == property }?.values ?? [])
                    .map { ($0.val, $0.count) }, uniquingKeysWith: { first, _ in first })
        }
        return IssueFacets(
            severities: counts(taxonomy.severityFacet), types: counts(taxonomy.familyFacet),
            total: response.total)
    }

    public static func projects(base: URL, token: String) async throws -> [Project] {
        let url = base.appending(path: "api/projects/search")
            .appending(queryItems: [URLQueryItem(name: "ps", value: "500")])
        struct Response: Decodable { let components: [Project] }
        return try await get(url, token: token, as: Response.self).components
    }

    /// Waits for SonarQube to finish ingesting an analysis report.
    ///
    /// ⚠ A scan is two steps, and the scanner only does the first. It uploads
    /// a report and exits; SonarQube's compute engine ingests it a second or
    /// two later. Until this existed, `Scan.run` returned after step one, so
    /// the obvious loop — scan, then read the issues — read the results of
    /// the PREVIOUS analysis. Measured: the scanner returned at 10:14:52 and
    /// the compute engine finished at 10:14:55, and in between the caller
    /// was handed line numbers pointing at code it had already deleted.
    ///
    /// The race is silent and it loses by default, which is the worst
    /// combination: the answer is confident, well-formed and stale.
    public static func awaitAnalysis(
        base: URL, token: String, task: String, timeout: TimeInterval = 120
    ) async throws {
        struct Response: Decodable {
            struct Task: Decodable { let status: String }
            let task: Task
        }
        let url = base.appending(path: "api/ce/task")
            .appending(queryItems: [URLQueryItem(name: "id", value: task)])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = (try? await get(url, token: token, as: Response.self))?.task.status
            switch status {
            case "SUCCESS": return
            case "FAILED", "CANCELED":
                throw OilbirdError(
                    .verifyFailed, "The server could not process the analysis.",
                    recovery: .retry("Show log"), underlying: "ce task \(task) \(status ?? "")")
            default: break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw OilbirdError(
            .serverUnhealthy, "The server did not finish processing the analysis.",
            recovery: .retry("Try again"), underlying: "ce task \(task) still pending")
    }

    /// Turns off SonarQube's own banners and upsells, once, as the admin.
    ///
    /// Not restyling — Oilbird may tint, never restyle, and this is not it.
    /// These are notices SonarQube itself makes dismissible, with an x in
    /// the corner, and this presses that x once at setup instead of leaving
    /// the user to dismiss the same strip on every fresh profile. The
    /// server records the dismissal against the account; the markup is
    /// untouched.
    ///
    /// The list is the server's own vocabulary, and an unknown name is
    /// refused with the valid set, so a version that renames one fails
    /// loudly here rather than quietly leaving a banner.
    public static let dismissibleNotices = [
        // "The way in which security, reliability and maintainability
        // counts and ratings are calculated has changed."
        "showNewModesBanner",
        // "Get the most out of SonarQube Community Build!" — an
        // advertisement for a product this user has already chosen not to
        // use, inside an app they installed to avoid choosing.
        "sonarlintAd",
        "educationPrinciples",
        "showDesignAndArchitectureBanner",
        "overviewZeroNewIssuesSimplification",
    ]

    /// Returns the notices the server would not dismiss, so the caller can
    /// say so. SonarAPI never logs — it is argument-in, answer-out, which is
    /// what lets the whole of it be tested against a fixture server.
    @discardableResult
    public static func dismissNotices(base: URL, token: String) async -> [String] {
        var refused: [String] = []
        for notice in dismissibleNotices {
            var request = URLRequest(url: base.appending(path: "api/users/dismiss_notice"))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("notice=\(notice)".utf8)
            guard let (_, response) = try? await HTTP.session.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 204
            else {
                refused.append(notice)
                continue
            }
        }
        return refused
    }

    /// Signs in and returns the session cookies, without returning the
    /// password that produced them.
    ///
    /// This is what lets the app show a dashboard the user never logs into.
    /// SonarQube presents a login wall, and the credential behind it is
    /// generated by Oilbird, stored `0600` and deliberately never shown — so
    /// a user faced with that form has no key and no way to get one. The app
    /// gets a session instead: enough to render, never enough to leak.
    ///
    /// `Set-Cookie: JWT-SESSION` is `HttpOnly`, so page script cannot read
    /// it back out even though the view holds it.
    public static func login(base: URL, password: String) async -> [HTTPCookie] {
        var request = URLRequest(url: base.appending(path: "api/authentication/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            Provisioning.form(["login": "admin", "password": password]).utf8)
        guard let (_, response) = try? await HTTP.session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let fields = http.allHeaderFields as? [String: String]
        else { return [] }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: base)
    }

    /// Removes a project and everything analysed under it.
    ///
    /// Exists for one caller: the scanner's self-check really scans a fixture
    /// — that is what makes it a verification rather than a version flag —
    /// and a real scan is really uploaded, so the check leaves a project on
    /// the user's dashboard every time it runs. This is how it cleans up
    /// after itself.
    ///
    /// Returns whether it went; a self-check that cannot tidy up is not a
    /// failed self-check, and throwing here would turn a cosmetic leftover
    /// into a broken `doctor`.
    @discardableResult
    public static func deleteProject(base: URL, token: String, key: String) async -> Bool {
        var request = URLRequest(url: base.appending(path: "api/projects/delete"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("project=\(key)".utf8)
        guard let (_, response) = try? await HTTP.session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 204
    }

    /// Everything Oilbird can set about one project, as the server has it.
    public struct ProjectSettings: Sendable, Equatable {
        public var tags: [String]
        /// `PREVIOUS_VERSION`, `NUMBER_OF_DAYS`, `REFERENCE_BRANCH`…
        public var newCodeType: String?
        public var newCodeValue: String?
        /// Whether the new-code rule is this project's own or the instance
        /// default it happens to sit under. Different facts, and a settings
        /// screen that showed them the same way would be claiming a choice
        /// nobody made.
        public var newCodeInherited: Bool
        public var exclusions: [String]

        public init(
            tags: [String] = [], newCodeType: String? = nil, newCodeValue: String? = nil,
            newCodeInherited: Bool = true, exclusions: [String] = []
        ) {
            self.tags = tags
            self.newCodeType = newCodeType
            self.newCodeValue = newCodeValue
            self.newCodeInherited = newCodeInherited
            self.exclusions = exclusions
        }
    }

    /// What the server currently has for a project.
    public static func projectSettings(base: URL, token: String, key: String) async
        -> ProjectSettings
    {
        var settings = ProjectSettings()

        struct Search: Decodable {
            struct Component: Decodable { let tags: [String]? }
            let components: [Component]
        }
        let url = base.appending(path: "api/components/search_projects")
            .appending(queryItems: [URLQueryItem(name: "filter", value: "query=\(key)")])
        if let found = try? await get(url, token: token, as: Search.self) {
            settings.tags = found.components.first?.tags ?? []
        }

        // ⚠ `list`, not `show`. `set` without a branch lands the
        // rule on the MAIN BRANCH while `show?project=` reports the project
        // level, so a write that worked reads back as the inherited default.

        // `show` is still asked, for the case where nothing has been set and
        // what the project inherits is the only true answer.
        struct Periods: Decodable {
            struct Period: Decodable {
                let branchKey: String?
                let type: String?
                let value: String?
                let inherited: Bool?
            }
            let newCodePeriods: [Period]
        }
        let periodList = base.appending(path: "api/new_code_periods/list")
            .appending(queryItems: [URLQueryItem(name: "project", value: key)])
        if let periods = try? await get(periodList, token: token, as: Periods.self),
            let period = periods.newCodePeriods.first(where: { $0.branchKey == "main" })
                ?? periods.newCodePeriods.first
        {
            settings.newCodeType = period.type
            settings.newCodeValue = period.value
            settings.newCodeInherited = period.inherited ?? false
        } else {
            struct NewCode: Decodable {
                let type: String?
                let value: String?
                let inherited: Bool?
            }
            let periodShow = base.appending(path: "api/new_code_periods/show")
                .appending(queryItems: [URLQueryItem(name: "project", value: key)])
            if let period = try? await get(periodShow, token: token, as: NewCode.self) {
                settings.newCodeType = period.type
                settings.newCodeValue = period.value
                settings.newCodeInherited = period.inherited ?? true
            }
        }

        struct Values: Decodable {
            struct Setting: Decodable {
                let key: String
                let values: [String]?
                let value: String?
            }
            let settings: [Setting]
        }
        let settingsValues = base.appending(path: "api/settings/values")
            .appending(queryItems: [
                URLQueryItem(name: "component", value: key),
                URLQueryItem(name: "keys", value: "sonar.exclusions"),
            ])
        if let values = try? await get(settingsValues, token: token, as: Values.self),
            let exclusions = values.settings.first(where: { $0.key == "sonar.exclusions" })
        {
            settings.exclusions =
                exclusions.values ?? exclusions.value.map { [$0] } ?? []
        }
        return settings
    }

    /// What the main branch is called.
    ///
    /// ⚠ There is only ever one on Community Build — branch analysis is a
    /// commercial feature, and every scan lands on it — so `set_main` has
    /// nothing to choose between and is not offered. `rename` is real and
    /// useful: a repository whose default branch is `master` or `trunk`
    /// gets a dashboard insisting it is `main`.
    public static func mainBranch(base: URL, token: String, key: String) async -> String? {
        struct Branches: Decodable {
            struct Branch: Decodable {
                let name: String
                let isMain: Bool
            }
            let branches: [Branch]
        }
        let url = base.appending(path: "api/project_branches/list")
            .appending(queryItems: [URLQueryItem(name: "project", value: key)])
        guard let found = try? await get(url, token: token, as: Branches.self) else {
            return nil
        }
        return (found.branches.first { $0.isMain } ?? found.branches.first)?.name
    }

    public static func renameMainBranch(
        base: URL, token: String, key: String, to name: String
    ) async -> String? {
        await write(
            base: base, token: token, path: "api/project_branches/rename",
            form: [("project", key), ("name", name)])
    }

    /// A write, and the server's own words when it refuses.
    ///
    /// ⚠ Returns the refusal rather than a Bool. `deleteProject` answers
    /// true/false and that was enough for one endpoint with one failure
    /// mode; these have several, and SonarQube names the parameter and
    /// lists the legal values in the body. Throwing that away and printing
    /// "it did not work" is the defect this exists to refuse.
    static func write(
        base: URL, token: String, path: String, form: [(String, String)]
    ) async -> String? {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var encoded = CharacterSet.alphanumerics
        encoded.insert(charactersIn: "-._~")
        request.httpBody = Data(
            form.map { name, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: encoded) ?? value
                return "\(name)=\(escaped)"
            }.joined(separator: "&").utf8)
        guard let (body, response) = try? await HTTP.session.data(for: request) else {
            return "the server did not answer"
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            return said(in: body) ?? "the server refused it (HTTP \(code))"
        }
        return nil
    }

    public static func setTags(base: URL, token: String, key: String, tags: [String]) async
        -> String?
    {
        await write(
            base: base, token: token, path: "api/project_tags/set",
            form: [("project", key), ("tags", tags.joined(separator: ","))])
    }

    public static func setNewCode(
        base: URL, token: String, key: String, type: String, value: String?
    ) async -> String? {
        var form = [("project", key), ("type", type)]
        if let value, !value.isEmpty { form.append(("value", value)) }
        return await write(
            base: base, token: token, path: "api/new_code_periods/set", form: form)
    }

    public static func setExclusions(
        base: URL, token: String, key: String, patterns: [String]
    ) async -> String? {
        // ⚠ `values` repeated, never one comma-joined `value`: a pattern may
        // legally contain a comma, and joined into one `a,b` becomes a single
        // pattern matching neither.
        var form = [("key", "sonar.exclusions"), ("component", key)]
        form += patterns.map { ("values", $0) }
        return await write(base: base, token: token, path: "api/settings/set", form: form)
    }

    /// The token travels in a header, never a query string — a URL is logged,
    /// cached and shoulder-surfed in ways a header is not.
    /// SonarQube's own words for why it refused, or nil.
    ///
    /// The shape is `{"errors":[{"msg":"..."}]}` and it is worth far more
    /// than anything Oilbird could write in its place: it names the
    /// parameter and, for an enumerated one, lists the legal values.
    static func said(in body: Data) -> String? {
        struct Refusal: Decodable {
            struct Message: Decodable { let msg: String }
            let errors: [Message]
        }
        guard let refusal = try? JSONDecoder().decode(Refusal.self, from: body) else {
            return nil
        }
        let messages = refusal.errors.map(\.msg).filter { !$0.isEmpty }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    // MARK: the whole API

    /// The server's own description of every endpoint it has.
    public static func catalogue(base: URL, token: String) async throws -> APICatalogue {
        // `include_internals`, because an endpoint Oilbird cannot SEE is one
        // an agent cannot reach and several useful ones are marked internal.
        // Listed as unsupported rather than hidden, so it is not a dead end.
        let url = base.appending(path: "api/webservices/list")
            .appending(queryItems: [URLQueryItem(name: "include_internals", value: "true")])
        let listing = try await get(url, token: token, as: WebServicesListing.self)

        let endpoints = listing.webServices.flatMap { service in
            (service.actions ?? []).map { action in
                APICatalogue.Endpoint(
                    path: "\(service.path)/\(action.key)",
                    summary: firstSentence(action.description ?? ""),
                    post: action.post ?? false,
                    unsupported: action.isInternal ?? false,
                    since: action.since,
                    parameters: (action.params ?? []).map { param in
                        APICatalogue.Parameter(
                            key: param.key,
                            description: firstSentence(param.description ?? ""),
                            required: param.required ?? false,
                            possibleValues: param.possibleValues ?? [],
                            defaultValue: param.defaultValue,
                            example: param.exampleValue)
                    })
            }
        }
        .sorted { $0.path < $1.path }

        guard !endpoints.isEmpty else {
            throw OilbirdError(
                .serverUnhealthy, "The server described no endpoints at all.",
                recovery: .retry("Try again"),
                underlying: "webservices/list returned \(listing.webServices.count) services")
        }
        let descriptions = Dictionary(
            listing.webServices.map { ($0.path, firstSentence($0.description ?? "")) },
            uniquingKeysWith: { first, _ in first })
        return APICatalogue(endpoints: endpoints, descriptions: descriptions)
    }

    /// SonarQube's descriptions are HTML paragraphs. One sentence is a row.
    static func firstSentence(_ text: String) -> String {
        var plain = text.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression)
        plain = plain.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        plain = plain.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stop = plain.firstIndex(where: { $0 == "." || $0 == "\n" }) {
            let sentence = String(plain[plain.startIndex..<stop])
            // A sentence that stops after two words is an abbreviation, not
            // the end — "e.g. the project key" should not become "e".
            if sentence.split(separator: " ").count >= 4 { return sentence }
        }
        return plain.count > 160 ? String(plain.prefix(160)) + "…" : plain
    }

    /// Performs any endpoint in the catalogue, and returns what came back.
    ///
    /// ⚠ The method is taken from the catalogue rather than from the caller.
    /// SonarQube answers a POST endpoint reached by GET with a 405 whose body
    /// is an HTML error page, which decodes to nothing and reads as "the
    /// server did not answer" — a diagnosis that sends someone to look at a
    /// healthy engine. The server already said which it is.
    public static func perform(
        base: URL, token: String, endpoint: APICatalogue.Endpoint, parameters: [String: String]
    ) async throws -> String {
        var request: URLRequest
        if endpoint.post {
            request = URLRequest(url: base.appending(path: endpoint.path))
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(formEncoded(parameters).utf8)
        } else {
            let items = parameters.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            let url = base.appending(path: endpoint.path)
            request = URLRequest(url: items.isEmpty ? url : url.appending(queryItems: items))
        }
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await HTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            throw OilbirdError(
                .credentialRejected, "The server rejected Oilbird's access token.",
                recovery: .retry("Try again"), underlying: "HTTP \(code) for \(endpoint.path)")
        }
        guard (200..<300).contains(code) else {
            // The server's own words. It rejects an unknown key
            // with the valid set and an unknown severity with the legal ones,
            // which is worth more than a sentence written here.
            throw OilbirdError(
                .verifyFailed, said(in: data) ?? "The server refused that call.",
                recovery: .chooseAlternative("Check the parameters"),
                underlying: "HTTP \(code) for \(endpoint.path)")
        }
        // A 204 is the usual answer to a write, and it has no body.
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        return prettied(data) ?? text
    }

    /// Form-encodes a body.
    ///
    /// ⚠ Its own, rather than Provisioning's. `domains.yaml` gives SonarAPI
    /// `[Model, HTTP]` and nothing else — it takes a base URL and a token as
    /// arguments, which is what makes it testable against a fixture server,
    /// and reaching Provisioning for a string function would trade that for
    /// six lines.
    ///
    /// The allowed set is deliberately narrow: `+` is a space in a form body,
    /// and a rule description containing one would arrive with a hole in it.
    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map {
                let value = $0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\($0.key)=\(value)"
            }
            .joined(separator: "&")
    }

    /// Re-encoded with sorted keys and indentation, so a diff of two answers
    /// is a diff of the answers and not of the server's key ordering.
    static func prettied(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: pretty, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Whether the server still accepts this token.
    ///
    /// ⚠ `authentication/validate` answers `200 {"valid":false}` for a
    /// revoked token, a malformed one and no token at all — it never 401s,
    /// which is what makes it usable as a probe. Verified against 26.9:
    /// a bearer token that had been revoked returned `200 {"valid":false}`
    /// here while `api/projects/search` returned `401` with an empty body.
    ///
    /// A network failure answers `true`. This is a probe for "was it
    /// revoked", and a server that cannot be reached has not revoked
    /// anything; answering `false` would mint a fresh token on every
    /// blip and leave the real fault undiagnosed.
    public static func accepts(base: URL, token: String) async -> Bool {
        var request = URLRequest(url: base.appending(path: "api/authentication/validate"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await HTTP.session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return true }
        struct Validity: Decodable { let valid: Bool }
        return (try? JSONDecoder().decode(Validity.self, from: data))?.valid ?? true
    }

    static func get<T: Decodable>(_ url: URL, token: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // ⚠ A 404 is the server answering clearly, usually about a mistyped
            // key. "The server did not answer → Try again" blames the wrong
            // party, and retrying a typo produces the same typo.
            if code == 404 {
                throw OilbirdError(
                    .verifyFailed, "The server has nothing by that name.",
                    recovery: .chooseAlternative("List projects"),
                    underlying: "HTTP 404 for \(url.path)")
            }
            // ⚠ The server HAS answered, with the fix in the body: discarding
            // it sends a user to debug a healthy engine and an agent to retry
            // `critical` for `CRITICAL` for ever.

            // ⚠ Before the generic 4xx branch, which would claim the arguments
            // are wrong. A 401 means the token was revoked or the server was
            // reprovisioned, and the body is empty.
            if code == 401 || code == 403 {
                throw OilbirdError(
                    .credentialRejected, "The server rejected Oilbird's access token.",
                    recovery: .retry("Try again"), underlying: "HTTP \(code) for \(url.path)")
            }
            if (400..<500).contains(code) {
                throw OilbirdError(
                    .verifyFailed, said(in: data) ?? "The server refused that request.",
                    recovery: .chooseAlternative("Check the arguments"),
                    underlying: "HTTP \(code) for \(url.path)")
            }
            throw OilbirdError(
                .serverUnhealthy, "The server did not answer that request.",
                recovery: .retry("Try again"), underlying: "HTTP \(code) for \(url.path)")
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw OilbirdError(
                .serverUnhealthy, "The server's answer could not be read.",
                recovery: .reportIssue("Report an issue"),
                underlying: "undecodable \(T.self) from \(url.path)")
        }
        return decoded
    }
}

/// The database upgrade, which is the whole of what a version bump costs.
///
/// ⚠ Detect the state, `POST /api/system/migrate_db`, poll
/// `/api/system/db_migration_status`. `sonar.autoDatabaseUpgrade=false` is
/// only half of that; without the other half, the first new jar against an
/// older database would park every existing install in a loop it could not
/// leave: `awaitReady` throws on `DB_MIGRATION_NEEDED`, `Oilbird.up`'s catch
/// tears the engine down and rethrows, and the next `up` reaches exactly the
/// same state, for ever.
extension SonarAPI {
    /// The migration state machine's own vocabulary, verbatim.
    ///
    /// Deliberately not spelled `.none`: switched over a `MigrationState?`
    /// that would collide with the optional's own case, and the compiler
    /// points at neither.
    public enum MigrationState: String, Sendable {
        /// The schema already matches the jar — the normal answer on every
        /// start that is not an upgrade.
        case notNeeded = "NO_MIGRATION"
        /// This database cannot be migrated at all. SonarQube reports it for
        /// the embedded H2 it refuses in production, which is not a database
        /// Oilbird ever creates — so seeing it means something is wrong that
        /// waiting will not fix.
        case notSupported = "NOT_SUPPORTED"
        case required = "MIGRATION_REQUIRED"
        case running = "MIGRATION_RUNNING"
        case succeeded = "MIGRATION_SUCCEEDED"
        case failed = "MIGRATION_FAILED"
    }

    public struct Migration: Sendable, Decodable, Equatable {
        /// Carried as the raw string and read through `status`.
        ///
        /// A SonarQube that adds a state must not make this response
        /// undecodable: an unknown state has to reach the poller *as* an
        /// unknown state, where the deadline governs it, rather than as
        /// "the server's answer could not be read".
        public let state: String
        /// The server's own words. On a failure this is the only place the
        /// cause exists.
        public let message: String?
        public let startedAt: String?

        public var status: MigrationState? { MigrationState(rawValue: state) }

        public init(state: String, message: String? = nil, startedAt: String? = nil) {
            self.state = state
            self.message = message
            self.startedAt = startedAt
        }
    }

    /// Unauthenticated, like `/api/system/status`, and for the same reason:
    /// a server parked on a migration has no working session to offer.
    public static func migrationStatus(base: URL) async -> Migration? {
        var request = URLRequest(url: base.appending(path: "api/system/db_migration_status"))
        request.timeoutInterval = 10
        guard let (data, response) = try? await HTTP.session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(Migration.self, from: data)
    }

    /// Asks the server to upgrade its own schema, and returns what it said.
    public static func startMigration(base: URL) async -> Migration? {
        var request = URLRequest(url: base.appending(path: "api/system/migrate_db"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        guard let (data, response) = try? await HTTP.session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(Migration.self, from: data)
    }

    /// Drives one migration to a verdict, reporting every poll.
    ///
    /// The budget is thirty minutes rather than the readiness probe's three.
    /// A schema upgrade rewrites tables — ninety-seven migrations on a fresh
    /// install, and on an upgrade however much analysis history the user has
    /// accumulated — so *slow* and *stuck* are an hour apart here, and
    /// `onProgress` is the only thing that tells them apart.
    ///
    /// Every exit is a verdict. Nothing here returns quietly having done
    /// nothing, because that is the shape that produced the loop: the caller
    /// must be able to continue the start, or stop, and never to retry.
    public static func migrate(
        base: URL, timeout: TimeInterval = 1800,
        onProgress: @Sendable (Migration) -> Void = { _ in }
    ) async throws {
        guard let started = await startMigration(base: base) else {
            throw OilbirdError(
                .serverUnhealthy, "Oilbird could not start the database upgrade.",
                recovery: .chooseAlternative("Show log"),
                underlying: "POST api/system/migrate_db did not answer 200")
        }
        onProgress(started)
        try verdict(started)
        if started.status == .succeeded || started.status == .notNeeded { return }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let current = await migrationStatus(base: base) else { continue }
            onProgress(current)
            try verdict(current)
            if current.status == .succeeded || current.status == .notNeeded { return }
        }
        throw OilbirdError(
            .serverUnhealthy, "The database upgrade did not finish in time.",
            recovery: .retry("Show log"),
            underlying: "no terminal migration state within \(Int(timeout))s")
    }

    /// Throws on the states nothing further can happen from.
    ///
    /// ⚠ `MIGRATION_FAILED` is deliberately **not** `.retry`. The migration
    /// has already run once against this database and stopped part-way; a
    /// button that runs it again is the same loop wearing a friendlier
    /// label. SonarQube's own `message` names which migration failed, and
    /// that is the only thing anyone can act on — so the recovery points at
    /// the log that carries it.
    private static func verdict(_ migration: Migration) throws {
        switch migration.status {
        case .failed:
            throw OilbirdError(
                .serverUnhealthy, "The database upgrade failed part-way through.",
                recovery: .chooseAlternative("Show log"),
                underlying: "migrate_db: \(migration.message ?? "no message from the server")")
        case .notSupported:
            throw OilbirdError(
                .serverUnhealthy, "This database cannot be upgraded.",
                recovery: .reportIssue("Report an issue"),
                underlying: "migrate_db: NOT_SUPPORTED — \(migration.message ?? "")")
        default:
            return
        }
    }
}

/// `api/webservices/list`, in the shape the server sends it.
///
/// ⚠ At file scope rather than inside the function that decodes it. Four
/// levels of nested `Decodable` mirrors the JSON exactly, which is the clearest
/// way to write it and put `Param` a level deeper than anything can be named
/// or found. Out here the payload has a name, and `catalogue()` is forty lines
/// shorter.
private struct WebServicesListing: Decodable {
    struct Service: Decodable {
        struct Action: Decodable {
            let key: String
            let description: String?
            let post: Bool?
            let since: String?
            let isInternal: Bool?
            let params: [Param]?

            enum CodingKeys: String, CodingKey {
                case key, description, post, since, params
                // `internal` is a keyword, and the JSON spells it that way.
                case isInternal = "internal"
            }
        }

        /// One parameter of one endpoint.
        struct Param: Decodable {
            let key: String
            let description: String?
            let required: Bool?
            let possibleValues: [String]?
            let defaultValue: String?
            let exampleValue: String?
        }

        let path: String
        let description: String?
        let actions: [Action]?
    }

    let webServices: [Service]
}
