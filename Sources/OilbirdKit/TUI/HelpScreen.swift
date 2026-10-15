import SwiftTUI

/// Every verb, grouped by what it costs to run.
public struct HelpScreen: View {
    public struct Section: Sendable, Equatable {
        public let title: String
        public let verbs: [Offers.Offer]

        public init(title: String, verbs: [Offers.Offer]) {
            self.title = title
            self.verbs = verbs
        }
    }

    let build: String
    let sections: [Section]

    public init(build: String, sections: [Section]) {
        self.build = build
        self.sections = sections
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ⚠ `oilbird — a local SonarQube…` on ONE line: `CLIContractTests`
            // greps for that phrase to prove `--help` printed usage rather
            // than running the verb beside it.
            Text(
                """
                \(Text("oilbird").bold()) \
                \(Text("— a local SonarQube, with nothing to install first")
                    .foregroundStyle(Role.note))
                """
            )
            Text("")
            Text("USAGE").foregroundStyle(Role.note)
            Offers([
                .init(command: "oilbird <command>", what: "[--json] [--severity LEVEL]")
            ])
            Text("")
            ForEach(sections, id: \.title) { section in
                Text(section.title).foregroundStyle(Role.note)
                Offers(section.verbs)
                Text("")
            }
            // ⚠ Named by section rather than counted. This read "the first six need
            // an engine" over a section of seven: a count in prose goes stale the
            // next time a verb is added, and nobody re-counts.
            Text(
                "Everything under LOOK AT CODE starts an engine if one is not running, which "
                    + "costs about 15 seconds and 1.6 GB. Nothing under LOOK AT OILBIRD ever does."
            )
            .foregroundStyle(Role.note)
            Text("")
            Text(
                "--json on any verb for machine-readable output. --severity BLOCKER "
                    + "(repeatable) narrows issues; --browse opens it as a screen you can move "
                    + "around, which needs a terminal."
            )
            .foregroundStyle(Role.note)
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}
