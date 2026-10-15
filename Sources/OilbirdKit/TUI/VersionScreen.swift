import SwiftTUI

/// What this build pins, and what is actually here.
public struct VersionScreen: View {
    public struct Row: Sendable, Equatable {
        public let id: String
        public let pinned: String
        /// What is here, already worded, and how sure we are of it.
        public let installed: String
        public let installedRole: Int
        public let licence: String
        /// Oilbird put it here and it is not what this build pins.
        public let differs: Bool

        public init(
            id: String, pinned: String, installed: String, installedRole: Int,
            licence: String, differs: Bool
        ) {
            self.id = id
            self.pinned = pinned
            self.installed = installed
            self.installedRole = installedRole
            self.licence = licence
            self.differs = differs
        }
    }

    let build: String
    let commit: String?
    let rows: [Row]

    public init(build: String, commit: String?, rows: [Row]) {
        self.build = build
        self.commit = commit
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Text("oilbird \(build)").bold()
                if let commit { Text(commit).foregroundStyle(Role.note) }
            }
            Text("")
            AlignedTable(
                columns: [
                    .init(heading: ""), .init(heading: "pinned"),
                    .init(heading: "installed"), .init(heading: "licence"),
                ],
                rows: rows.map {
                    [
                        .init(text: $0.id),
                        .init(text: $0.pinned),
                        .init(text: $0.installed, role: $0.installedRole),
                        .init(text: $0.licence, role: Role.dim),
                    ]
                })

            // ⚠ Only when there is something to say. A footnote explaining a
            // difference that is not there is noise on every other run.
            ForEach(rows.filter(\.differs), id: \.id) { row in
                Text("")
                HStack(spacing: 2) {
                    Text(row.installed).foregroundStyle(Role.attn)
                    Text("the \(row.id) on disk is not the one this build pins.")
                }
                HStack(spacing: 2) {
                    Text("It is replaced on the next start.")
                    Text("oilbird install").foregroundStyle(Role.action)
                }
            }

            Text("")
            // ⚠ The command on its own row. Left in the sentence it wrapped to
            // `oilbird` / `doctor` across two lines, which reads fine and pastes
            // wrong — the defect `Offers` was written for.
            Text("`pinned` is what this build intends. `installed` is what is here.")
                .foregroundStyle(Role.note)
            Offers([
                .init(
                    command: "oilbird doctor",
                    what: "the only thing that says whether it WORKS")
            ])
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}
