import SwiftTUI
import SwiftTUICharts

/// One quality gate condition, drawn against the threshold it is judged by.
///
/// A condition is a metric, a comparator, a threshold and the value the last
/// analysis measured. That is a gauge with a band on it, and it reads as one:
/// where the bar sits relative to the band is the verdict, before any word is
/// read.
///
/// ⚠ A gauge is only drawn where a real scale exists. Coverage runs 0 to 100
/// and a bar over it means something; "new issues, threshold 0, actual 3" has
/// no denominator, and inventing one — twice the threshold, say — draws a bar
/// whose fullness is arithmetic rather than fact. Those stay an aligned row.
public struct GateConditionRow: View {
    public struct Condition: Sendable, Equatable {
        public let metric: String
        public let comparator: String?
        public let threshold: String?
        public let actual: String?
        public let failed: Bool

        public init(
            metric: String, comparator: String?, threshold: String?, actual: String?,
            failed: Bool
        ) {
            self.metric = metric
            self.comparator = comparator
            self.threshold = threshold
            self.actual = actual
            self.failed = failed
        }

        /// The denominator this metric is measured against, or nil when it
        /// has none.
        ///
        /// ⚠ A property of the CONDITION, not of the row that draws it. It is
        /// a fact about the metric — coverage is out of a hundred, a count of
        /// violations is out of nothing — and filing it on the view made it
        /// reachable only by building one.
        public var scale: Double? {
            GateConditionRow.percentages.contains(metric) ? 100 : nil
        }
    }

    let condition: Condition

    public init(condition: Condition) {
        self.condition = condition
    }

    /// Metrics SonarQube reports as a percentage of a hundred.
    ///
    /// Named rather than guessed from the value: `new_violations` of 85 is
    /// eighty-five issues, not eighty-five percent, and a bar drawn as though
    /// it were would be a confident lie.
    /// ⚠ `nonisolated`, and so is every helper below. A `View` is
    /// `@MainActor` and its members inherit that, but none of these touch the
    /// view graph: they map a condition to a scale, a band or a sentence,
    /// which is arithmetic. Leaving them isolated makes them unreachable from
    /// a plain test and says something untrue about them.
    ///
    /// Public for the same reason every screen type here is: the suite imports
    /// this the way a client does, with no `@testable` anywhere.
    nonisolated public static let percentages: Set<String> = [
        "coverage", "new_coverage", "line_coverage", "new_line_coverage",
        "branch_coverage", "new_branch_coverage",
        "duplicated_lines_density", "new_duplicated_lines_density",
        "security_hotspots_reviewed", "new_security_hotspots_reviewed",
    ]

    public var body: some View {
        if let total = condition.scale, let actual = Double(condition.actual ?? ""),
            let threshold = Double(condition.threshold ?? "")
        {
            ThresholdGauge(
                Self.readable(condition.metric),
                value: actual,
                total: total,
                bands: Self.bands(
                    threshold: threshold, total: total,
                    comparator: condition.comparator))
        } else {
            LabeledContent(
                Self.readable(condition.metric),
                value: Self.verdict(condition)
            )
            .foregroundStyle(condition.failed ? Role.bad : Role.note)
        }
    }

    /// The band the gauge changes tone across.
    ///
    /// `LT` means the gate fails BELOW the threshold — coverage under 80 is
    /// the failure — so the critical band is the bottom of the scale. `GT`
    /// fails above it, and duplication over 3 is the failure. Getting this
    /// backwards paints a passing project red, so it is read off the
    /// comparator the server sent rather than assumed.
    nonisolated public static func bands(threshold: Double, total: Double, comparator: String?)
        -> [ThresholdBand]
    {
        switch comparator {
        case "LT":
            [.init(upTo: threshold, tone: .critical), .init(upTo: total, tone: .success)]
        default:
            [.init(upTo: threshold, tone: .success), .init(upTo: total, tone: .critical)]
        }
    }

    nonisolated public static func verdict(_ condition: Condition) -> String {
        let actual = condition.actual ?? "—"
        guard let threshold = condition.threshold else { return actual }
        let comparator = condition.comparator == "LT" ? "must be at least" : "must not exceed"
        return "\(actual)   \(comparator) \(threshold)"
    }

    /// `new_duplicated_lines_density` is not a thing anyone says out loud.
    nonisolated public static func readable(_ metric: String) -> String {
        let words = metric.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
