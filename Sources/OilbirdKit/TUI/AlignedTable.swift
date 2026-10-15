import SwiftTUI

/// Columns that line up, with no rules and no blank lines between rows.
///
/// ⚠ Not `Table`. `Table` puts a rule row between EVERY row, and blanking the
/// glyph set leaves the row behind as whitespace — a three-row table renders
/// across seven lines. Oilbird's tables have always been dense, and six lines
/// of air in a summary is not a port, it is a regression.
///
/// So the alignment is done here: measure each column, pin every cell to that
/// width. This is the pattern the framework's own markdown reader uses for the
/// same reason, and `Table` stays the right answer wherever its chrome is
/// wanted.
///
/// For a large, scrollable, selectable collection use `List` with these rows
/// inside it instead — `List` virtualises, and this does not.
public struct AlignedTable: View {
    public struct Column: Sendable, Equatable {
        public let heading: String
        public let trailing: Bool
        /// Whether this column gives up width when the row will not fit.
        ///
        /// A project key, a version and a verdict are all the answer the
        /// reader came for, and half of one is worse than none. A detail
        /// column is prose about the answer and shortens without lying.
        public let elastic: Bool

        public init(heading: String, trailing: Bool = false, elastic: Bool = false) {
            self.heading = heading
            self.trailing = trailing
            self.elastic = elastic
        }
    }

    public struct Cell: Sendable, Equatable {
        public let text: String
        public let role: Int

        public init(text: String, role: Int = 0) {
            self.text = text
            self.role = role
        }
    }

    let columns: [Column]
    let rows: [[Cell]]
    let gap: Int

    public init(columns: [Column], rows: [[Cell]], gap: Int = 2) {
        self.columns = columns
        self.rows = rows
        self.gap = gap
    }

    /// The width each column needs: its heading, or its widest cell.
    ///
    /// ⚠ Measured in CHARACTERS, which is right here and would not be for
    /// every input. A terminal cell holds one column of a monospace grid, and
    /// a wide glyph occupies two — project keys and metric names are ASCII, so
    /// this holds, and a screen that takes arbitrary user text would need the
    /// display width instead.
    nonisolated public static func widths(
        columns: [Column], rows: [[Cell]]
    ) -> [Int] {
        columns.enumerated().map { index, column in
            let cells = rows.compactMap { $0.indices.contains(index) ? $0[index].text.count : nil }
            return max(column.heading.count, cells.max() ?? 0)
        }
    }

    /// The widths, shrunk to fit `available` cells if they do not already.
    ///
    /// ⚠ Content-sized columns overflow at ANY width, because a project key is
    /// a directory name and a hash and can be as long as the directory was.
    /// `oilbird scans` drew a 61-cell row into a 60-column terminal the moment
    /// a key reached sixteen characters, having passed every earlier run on
    /// the shorter keys that happened to be there. A budget is the fix; a
    /// wider floor would only move the failure.
    ///
    /// Only elastic columns give width up, smallest surplus first, and none
    /// goes below `floor`. If that is not enough the row still overflows, and
    /// it does so having shortened everything it was allowed to.
    nonisolated public static func widths(
        columns: [Column], rows: [[Cell]], gap: Int, available: Int?
    ) -> [Int] {
        var widths = self.widths(columns: columns, rows: rows)
        guard let available, available > 0 else { return widths }
        let floor = 6
        var over = widths.reduce(0, +) + gap * max(0, columns.count - 1) - available
        guard over > 0 else { return widths }
        let elastic = columns.indices.filter { columns[$0].elastic }
            .sorted { widths[$0] > widths[$1] }
        for index in elastic where over > 0 {
            let give = min(over, max(0, widths[index] - floor))
            widths[index] -= give
            over -= give
        }
        guard over > 0 else { return widths }

        // ⚠ Still over: the widest column gives up width even though it was
        // not offered. A key cut to the terminal is worth more than a key
        // plus 180 cells of padding and no other column.
        while over > 0 {
            guard let widest = widths.indices.max(by: { widths[$0] < widths[$1] }),
                widths[widest] > floor
            else { break }
            let give = min(over, widths[widest] - floor)
            widths[widest] -= give
            over -= give
        }
        return widths
    }

    /// One cell, cut to its column with an ellipsis where anything was cut.
    nonisolated static func fitted(_ text: String, to width: Int) -> String {
        guard text.count > width, width > 0 else { return text }
        return String(text.prefix(width - 1)) + "…"
    }

    var measured: [Int] {
        Self.widths(
            columns: columns, rows: rows, gap: gap,
            available: terminal.width > 0 ? terminal.width - surround : nil)
    }

    /// What the screens spend on their own margin, which this cannot see from
    /// inside. `Frames` pads every screen by two cells on each side.
    private let surround = 4

    @Environment(\.terminalSize) private var terminal

    public var body: some View {
        let widths = measured
        VStack(alignment: .leading, spacing: 0) {
            // ⚠ No header row when there are no headings. `Offers` is this table
            // with both columns unnamed, and an always-drawn header put a blank
            // line above every command list that means nothing.
            if columns.contains(where: { !$0.heading.isEmpty }) {
                HStack(spacing: gap) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        Text(Self.fitted(column.heading, to: widths[index]))
                            .foregroundStyle(Role.note)
                            .frame(
                                width: widths[index],
                                alignment: column.trailing ? .trailing : .leading)
                    }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        Text(Self.fitted(cell.text, to: widths[index]))
                            .foregroundStyle(Role.of(cell.role))
                            .frame(
                                width: widths[index],
                                alignment: columns[index].trailing ? .trailing : .leading)
                    }
                }
            }
        }
    }
}

extension Role {
    /// ⚠ An `Int`, not the style itself, because `AnyShapeStyle` is not
    /// `Equatable` and a cell that cannot compare cannot be diffed or asserted
    /// on. The screens name a role; this maps it back.
    nonisolated public static func of(_ role: Int) -> AnyShapeStyle {
        switch role {
        case 1: note
        case 2: attn
        case 3: good
        case 4: bad
        case 5: action
        default: body
        }
    }

    nonisolated public static let plain = 0
    nonisolated public static let dim = 1
    nonisolated public static let warn = 2
    nonisolated public static let ok = 3
    nonisolated public static let fail = 4
    nonisolated public static let typed = 5
}
