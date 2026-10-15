import Foundation
import OilbirdCore
import OilbirdModel

/// Reading what a scan found: counts, ratings, history and the summary.
///
/// ⚠ An extension in its own file, not a separate type. `Oilbird` is
/// the one barrel a client imports and that is deliberate; what was not
/// deliberate is all of it living in one 1,877-line file. Splitting the
/// FILE changes nothing a caller can see.
extension Oilbird {
    /// "1 issue", "1,559 issues". One implementation, named here so the MCP
    /// target can reach it — `domains.yaml` lets that target see `Kit` only,
    /// and a machine surface printing `issue(s)` is the same unchecked
    /// plural the CLI stopped printing.
    public static func counted(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        UI.counted(n, singular, plural)
    }

    public static var mqrSeverities: [String] { SonarAPI.Taxonomy.mqr.severities }
    public static var standardSeverities: [String] { SonarAPI.Taxonomy.standard.severities }

    /// The worst N issues, worst first.
    ///
    /// ⚠ **A pure function BECAUSE the defect was pure ordering.** One MCP
    /// call returned 1,559 rows — 319,599 characters, about 80,000 tokens —
    /// in a single tool result, and the fix has two halves that are both
    /// invisible from outside: a bound, and a SORT before it. The server
    /// does not return severity order, so a plain `prefix` drops blockers
    /// and keeps whatever happened to be indexed first. Neither half can be
    /// checked against a machine with nothing scanned on it, which is every
    /// machine the suite runs on.
    ///
    /// `limit` of 0 means all of them: an agent that has asked for the whole
    /// list, knowing the size, gets the whole list.
    public static func worst(
        _ issues: [SonarAPI.Issue], taxonomy: SonarAPI.Taxonomy, limit: Int
    ) -> [SonarAPI.Issue] {
        let order = taxonomy.severities
        let ranked = issues.sorted {
            (order.firstIndex(of: $0.severity(in: taxonomy)) ?? order.count)
                < (order.firstIndex(of: $1.severity(in: taxonomy)) ?? order.count)
        }
        return limit <= 0 ? ranked : Array(ranked.prefix(limit))
    }

    /// How many analyses a surface draws before it has to say it is drawing
    /// a window.
    ///
    /// ⚠ One constant for both surfaces. Written separately they were both
    /// eight and both silent, and the day one of them changed they would
    /// have disagreed about what an agent and a person were each looking at.
    public static let historyWindow = 8

    /// How this project has changed, analysis by analysis.
    public static func history(projectKey: String) async throws -> [SonarAPI.Snapshot] {
        let attachment = Idle.Attachment(reason: "history")
        defer { withExtendedLifetime(attachment) {} }
        let (running, token) = try await connected()
        let snapshots = await SonarAPI.history(
            base: base(running.webPort), token: token, projectKey: projectKey)
        // Empty is ambiguous — never scanned, or never existed — and only
        // then is it worth a second call to find out which. The same trap
        // `issues` had: a typo reading as "nothing to report".
        if snapshots.isEmpty,
            await !SonarAPI.projectExists(
                base: base(running.webPort), token: token, projectKey: projectKey)
        {
            throw OilbirdError(
                .verifyFailed, "There is no project called '\(projectKey)'.",
                recovery: .chooseAlternative("List projects"),
                underlying: "api/components/show found no \(projectKey)")
        }
        return snapshots
    }

    /// What changed since the analysis before this one.
    ///
    /// The whole point of scanning twice. An agent that fixes something and
    /// re-scans wants one number — did it get better — and until now had to
    /// count the remaining issues and infer.
    public struct Change: Sendable {
        public let metric: String
        public let before: Double
        public let after: Double

        public init(metric: String, before: Double, after: Double) {
            self.metric = metric
            self.before = before
            self.after = after
        }
        public var delta: Double { after - before }

        /// Counts read as counts. "violations 3.0 → 1.0 (-2.0)" is three
        /// decimal points nobody asked for on a number that cannot have
        /// them; percentages keep one.
        public static func show(_ value: Double) -> String {
            value == value.rounded()
                ? String(Int(value)) : String(format: "%.1f", value)
        }

        public var summary: String {
            let sign = delta > 0 ? "+" : ""
            return "\(metric) \(Self.show(before)) → \(Self.show(after)) "
                + "(\(sign)\(Self.show(delta)))"
        }
    }

    public static func changeSinceLast(projectKey: String) async throws -> [Change] {
        let snapshots = try await history(projectKey: projectKey)
        guard snapshots.count >= 2 else { return [] }
        let before = snapshots[snapshots.count - 2].measures
        let after = snapshots[snapshots.count - 1].measures
        return after.keys.sorted().compactMap { metric in
            guard let a = Double(after[metric] ?? ""), let b = Double(before[metric] ?? ""),
                a != b
            else { return nil }
            return Change(metric: metric, before: b, after: a)
        }
    }

    /// SonarQube's letter rating, from the number it reports it as.
    ///
    /// ⚠ Here rather than in the screen, because BOTH surfaces show it and a
    /// conversion written twice is a conversion that will disagree once. Nil
    /// for absent: a project nothing has rated and a project rated `A` are
    /// not the same thing.
    public static func ratingLetter(_ value: String?) -> String? {
        guard let value, let number = Double(value), (1...5).contains(Int(number)) else {
            return nil
        }
        return String(UnicodeScalar(UInt8(64 + Int(number))))
    }

    public static func summary(projectKey: String) async throws -> Summary {
        let attachment = Idle.Attachment(reason: "summary")
        defer { withExtendedLifetime(attachment) {} }
        let (running, token) = try await connected()
        let host = base(running.webPort)
        var gate = try await SonarAPI.qualityGate(
            base: host, token: token, projectKey: projectKey)
        // ⚠ Filled HERE too, and it was not. `linesAnalysed` is optional and
        // `readNothing` is `== 0`, so an unfilled field answers "code was
        // read" for a project nothing read — gate OK, A ratings, 0 issues.
        gate.linesAnalysed = await SonarAPI.analysedSize(
            base: host, token: token, projectKey: projectKey
        ).lines
        // ⚠ Asked ONCE, here, and carried through every call below it. A screen
        // that fetched the mode itself would be a second round trip per surface and
        // a second chance to disagree with the numbers printed beside it.
        let judging = await SonarAPI.taxonomy(base: host, token: token)
        let measures = await SonarAPI.measures(
            base: host, token: token, projectKey: projectKey,
            keys: SonarAPI.summaryKeys(judging))
        let facets = await SonarAPI.issueFacets(
            base: host, token: token, projectKey: projectKey, taxonomy: judging)
        return Summary(
            project: projectKey, gate: gate, measures: measures,
            severities: facets.severities, types: facets.types, total: facets.total,
            taxonomy: judging)
    }
}
