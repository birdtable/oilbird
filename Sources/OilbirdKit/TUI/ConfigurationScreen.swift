import SwiftTUI

/// What a project is set to, and how to change it.
public struct ConfigurationScreen: View {
    public struct Setting: Sendable, Equatable {
        public let label: String
        public let value: String
        /// Dim when it is a default rather than a choice someone made.
        public let chosen: Bool

        public init(label: String, value: String, chosen: Bool) {
            self.label = label
            self.value = value
            self.chosen = chosen
        }
    }

    let project: String
    let settings: [Setting]
    let offers: [Offers.Offer]

    public init(project: String, settings: [Setting], offers: [Offers.Offer]) {
        self.project = project
        self.settings = settings
        self.offers = offers
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(project).bold()
            Text("")
            // ⚠ A default is drawn dim and a choice is not. Equal weight made
            // "nothing has been set here" and "somebody set this deliberately" look
            // identical, which is the question this screen answers.
            AlignedTable(
                columns: [.init(heading: ""), .init(heading: "")],
                rows: settings.map {
                    [
                        .init(text: $0.label, role: Role.dim),
                        .init(text: $0.value, role: $0.chosen ? Role.plain : Role.dim),
                    ]
                })
            if !offers.isEmpty {
                Text("")
                Text("Set any of them:").foregroundStyle(Role.note)
                Offers(offers)
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}
