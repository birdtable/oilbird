import SwiftTUI

/// Everything scanned so far.
///
/// The first screen ported, and the shape every other one follows: a value
/// type over already-fetched data, no I/O, no engine. That is what makes it
/// renderable to a string in a test with no terminal and no server.
public struct ProjectsScreen: View {
    public struct Project: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    let projects: [Project]

    public init(projects: [Project]) {
        self.projects = projects
    }

    public var body: some View {
        if projects.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 1) {
                    Text("none").foregroundStyle(Role.attn)
                    Text("nothing has been scanned on this machine yet.")
                        .foregroundStyle(Role.body)
                }
                Text("oilbird scan <path>").foregroundStyle(Role.action)
            }
            .padding(.init(horizontal: 2, vertical: 0))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                AlignedTable(
                    columns: [
                        .init(heading: "project"),
                        .init(heading: "name", elastic: true),
                    ],
                    rows: projects.map {
                        [.init(text: $0.id), .init(text: $0.name, role: Role.dim)]
                    })

                // ⚠ An explicit break. It used to come from `AlignedTable` drawing
                // a header row for `Offers`' two unnamed columns — spacing as a
                // side effect of a blank heading.
                Text("")
                // ⚠ The commands, spelled out and one per line. "The key is what
                // every other verb takes" leaves the reader to assemble the
                // command: name the way out, do not describe it.
                Offers([
                    .init(command: "oilbird summary <key>", what: "gate, measures, counts"),
                    .init(command: "oilbird issues <key>", what: "what the last scan found"),
                ])
            }
            .padding(.init(horizontal: 2, vertical: 0))
        }
    }
}
