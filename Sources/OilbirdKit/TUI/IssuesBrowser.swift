import SwiftTUI

/// One issue, reduced to what a reader picks from.
public struct IssueRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let severity: String
    public let file: String
    public let line: Int?
    public let rule: String
    public let message: String

    public init(
        id: String, severity: String, file: String, line: Int?, rule: String, message: String
    ) {
        self.id = id
        self.severity = severity
        self.file = file
        self.line = line
        self.rule = rule
        self.message = message
    }

    public var place: String { line.map { "\(file):\($0)" } ?? file }
}

/// What the browser is showing, and what it is showing it of.
///
/// ⚠ A value, and every decision in it is a pure function. The old browser
/// mixed the same decisions into a keyboard loop, so "does this filter match"
/// could only be asked by pressing a key. These are the assertions worth
/// keeping; the drawing and the key handling belong to the framework now.
public struct IssueFilter: Sendable, Equatable {
    public var severity: String?
    public var needle: String

    public init(severity: String? = nil, needle: String = "") {
        self.severity = severity
        self.needle = needle
    }

    /// ⚠ Recomputed, never cached. A cached list and a selection are two
    /// facts that can disagree, and the way they disagree is an
    /// out-of-range read in front of somebody reading their own code.
    nonisolated public func admits(_ issue: IssueRow) -> Bool {
        if let severity, issue.severity != severity { return false }
        guard !needle.isEmpty else { return true }
        let needle = needle.lowercased()
        return issue.file.lowercased().contains(needle)
            || issue.message.lowercased().contains(needle)
            || issue.rule.lowercased().contains(needle)
    }

    nonisolated public func apply(to issues: [IssueRow]) -> [IssueRow] {
        issues.filter(admits)
    }

    /// The next severity in the cycle, ending back at every severity.
    ///
    /// ⚠ Cycles through `nil` rather than wrapping straight from the last
    /// severity to the first. "Everything" is a state a reader needs to get
    /// back to, and a cycle that skips it makes them press the key N times
    /// and watch for the one that looks unfiltered.
    nonisolated public func cycled(through severities: [String]) -> IssueFilter {
        var next = self
        guard let severity, let index = severities.firstIndex(of: severity) else {
            next.severity = severities.first
            return next
        }
        next.severity = index + 1 < severities.count ? severities[index + 1] : nil
        return next
    }
}

/// The issues of one project, browsable.
public struct IssuesBrowser: View {
    let project: String
    let issues: [IssueRow]
    /// The severity words this project's taxonomy uses, in order.
    ///
    /// ⚠ Passed in, never enumerated here. SonarQube reports one of two
    /// vocabularies depending on the server's mode, and a browser that knew
    /// only one would offer a filter that matches nothing.
    let severities: [String]

    @State private var filter = IssueFilter()
    @State private var selection: Set<IssueRow.ID> = []
    @State private var cursor: IssueRow.ID?
    /// ⚠ Two properties, because they are two things. `filtering` is whether
    /// the field is on screen; `filterFocused` is whether it has the keys.
    /// One `@FocusState` doing both did not work and did not fail: assigning
    /// `true` to a focus binding with no view bound to it is not a toggle,
    /// and the field never appeared, so `/` silently did nothing while every
    /// other key worked.
    @State private var filtering = false
    @FocusState private var filterFocused: Bool

    public init(project: String, issues: [IssueRow], severities: [String]) {
        self.project = project
        self.issues = issues
        self.severities = severities
    }

    var visible: [IssueRow] { filter.apply(to: issues) }

    var focused: IssueRow? { Self.focus(cursor, in: visible) }

