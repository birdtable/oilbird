import SwiftTUI

/// Something went wrong, what to do about it, and what the exit code means.
///
/// ⚠ The most-read screen in the product, so the wrapping matters most here.
/// The markup version hand-wrapped and the sentence about exit codes ran to
/// 122 cells: a footnote about reading the output that did not itself fit in
/// the window.
public struct ErrorScreen: View {
    let what: String
    let advice: [Offers.Offer]
    let note: String

    public init(what: String, advice: [Offers.Offer] = [], note: String = "") {
        self.what = what
        self.advice = advice
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Text("error").foregroundStyle(Role.bad)): \(what)")
            if !advice.isEmpty {
                Text("")
                Offers(advice)
            }
            if !note.isEmpty {
                Text("")
                Text(note).foregroundStyle(Role.note)
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}

/// The scan finished and analysed nothing.
///
/// ⚠ Its own screen and its own exit code. "It worked and found no issues"
/// and "it read no code at all" look identical in every number the product
/// reports, and only one of them means the project is clean.
public struct ReadNothingScreen: View {
    let path: String
    let because: String

    public init(path: String, because: String) {
        self.path = path
        self.because = because
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Text("read nothing").foregroundStyle(Role.attn)): \(path)")
            Text("")
            Text("The scan finished and analysed no source at all — 0 files, 0 lines.")
            Text("Any issue count, measure or gate for this project describes nothing.")
            Text("")
            Text(because)
            Text("")
            Text(
                "exit 3. The other ways to read nothing: the directory is empty, it holds no "
                    + "language this SonarQube analyses, or everything in it was excluded."
            )
            .foregroundStyle(Role.note)
            Offers([.init(command: "oilbird scans", what: "shows which")])
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}
