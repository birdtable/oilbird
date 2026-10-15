import SwiftTUI

/// What the last analysis of one project says.
public struct SummaryScreen: View {
    /// A left-hand row: an issue family, how it rates, how many it has.
    public struct Family: Sendable, Equatable {
        public let label: String
        public let rating: String
        public let count: String

        public init(label: String, rating: String, count: String) {
            self.label = label
            self.rating = rating
            self.count = count
        }
    }

    /// A right-hand row: something the analysis measured.
    public struct Measure: Sendable, Equatable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Model: Sendable, Equatable {
        public let project: String
        /// How much code the last analysis read, already worded.
        public let size: String?
        /// The gate's own word, whatever it was.
        public let verdict: String
        public let verdictIsFailure: Bool
        /// Nothing was measured, so the verdict means nothing either.
        public let judgedNothing: Bool
        /// Nothing was READ. A different fact with different advice: scanning
        /// again gives `judgedNothing` a baseline, and gives this nothing.
        public let readNothing: Bool
        public let conditions: [GateConditionRow.Condition]
        public let failedCount: Int
        public let families: [Family]
        public let measures: [Measure]

        public init(
            project: String, size: String?, verdict: String, verdictIsFailure: Bool,
            judgedNothing: Bool, readNothing: Bool = false,
            conditions: [GateConditionRow.Condition], failedCount: Int,
            families: [Family], measures: [Measure]
        ) {
            self.readNothing = readNothing
            self.project = project
            self.size = size
            self.verdict = verdict
            self.verdictIsFailure = verdictIsFailure
            self.judgedNothing = judgedNothing
            self.conditions = conditions
            self.failedCount = failedCount
            self.families = families
            self.measures = measures
        }
    }

    let model: Model

    public init(model: Model) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Text(model.project).bold()
                if let size = model.size {
                    Text(size).foregroundStyle(Role.note)
                }
            }

            // ⚠ The honest verdict before the pretty one: a gate that evaluated
            // no conditions is not a pass, and "OK" over an analysis that read
            // nothing is what lets `gate && deploy` deploy.
            if model.readNothing {
                // ⚠ Before `judgedNothing`, and worded differently on purpose.
                // "no baseline yet" invites another scan, which is the right
                // advice for one of these and useless for the other.
                Text("\(model.verdict) — NO CODE WAS READ, so this describes nothing")
                    .foregroundStyle(Role.attn)
            } else if model.judgedNothing {
                Text("\(model.verdict) — nothing was checked, no baseline yet")
                    .foregroundStyle(Role.attn)
            } else {
                HStack(spacing: 3) {
                    Text(model.verdict)
                        .foregroundStyle(model.verdictIsFailure ? Role.bad : Role.good)
                    Text(
                        "\(model.failedCount) of "
                            + "\(model.conditions.count) condition"
                            + (model.conditions.count == 1 ? "" : "s")
                    )
                    .foregroundStyle(Role.note)
                }
            }

            ForEach(model.conditions, id: \.metric) { condition in
                GateConditionRow(condition: condition)
            }

            // ⚠ Two halves, because counts and percentages read differently.
            // The column set is the one the SERVER judges by: getting it wrong
            // prints `reliability 34` beside a dashboard reading 111.
            if !model.families.isEmpty || !model.measures.isEmpty {
                AlignedTable(
                    columns: [
                        .init(heading: ""), .init(heading: "rating"),
                        .init(heading: "issues", trailing: true),
                        .init(heading: ""), .init(heading: "measure"),
                        .init(heading: "", trailing: true),
                    ],
                    rows: Self.halves(model.families, model.measures))
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }

    /// The two halves, zipped into rows.
    ///
    /// ⚠ Padded to the longer side rather than the shorter one. Zipping would
    /// silently drop whichever half has more rows, and the halves are not the
    /// same length: four measures sit beside three families and a hotspot
    /// line.
    nonisolated public static func halves(
        _ families: [Family], _ measures: [Measure]
    ) -> [[AlignedTable.Cell]] {
        (0..<max(families.count, measures.count)).map { index in
            let family = index < families.count ? families[index] : nil
            let measure = index < measures.count ? measures[index] : nil
            return [
                .init(text: family?.label ?? "", role: Role.dim),
                .init(text: family?.rating ?? "", role: Role.plain),
                .init(text: family?.count ?? "", role: Role.plain),
                .init(text: "", role: Role.plain),
                .init(text: measure?.label ?? "", role: Role.dim),
                .init(text: measure?.value ?? "", role: Role.plain),
            ]
        }
    }
}
