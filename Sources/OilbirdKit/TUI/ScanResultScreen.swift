import SwiftTUI

/// How a scan ended.
///
/// ⚠ Five outcomes, and four of them are not "it worked". A scan that read
/// nothing, failed, was stopped, or was interrupted each leaves the project
/// in a different state and each has its own exit code — collapsing them into
/// "scan failed" is what makes a person re-run the same command and get the
/// same nothing.
public struct ScanResultScreen: View {
    public enum Outcome: Sendable, Equatable {
        case scanned(read: String, degraded: Bool, gate: Gate)
        case stopped
        case interrupted(rerun: String)
    }

    public enum Gate: Sendable, Equatable {
        case judgedNothing
        case verdict(said: String, failed: Bool, next: String)
        case none
    }

    let project: String
    let outcome: Outcome

    public init(project: String, outcome: Outcome) {
        self.project = project
        self.outcome = outcome
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch outcome {
            case .scanned(let read, let degraded, let gate):
                HStack(spacing: 3) {
                    Text("scanned").foregroundStyle(Role.good)
                    Text(project).bold()
                    Text(read).foregroundStyle(Role.note)
                }
                // ⚠ Said out loud, not inferred from a missing number. A scan
                // that ran without the project's toolchain reports coverage
                // it never measured, and silence there reads as zero.
                if degraded {
                    Text("")
                    Text("WITHOUT COVERAGE").foregroundStyle(Role.attn)
                }
                switch gate {
                case .judgedNothing:
                    Text("")
                    HStack(spacing: 3) {
                        Text("none").foregroundStyle(Role.attn)
                        Text("quality gate")
                        Text("it scores new code and there is no baseline yet")
                            .foregroundStyle(Role.note)
                    }
                case .verdict(let said, let failed, let next):
                    Text("")
                    HStack(spacing: 3) {
                        Text(said).foregroundStyle(failed ? Role.bad : Role.good)
                        Text("quality gate")
                    }
                    if failed && !next.isEmpty {
                        Offers([.init(command: next, what: "says which conditions")])
                    }
                case .none:
                    Text("")
                }

            case .stopped:
                HStack(spacing: 3) {
                    Text("stopped").foregroundStyle(Role.attn)
                    Text(project).bold()
                }
                Text("")
                Text("Anything already uploaded is kept: the compute engine has it.")

            case .interrupted(let rerun):
                // ⚠ Never resumed. The pid belongs to somebody else now, so
                // "carry on where it left off" is not a thing Oilbird can
                // offer honestly.
                HStack(spacing: 3) {
                    Text("interrupted").foregroundStyle(Role.attn)
                    Text(project).bold()
                }
                Text("")
                Text(
                    "The process that was running it is gone. Whatever it had already "
                        + "uploaded is kept."
                )
                Text("")
                Offers([.init(command: rerun, what: "")])
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}