    /// The row the detail pane describes.
    ///
    /// ⚠ Falls back to the first visible row rather than holding a cursor
    /// that is no longer in the list. Narrowing the filter can hide the
    /// selected row, and a detail pane still describing it shows a reader one
    /// issue while their cursor sits on another. A static because it is a
    /// decision worth asserting, and a private computed property on a
    /// `@MainActor` view cannot be.
    nonisolated public static func focus(
        _ cursor: IssueRow.ID?, in visible: [IssueRow]
    ) -> IssueRow? {
        guard let cursor else { return visible.first }
        return visible.first { $0.id == cursor } ?? visible.first
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // ⚠ Drawn only while in USE. An always-present `TextField` is the first
            // focusable thing on screen and takes focus as the browser opens, so
            // every key goes into it and no command fires.
            if filtering || !filter.needle.isEmpty {
                TextField("filter", text: $filter.needle)
                    .focused($filterFocused)
                    .textFieldStyle(.plain)
            }
            Divider()
            // ⚠ The DATA initialiser: a builder-composed list measures every
            // row every frame and trips `collection.eagerLargeCollection` past
            // a few hundred, where a project here carries two thousand.
            List(visible, selection: $cursor) { issue in
                row(issue)
            }
            // ⚠ Neither `.automatic` nor `.plain`: one boxes the whole list,
            // the other rules every row. A border around the one thing a
            // reader is scanning is the chrome that costs most.
            .listStyle(.bare)
            .frame(maxHeight: .infinity)
            Divider()
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // ⚠ `focusable`, or none of the keys below arrive: `onKeyPress` runs on
        // the focused view and bubbles up the focus chain, and a view that
        // cannot hold focus is not on it.
        .focusable(true)
        // ⚠ Declined, never consumed, while the filter has focus: typing `/`
        // into it must produce a slash, or the field is unusable for the one
        // job it exists for.
        .onKeyPress(.any) { key in
            guard !filterFocused else { return .ignored }
            switch key {
            case KeyPress(.character("/")):
                filtering = true
                filterFocused = true
                return .handled
            case KeyPress(.space):
                guard let id = focused?.id else { return .ignored }
                if selection.contains(id) {
                    selection.remove(id)
                } else {
                    selection.insert(id)
                }
                return .handled
            case KeyPress(.character("s")):
                filter = filter.cycled(through: severities)
                return .handled
            case KeyPress(.escape):
                // Clearing the filter is the way back from an empty list, so
                // escape does that before it does anything else.
                guard !filter.needle.isEmpty || filter.severity != nil else { return .ignored }
                filter = IssueFilter()
                filtering = false
                filterFocused = false
                return .handled
            default:
                return .ignored
            }
        }
    }

    @ViewBuilder var header: some View {
        HStack(spacing: 2) {
            Text(project).bold()
            Text(Self.counted(visible.count, of: issues.count))
                .foregroundStyle(Role.note)
            if let severity = filter.severity {
                Text(severity).foregroundStyle(Self.tone(severity))
            }
            Spacer(minLength: 1)
            if !selection.isEmpty {
                Text("\(selection.count) selected").foregroundStyle(Role.attn)
            }
        }
    }

    @ViewBuilder func row(_ issue: IssueRow) -> some View {
        HStack(spacing: 2) {
            Text(selection.contains(issue.id) ? "•" : " ")
                .foregroundStyle(Role.attn)
                .frame(width: 1)
            Text(issue.severity)
                .foregroundStyle(Self.tone(issue.severity))
                .frame(width: 8)
            Text(issue.place)
                .foregroundStyle(Role.note)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: 34, alignment: .leading)
            Text(issue.message).lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder var detail: some View {
        if let issue = focused {
            VStack(alignment: .leading, spacing: 0) {
                Text(issue.message)
                HStack(spacing: 2) {
                    Text(issue.rule).foregroundStyle(Role.note)
                    Text(issue.place).foregroundStyle(Role.note)
                }
            }
        } else {
            // ⚠ Not a dead end: a filter that matches nothing says how to get back,
            // rather than leaving an empty box and a cursor.
            VStack(alignment: .leading, spacing: 0) {
                Text("Nothing matches that filter.").foregroundStyle(Role.attn)
                Text("Clear it to see all \(issues.count) again.")
                    .foregroundStyle(Role.note)
            }
        }
    }

    /// ⚠ The severity vocabulary is NOT enumerated here. SonarQube ships two
    /// taxonomies and has added words to both; a switch over the ones known
    /// today paints a new one as unremarkable. Anything unrecognised is drawn
    /// as ordinary body text rather than quietly as `note`, which is what the
    /// old screen did.
    nonisolated public static func tone(_ severity: String) -> AnyShapeStyle {
        switch severity.uppercased() {
        case "BLOCKER", "CRITICAL", "HIGH": Role.bad
        case "MAJOR", "MEDIUM": Role.attn
        case "MINOR", "LOW", "INFO": Role.note
        default: Role.body
        }
    }

    nonisolated public static func counted(_ shown: Int, of total: Int) -> String {
        shown == total ? "\(total) issues" : "\(shown) of \(total)"
    }
}
