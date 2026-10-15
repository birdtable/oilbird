import SwiftTUI

/// The commands a screen is handing the reader, one per line.
///
/// ⚠ One per line because a wrapped command cannot be copied. Written as a
/// sentence — "the key is what every other verb takes: `oilbird summary
/// <key>`, `oilbird issues <key>`" — it reflowed at 76 columns into
/// `oilbird` / `issues <key>` across two lines, which reads fine and pastes
/// wrong. The old design system had the same shape for the same reason.
public struct Offers: View {
    public struct Offer: Sendable, Equatable {
        public let command: String
        public let what: String

        public init(command: String, what: String) {
            self.command = command
            self.what = what
        }
    }

    let offers: [Offer]

    public init(_ offers: [Offer]) {
        self.offers = offers
    }

    public var body: some View {
        AlignedTable(
            columns: [.init(heading: ""), .init(heading: "")],
            rows: offers.map {
                [
                    .init(text: $0.command, role: Role.typed),
                    .init(text: $0.what, role: Role.dim),
                ]
            },
            gap: 3)
    }
}
