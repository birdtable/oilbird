import SwiftTUI

/// A list with no rules between its rows.
///
/// ⚠ `.plain` still draws a separator under every row, which doubles the
/// height of the list and is the same density regression `Table` had.
/// `.listRowSeparator(.hidden)` on the row does not reach it either: the
/// separator belongs to the list's presentation, not to the row, so the list
/// is where it has to be turned off.
public struct BareListStyle: ListStyle {
    public init() {}

    public var snapshotLabel: String { "oilbird.bare" }

    public func resolvePresentation(
        for configuration: ListStyleConfiguration
    ) -> ListStylePresentation {
        var presentation = ListStylePresentation.plain
        presentation.snapshotLabel = snapshotLabel
        presentation.showsRowSeparators = false
        return presentation
    }
}

extension ListStyle where Self == BareListStyle {
    public static var bare: BareListStyle { BareListStyle() }
}
