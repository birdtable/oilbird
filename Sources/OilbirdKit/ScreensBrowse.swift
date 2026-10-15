import Foundation
import OilbirdCore

/// The one screen that repaints, and the reason it is behind a flag.
///
/// ⚠ Everything else Oilbird prints is one-shot output that survives a pipe.
/// Browsing 1,559 rows genuinely cannot be: it needs a cursor, a window into
/// the list, and a detail pane that changes as the cursor moves. So it is
/// `--browse`, it REFUSES without a terminal rather than degrading, and the
/// plain `oilbird issues` — which a pipe and an agent both get — is untouched.
///
/// ⚠ The state is a value and the drawing is a function of it. Nothing here
/// reads a key, writes a stream, or knows a terminal exists; the CLI owns the
/// loop. That is what makes a browser testable at all — the version of this
/// that owned its own run loop could only be checked by a person watching it.
extension UI {
    public func chooseScreen(
        _ title: String, rows: [(value: String, detail: String)], selected: Int?
    ) -> [String] {
        guard !rows.isEmpty else { return ["  {attn|none}{body|  " + title + "}"] }
        var lines = ["  {body|" + title + "}", ""]
        let widest = rows.map { cells($0.value) }.max() ?? 0
        let column = widest + (selected == nil ? 8 : 10)
        for (index, row) in rows.enumerated() {
            let here = index == selected
            let marker = selected == nil ? "" : (here ? "{action|\u{25B8} }" : "  ")
            let number = "{note|" + String(format: "%2d", index + 1) + ".} "
            let value = (here ? "{action|" : "{body|") + row.value + "}"
            let head = pad(marker + number + value, to: column)
            lines.append("  " + head + "{note|" + cut(row.detail, toFit: head) + "}")
        }
        lines += [
            "",
            selected == nil
                ? "  {action|1}{note|\u{2013}}{action|" + String(rows.count)
                    + "}{note| or a name   }{action|\u{23CE}}{note| choose   }"
                    + "{action|q}{note| cancel}"
                : "  {action|\u{2191}\u{2193}}{note| choose   }{action|\u{23CE}}{note| run   }"
                    + "{action|q}{note| cancel}",
        ]
        return lines
    }

    /// The detail column, cut to whatever the measure has left.
    ///
    /// ⚠ It used to be appended whole. `oilbird api` offers 48 services whose
    /// blurbs are SonarQube's own prose and one of them is 142 characters, so
    /// the picker drew 173 cells into a 60-column terminal. Every other screen
    /// is held to the measure by `AlignedTable`; this one draws its own rows
    /// and was held by nothing.
    ///
    /// A trailing ellipsis, not `elide`: that one cuts from the left at a `/`
    /// because a path's END identifies it, and a sentence's end does not.
    func cut(_ detail: String, toFit head: String) -> String {
        // No measure is a pipe, and a pipe has no width to cut to.
        guard measure > 0 else { return detail }
        let room = measure - cells(head) - 2
        guard room > 1 else { return "" }
        guard cells(detail) > room else { return detail }
        var kept = ""
        for character in detail {
            if cells(kept + String(character)) > room - 1 { break }
            kept.append(character)
        }
        return kept + "\u{2026}"
    }

    /// A path shortened from the left, at a separator, to fit.
    ///
    /// ⚠ From the LEFT because the end is what identifies the finding:
    /// `…/model/orderDraft.ts:100` still says everything a reader needs,
    /// where `src/features/accounts/mo…` says nothing at all. Cut at a
    /// `/`, so what is left is a path rather than a fragment of one.
    public static func elide(_ path: String, to room: Int) -> String {
        guard room > 0 else { return "" }
        guard width(path) > room else { return path }
        guard room > 4 else { return String(repeating: "\u{2026}", count: 1) }
        var kept = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: false).reversed() {
            let candidate = kept.isEmpty ? String(part) : part + "/" + kept
            // Two cells for the leading `…/`.
            if width(candidate) + 2 > room { break }
            kept = candidate
        }
        // A single path component too long to fit has no separator to cut
        // at, so the tail is taken directly rather than losing the row.
        guard !kept.isEmpty else { return "\u{2026}" + String(path.suffix(room - 1)) }
        return "\u{2026}/" + kept
    }

    /// The project key stripped off a component path.
    ///
    /// Every row of `oilbird issues <key>` carried the key it was asked
    /// about, in front of the one fact the reader is looking for.
    public static func shorten(_ component: String, of project: String) -> String {
        component.hasPrefix(project + ":")
            ? String(component.dropFirst(project.count + 1)) : component
    }
}
