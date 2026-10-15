import SwiftTUI
import SwiftTUICharts

/// How a project changed, analysis by analysis.
public struct HistoryScreen: View {
    public struct Point: Sendable, Equatable {
        public let analysed: String
        public let issues: String
        public let coverage: String
        /// The issue count as a number, when it is one.
        public let issueCount: Double?

        public init(analysed: String, issues: String, coverage: String, issueCount: Double?) {
            self.analysed = analysed
            self.issues = issues
            self.coverage = coverage
            self.issueCount = issueCount
        }
    }

    let project: String
    let points: [Point]
    /// How many analyses exist, which may be more than are shown.
    let total: Int
    let changes: [String]

    public init(project: String, points: [Point], total: Int, changes: [String]) {
        self.project = project
        self.points = points
        self.total = total
        self.changes = changes
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ⚠ The trend FIRST, because it is the question `history` exists
            // for, and a column of numbers makes the reader compute it. The
            // table stays underneath to answer "by how much".
            if let line = Self.trend(points) {
                Sparkline("issues", values: line, tone: Self.tone(line))
            }

            AlignedTable(
                columns: [
                    .init(heading: "analysed"),
                    .init(heading: "issues", trailing: true),
                    .init(heading: "coverage", trailing: true),
                ],
                rows: points.map {
                    [
                        .init(text: $0.analysed, role: Role.dim),
                        .init(text: $0.issues),
                        .init(text: $0.coverage),
                    ]
                })

            // ⚠ Says it is a WINDOW whenever it is one: 21 analyses shown as a
            // window reading 0 → 1, with a hidden earliest of 2, makes the
            // visible trend say "worse" where the truth is "better".
            if points.count < total {
                Text(
                    "showing the last \(points.count) of \(total) analyses; "
                        + "oilbird history \(project) --json has them all."
                )
                .foregroundStyle(Role.note)
            }

            Text("")
            if total < 2 {
                // ⚠ There IS no analysis before this one, and saying nothing
                // changed reads as "stable" for a project measured once.
                Text("This is the only analysis, so there is nothing to compare it with.")
                    .foregroundStyle(Role.note)
            } else if changes.isEmpty {
                Text("Nothing changed since the analysis before this one.")
                    .foregroundStyle(Role.note)
            } else {
                Text("since the last analysis").bold()
                ForEach(changes, id: \.self) { change in
                    Text(change).foregroundStyle(Role.note)
                }
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }

    /// The issue counts, when there are enough of them to be a line.
    ///
    /// ⚠ Nil for fewer than two points. A sparkline of one value is a dot
    /// that reads as a trend, and a project scanned once has no trend to
    /// show.
    nonisolated public static func trend(_ points: [Point]) -> [Double]? {
        let counts = points.compactMap(\.issueCount)
        guard counts.count == points.count, counts.count >= 2 else { return nil }
        return counts
    }

    /// ⚠ Fewer issues than we started with is good news, and the line should
    /// say so before the numbers are read. Compared end to end rather than
    /// against the last step: one noisy analysis in the middle is not the
    /// story.
    nonisolated public static func tone(_ values: [Double]) -> BannerTone {
        guard let first = values.first, let last = values.last else { return .info }
        if last < first { return .success }
        if last > first { return .warning }
        return .info
    }
}
