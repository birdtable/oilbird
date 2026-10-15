import SwiftTUI

/// One dependency, and whether it actually works.
///
/// ⚠ One ROW, not a screen, and that is the point. `doctor` prints each row
/// as its check completes — every one of them RUNS the thing it names, and
/// the four together took 7.45 seconds of silence on a real machine
/// before they all appeared at once. A tool that looks hung gets killed. The
/// rows arriving IS the progress, so this renders a row and the streaming
/// stays exactly where it was.
public struct DiagnosisRow: View {
    /// ⚠ The token carries the severity by CASE as well as by colour: `ok`
    /// does not shout, `FAIL` does, `wait` is neither. That second channel is
    /// what survives `NO_COLOR`, a monochrome terminal and a screenshot
    /// pasted into Slack — and it is why `grep -c ok` works on the piped
    /// form.
    ///
    /// ⚠ `waiting` is its own state and not a failure. The scanner cannot be
    /// checked until the server is up, and printing FAIL beside a dependency
    /// that is present and correct sent people off to reinstall it.
    public enum State: Sendable, Equatable {
        case working(String)
        case failed(String)
        case waiting(found: String, why: String, next: String)
    }

    let dependency: String
    let state: State

    public init(dependency: String, state: State) {
        self.dependency = dependency
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .working(let version):
                mark("ok", Role.good, version, Role.dim)
            case .failed(let reason):
                mark("FAIL", Role.bad, "", Role.dim)
                Text(reason).foregroundStyle(Role.note)
            case .waiting(let found, let why, let next):
                mark("wait", Role.attn, found, Role.dim)
                Text(why).foregroundStyle(Role.note)
                Text(next).foregroundStyle(Role.note)
            }
        }
        // ⚠ The same two cells every other screen indents by. These rows print one
        // at a time into a page whose summary is already indented, so a row flush
        // to the margin reads as another program's output.
        .padding(.init(horizontal: 2, vertical: 0))
    }

    @ViewBuilder func mark(
        _ word: String, _ tone: AnyShapeStyle, _ detail: String, _ detailRole: Int
    ) -> some View {
        HStack(spacing: 2) {
            Text(word).foregroundStyle(tone).frame(width: 5, alignment: .leading)
            Text(dependency).frame(width: 12, alignment: .leading)
            Text(detail).foregroundStyle(Role.of(detailRole))
        }
    }
}
