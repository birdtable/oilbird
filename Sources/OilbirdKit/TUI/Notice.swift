import SwiftTUI

/// A word, what it is about, and what to do next.
///
/// ⚠ One type for most of what is left, rather than a screen each. Half the
/// verbs answer with the same shape — `removed  web-app-deaa`, `none  nothing
/// has been scanned`, `45  stops after 45 minutes unused` — and a type per
/// verb would be eleven near-identical files that drift apart one comma at a
/// time.
///
/// The offers are not decoration. No dead ends: a screen names the way on, and
/// these are the screens with the least room to bury it.
public struct Notice: View {
    /// The word that carries the verdict, in the case that carries it too.
    public let mark: String?
    public let markRole: Int
    /// What the word is about, beside it.
    public let subject: String?
    /// Prose, wrapped by the runtime rather than split by hand.
    public let lines: [String]
    public let offers: [Offers.Offer]

    public init(
        mark: String? = nil, markRole: Int = Role.plain, subject: String? = nil,
        lines: [String] = [], offers: [Offers.Offer] = []
    ) {
        self.mark = mark
        self.markRole = markRole
        self.subject = subject
        self.lines = lines
        self.offers = offers
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mark != nil || subject != nil {
                HStack(spacing: 3) {
                    if let mark {
                        Text(mark).foregroundStyle(Role.of(markRole))
                    }
                    if let subject {
                        Text(subject).foregroundStyle(Role.note)
                    }
                }
            }
            if !lines.isEmpty {
                Text("")
                ForEach(lines, id: \.self) { line in
                    Text(line)
                }
            }
            if !offers.isEmpty {
                Text("")
                Offers(offers)
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}
