import SwiftTUI

/// What is running, if anything.
public struct StatusScreen: View {
    public enum State: Sendable, Equatable {
        case running(facts: [String], dashboard: String)
        case paused(rule: String)
        case notInstalled
        case starting
        case unresponsive(address: String)
    }

    let state: State

    public init(state: State) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .running(let facts, let dashboard):
                // ⚠ Separated by a middle dot and wrapped by the RUNTIME:
                // hand-splitting them ran to 70 cells on a 60-column terminal,
                // which is what the `screens` check exists to find.
                line("running", Role.plain, facts)
                Text("")
                HStack(spacing: 2) {
                    Text("dashboard").foregroundStyle(Role.note)
                    Text(dashboard).foregroundStyle(Role.action)
                }

            case .paused(let rule):
                // ⚠ No invented reason: it states the RULE, whichever of the
                // watchdog or `down` stopped it, because the lock this derives
                // from carries no reason across processes.
                line("paused", Role.warn, [rule])
                Text("")
                Text(
                    "Nothing is running and nothing is lost. Any command starts it again, "
                        + "which costs about 15 seconds and 1.6 GB."
                )
                Text("")
                Offers([.init(command: "oilbird up", what: "")])

            case .notInstalled:
                line("not set up", Role.warn, [])
                Text("")
                Text(
                    "Oilbird fetches everything it needs itself — no Java, no PostgreSQL, "
                        + "no Docker."
                )
                Text("")
                Offers([
                    .init(command: "oilbird up", what: "sets it up and starts it"),
                    .init(command: "oilbird version", what: "lists what it would download"),
                ])

            case .starting:
                line("starting", Role.warn, [])
                Text("")
                Text("Another client is bringing the engine up. Nothing to do.")

            case .unresponsive(let address):
                // ⚠ Its own state and its own exit code. A script that treats
                // this as running makes the next call fail for no visible
                // reason; one that treats it as stopped never repairs it.
                line("NOT ANSWERING", Role.fail, [address])
                Text("")
                Text(
                    "It is recorded as running and does not reply. Any command will restart it."
                )
                Text("")
                Offers([.init(command: "oilbird up", what: "")])
                Text("")
                Text(
                    "exit 3. Its own state and its own exit code: a script that treats this "
                        + "as running makes the next call fail for no visible reason, and one "
                        + "that treats it as stopped never repairs it."
                )
                .foregroundStyle(Role.note)
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }

    /// ⚠ One `Text`, not an `HStack`. A stack lays the word beside the facts
    /// and wraps each independently, so a narrow terminal put the facts
    /// ABOVE the word they describe. Interpolated into one run they reflow as
    /// one sentence, with the word still carrying its own colour.
    @ViewBuilder func line(_ word: String, _ role: Int, _ facts: [String]) -> some View {
        if facts.isEmpty {
            Text(word).foregroundStyle(Role.of(role))
        } else {
            Text(
                """
                \(Text(word).foregroundStyle(Role.of(role)))   \
                \(Text(facts.joined(separator: "   ·   ")).foregroundStyle(Role.note))
                """
            )
        }
    }
}
