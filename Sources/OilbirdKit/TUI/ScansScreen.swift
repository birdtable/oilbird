import SwiftTUI

/// What is running, and what has run.
public struct ScansScreen: View {
    public struct Row: Sendable, Equatable {
        public let key: String
        public let verdict: String
        public let verdictRole: Int
        public let when: String
        public let detail: String

        public init(
            key: String, verdict: String, verdictRole: Int, when: String, detail: String
        ) {
            self.key = key
            self.verdict = verdict
            self.verdictRole = verdictRole
            self.when = when
            self.detail = detail
        }
    }

    let running: [Row]
    let finished: [Row]
    /// How many finished scans exist, which may be more than are shown.
    let finishedTotal: Int

    public init(running: [Row], finished: [Row], finishedTotal: Int) {
        self.running = running
        self.finished = finished
        self.finishedTotal = finishedTotal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if running.isEmpty && finished.isEmpty {
                HStack(spacing: 1) {
                    Text("none").foregroundStyle(Role.attn)
                    Text("nothing has been scanned on this machine yet.")
                }
                Text("")
                Offers([
                    .init(command: "oilbird scan <path>", what: "runs one here and now"),
                    .init(command: "oilbird scan <path> --detach", what: "sends it off instead"),
                ])
            } else {
                if !running.isEmpty {
                    Text("RUNNING").bold()
                    AlignedTable(
                        columns: [
                            .init(heading: "project"), .init(heading: "phase"),
                            .init(heading: "for", trailing: true),
                            .init(heading: "path", elastic: true),
                        ],
                        rows: running.map { rows($0, verdictRole: Role.typed) })
                    Text("")
                }
                if !finished.isEmpty {
                    Text("FINISHED").bold()
                    AlignedTable(
                        columns: [
                            .init(heading: "project"), .init(heading: "verdict"),
                            .init(heading: "when", trailing: true),
                            .init(heading: "read", elastic: true),
                        ],
                        rows: finished.map { rows($0, verdictRole: $0.verdictRole) })

                    // ⚠ Bounded, and it says so. Finished scans stay listed for
                    // ever by design, and a terminal filling with last month's is
                    // not an answer — but a list silently cut is worse.
                    if finished.count < finishedTotal {
                        Text(
                            "and \(finishedTotal - finished.count) more — "
                                + "oilbird scans --json has them all."
                        )
                        .foregroundStyle(Role.note)
                    }
                }
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }

    func rows(_ row: Row, verdictRole: Int) -> [AlignedTable.Cell] {
        [
            .init(text: row.key),
            .init(text: row.verdict, role: verdictRole),
            .init(text: row.when, role: Role.dim),
            .init(text: row.detail, role: Role.dim),
        ]
    }
}
