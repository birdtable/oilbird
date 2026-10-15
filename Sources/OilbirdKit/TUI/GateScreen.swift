import SwiftTUI

/// The quality gate's verdict, and what it is worth.
///
/// ⚠ Three screens, not one with two footnotes. "Passed", "passed but judged
/// nothing" and "passed but read no code" are different answers, and the last
/// two are the ones that let `oilbird gate $KEY && deploy` deploy. Each says
/// its own exit code, because a script author reading this is deciding what
/// to branch on.
public struct GateScreen: View {
    public enum Verdict: Sendable, Equatable {
        /// The analysis read no source at all, whatever the gate says.
        case readNothing(said: String)
        /// The gate evaluated no conditions: a first analysis, no baseline.
        case judgedNothing(said: String)
        /// A real verdict over real conditions.
        case judged(failed: Bool, failedCount: Int, conditions: [GateConditionRow.Condition])
    }

    let project: String
    let verdict: Verdict

    public init(project: String, verdict: Verdict) {
        self.project = project
        self.verdict = verdict
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch verdict {
            case .readNothing(let said):
                // ⚠ `judgedNothing` keys off an empty condition list — true only of
                // a FIRST analysis. From scan two on, SonarQube evaluates every
                // condition against no code and passes: OK, exit 0.
                HStack(spacing: 1) {
                    Text("read nothing").foregroundStyle(Role.attn)
                    Text("\(project) says \(said), and nothing was analysed")
                }
                Text("")
                Text("Nothing was read, so nothing was judged. Any verdict for this project")
                Text("describes nothing.")
                Text("")
                Offers([
                    .init(
                        command: "oilbird summary \(project)",
                        what: "what the last scan found")
                ])
                Text("")
                Text("exit 3 — not 0. A CI step that treats this as a pass is the whole problem.")
                    .foregroundStyle(Role.note)

            case .judgedNothing(let said):
                // ⚠ SonarQube's default gate scores NEW code, so a first
                // analysis has nothing to compare against and every condition
                // is skipped.
                HStack(spacing: 1) {
                    Text("none").foregroundStyle(Role.attn)
                    Text("\(said), but nothing was checked")
                }
                Text("")
                Text("This gate scores NEW code, and there is no baseline yet. Scan again")
                Text("after a change to get a real verdict.")
                Text("")
                Text("exit 3 — not 0, because the honest answer is \"I cannot tell you\".")
                    .foregroundStyle(Role.note)

            case .judged(let failed, let failedCount, let conditions):
                HStack(spacing: 3) {
                    Text(failed ? "FAILED" : "OK")
                        .foregroundStyle(failed ? Role.bad : Role.good)
                    Text(
                        "\(failedCount) of \(conditions.count) condition"
                            + (conditions.count == 1 ? "" : "s")
                    )
                    .foregroundStyle(Role.note)
                }
                // ⚠ Only the failures are drawn. A passing gate with twelve
                // conditions is a wall of green bars saying nothing; the
                // question `gate` answers is "what stopped me".
                let broken = conditions.filter(\.failed)
                if !broken.isEmpty {
                    Text("")
                    ForEach(broken, id: \.metric) { condition in
                        GateConditionRow(condition: condition)
                    }
                }
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}
