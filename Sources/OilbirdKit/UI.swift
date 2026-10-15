import Darwin
import Foundation

/// Oilbird's terminal design system, and the rules it enforces.
///
/// These are Oilbird's own rules, and the screens they produce are drawn in a
/// design page generated from a model of the screens. What follows is why
/// this type has the shape it has.
///
/// # The one rule everything else follows from
///
/// PRESENTATION IS WHAT ONLY EXISTS AT A KNOWN TERMINAL. Behaviour is what
/// survives a pipe. An agent pipes this CLI constantly, so when the stream is
/// not a terminal every screen emits the plain bytes and nothing else: no
/// colour, no rules, no wordmark, no reflow. You cannot wrap to a width you do
/// not know, and an escape in a CI transcript makes the log harder to read,
/// which is the opposite of the point.
///
/// ⚠ The two capabilities are derived SEPARATELY and callers ask for the one
/// they need. `columns` says we know how wide the screen is; `rich` says
/// escapes will render. `NO_COLOR` at a terminal leaves `columns` set and
/// `rich` false — the reader keeps the layout and loses only the paint — and
/// collapsing them into one flag is what loses that.
///
/// # The palette — six roles, and colour that still means something
///
/// If everything is coloured, nothing is, so colour is spent on the three
/// things a reader is looking for: what is WRONG, what they will TYPE, and
/// what they may SKIP. `bad`/`attn`/`good` paint the status TOKEN and never
/// the sentence after it — a whole red line makes severity a property of prose
/// rather than of a column the eye runs down. Severity is carried by CASE as
/// well (`FAIL` shouts, `ok` does not), which is a second channel that
/// survives `NO_COLOR`, a monochrome terminal and a screenshot pasted into
/// Slack.
///
/// Eight-colour SGR only. No truecolour, no 256-colour, no backgrounds, no
/// blue — it is unreadable on the default Terminal.app ground and half of any
/// fleet has never changed it. Eight colours render identically in
/// Terminal.app, iTerm, a CI job log, tmux without 256-colour and over ssh to
/// something ancient, and there is no design idea here worth losing that.
///
/// # Markup, so a hundred existing strings did not have to be rewritten
///
/// Oilbird's messages already put commands in backticks — `oilbird up`,
/// `oilbird log` — which is a markup language nobody had to be taught, so it
/// is read as one: a backticked run is painted `action` and the backticks are
/// removed, because they were only ever standing in for the emphasis we could
/// not do. They come back when `rich` is false, because then they are carrying
/// the emphasis again. This is the highest-leverage part of the file: it gave
/// the right highlighting to every recovery sentence in `OilbirdError` without
/// touching one of them.
///
/// The composed screens add `{role|text}`, which is the markup the design
/// page is written in, so a screen is transcribed from it rather than
/// reinterpreted into code.
///
/// # What is deliberately not here
///
/// No progress bar, no cursor-addressed redraw, no alternate screen, no
/// full-screen form. Anything that repaints has to be undone correctly for
/// pipes, for CI, on SIGWINCH and on SIGINT, and every one of those is a way
/// to leave somebody's terminal in a state. Where a command is producing
/// output, that output IS the progress — `doctor`'s rows arriving is the
/// progress bar.
///
/// ⚠ There is exactly one animation, `UI.working`, and reading that rule as
/// "no spinner" is wrong. It is for a step that prints NOTHING while it
/// works, it is indeterminate, and it leaves no trace.
/// `UIWorking.swift` carries the argument and the four places it is allowed.
public struct UI: Sendable {
    /// How wide the terminal is, or `0` when there is no terminal to ask.
    ///
    /// Zero is not a small number, it is *unknown*: nothing is wrapped or
    /// padded to a screen width that was guessed, because a guess is what
    /// makes piped output depend on the window it was produced from.
    public let columns: Int

    /// Whether escapes will render. False under a pipe, `NO_COLOR`,
    /// `TERM=dumb` and in CI.
    public let rich: Bool

    public init(columns: Int, rich: Bool) {
        self.columns = columns
        self.rich = rich
    }

    /// Plain output with no known width — what a pipe gets, and the safe
    /// default for anything composing text before it knows better.
    public static let piped = UI(columns: 0, rich: false)

    /// The measure, clamped to 96 columns however wide the window is.
    ///
    /// Long lines are harder to read and most of what Oilbird prints is prose.
    /// `0` stays `0`: unknown is not 96.
    public var measure: Int { columns == 0 ? 0 : min(columns, Self.maximumMeasure) }

    public static let maximumMeasure = 96
}

// MARK: - the palette

extension UI {
    /// The six roles colour is spent on, plus the body default and the four
    /// the wordmark's gradient runs through.
    ///
    /// The wordmark's four are ANSI indices like everything else — Oilbird's
    /// mark is terracotta and red→yellow is the warm quarter of the sixteen
    /// the reader already chose, so the handsome version and the principled
    /// version are the same version.
    public enum Role: String, Sendable, CaseIterable {
        /// WRONG. The tool will misbehave.
        case bad
        /// STALE or unmeasured. True, and not alarming.
        case attn
        /// RIGHT, and the verdict when it is good.
        case good
        /// TEXT THE READER WILL TYPE. Commands, keys, menu rows.
        case action
        /// Text the reader may skip. Provenance, detail.
        case note
        /// One per screen: the heading, or the answer.
        case bold
        /// Everything else, and therefore never painted at all.
        case body
        case ember, flame, amber, spark

        /// The SGR parameter, and eight-colour only.
        var sgr: String {
            switch self {
            case .bad: "31"
            case .attn: "33"
            case .good: "32"
            case .action: "36"
            case .note: "90"
            case .bold: "1"
            case .body: "39"
            case .ember: "31"
            case .flame: "91"
            case .amber: "33"
            case .spark: "93"
            }
        }
    }
}

// MARK: - markup

extension UI {
    /// One run of text with one role.
    public struct Span: Sendable, Equatable {
        public let role: Role
        public let text: String
        /// True when this run came from `backticks` in a message string.
        ///
        /// Remembered rather than flattened into the role, because the
        /// backticks have to come back when there is no paint to replace
        /// them — and by then the role alone cannot say whether they were
        /// ever there.
        public let quoted: Bool

        public init(role: Role, text: String, quoted: Bool = false) {
            self.role = role
            self.text = text
            self.quoted = quoted
        }
    }

    /// Split a line of markup into runs.
    ///
    /// Two markups in one pass, because they nest: `{body|Try `oilbird up`.}`
    /// is a body run around an action run, and two independent passes would
    /// either paint the braces or miss the backticks inside them.
    ///
    /// Anything that does not parse is text. A `{` with no role, an unclosed
    /// brace and a lone backtick are all things a project key or a scanner
    /// message can contain, and a markup language that mangles its own input
    /// is worse than no markup at all.
    public static func spans(_ markup: String) -> [Span] {
        var found: [Span] = []
        var buffer = ""
        var index = markup.startIndex

        func flush(_ role: Role = .body) {
            guard !buffer.isEmpty else { return }
            found.append(Span(role: role, text: buffer))
            buffer = ""
        }

        while index < markup.endIndex {
            let character = markup[index]
            // ⚠ Before everything, so escaped text cannot be markup. A
            // reader's own `}` otherwise closes the run it sits in, and the
            // text after it changes colour and loses a brace.
            if character == "\\", let escaped = readEscape(markup, from: index) {
                buffer.append(escaped.character)
                index = escaped.end
                continue
            }
            if character == "{", let token = readToken(markup, from: index) {
                flush()
                found.append(contentsOf: backticked(token.text, as: token.role))
                index = token.end
                continue
            }
            if character == "`", let quote = readQuoted(markup, from: index) {
                flush()
                found.append(Span(role: .action, text: quote.text, quoted: true))
                index = quote.end
                continue
            }
            buffer.append(character)
            index = markup.index(after: index)
        }
        flush()
        return found
    }

    /// Untrusted text, made safe to put INSIDE markup.
    ///
    /// ⚠ **The CLI used to replace every `{` with `(` before printing a
    /// scanner message**, so *duplicating this literal `"{source}"`* reached a
    /// person as `"(source}"` — a string that is not in their code, and one a
    /// reader went and grepped for. `--json`, the MCP server and the app never
    /// did it, so the one surface a person reads was the only one that
    /// misreported their own source. On a brace-heavy language it fired
    /// constantly.
    ///
    /// The parser never needed it. `spans` promises that anything which does
    /// not parse is text, and `readToken` refuses a brace that is not followed
    /// by a known role, so `{source}` was always safe to print. What is not
    /// safe is text that spells a REAL token, and that is all this touches.
    ///
    /// ⚠ EVERY brace, not the ones that look dangerous. The first version of
    /// this escaped `{` only when a role and a `|` followed, and a test found
    /// the other half within minutes: a `}` in the text CLOSES the run it was
    /// concatenated into, so `{note|…"{source}" 4 times.}` ended the note at
    /// the reader's own brace and printed `"{source" 4 times.}`. A rule about
    /// which braces are safe has to be right about both of them at once,
    /// which is how the first bug got written.
    public static func escapingMarkup(_ text: String) -> String {
        var out = ""
        for character in text {
            if "{}`".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// One `{role|text}` read out of the markup.
    private struct Token {
        let role: Role
        let text: String
        /// Where to carry on reading, just past the closing brace.
        let end: String.Index
    }

    /// `{role|text}` at `start`, or nil when this brace is just a brace.
    ///
    /// ⚠ The closing brace has to be an UNESCAPED one. Searching for the
    /// first `}` ends the run at the reader's own brace instead: a message
    /// saying `duplicating this literal "{source}"` closed the note early,
    /// and everything after it changed colour and lost a character.
    private static func readToken(_ markup: String, from start: String.Index) -> Token? {
        let afterBrace = markup.index(after: start)
        guard let bar = markup[afterBrace...].firstIndex(of: "|"),
            let role = Role(rawValue: String(markup[afterBrace..<bar])),
            let close = unescapedIndex(of: "}", in: markup, from: markup.index(after: bar))
        else { return nil }
        return Token(
            role: role, text: String(markup[markup.index(after: bar)..<close]),
            end: markup.index(after: close))
    }

    /// The first `character` that is not escaped, at or after `from`.
    private static func unescapedIndex(
        of character: Character, in markup: String, from: String.Index
    ) -> String.Index? {
        var index = from
        while index < markup.endIndex {
            if markup[index] == "\\", let escaped = readEscape(markup, from: index) {
                index = escaped.end
                continue
            }
            if markup[index] == character { return index }
            index = markup.index(after: index)
        }
        return nil
    }

    /// `\{`, `\}` or a backtick at `start`, or nil for an ordinary backslash.
    ///
    /// Only the three characters that mean something to this markup. A
    /// backslash before anything else is a backslash, because paths and
    /// regular expressions are full of them and escaping those would be the
    /// mangling this exists to stop.
    private static func readEscape(_ markup: String, from start: String.Index)
        -> (character: Character, end: String.Index)?
    {
        let next = markup.index(after: start)
        guard next < markup.endIndex, "{}`".contains(markup[next]) else { return nil }
        return (markup[next], markup.index(after: next))
    }

    /// A backticked run at `start`, or nil when the backtick is unpaired.
    private static func readQuoted(
        _ markup: String, from start: String.Index
    ) -> (text: String, end: String.Index)? {
        let afterTick = markup.index(after: start)
        guard let close = unescapedIndex(of: "`", in: markup, from: afterTick),
            close != afterTick
        else { return nil }
        return (String(markup[afterTick..<close]), markup.index(after: close))
    }

    /// The backtick pass, run inside an already-typed run.
    private static func backticked(_ text: String, as role: Role) -> [Span] {
        var found: [Span] = []
        var buffer = ""
        var index = text.startIndex
        while index < text.endIndex {
            // The same escape as the outer pass: a run's text has been
            // through neither, so it still carries the reader's braces.
            if text[index] == "\\", let escaped = readEscape(text, from: index) {
                buffer.append(escaped.character)
                index = escaped.end
                continue
            }
            if text[index] == "`", let quote = readQuoted(text, from: index) {
                if !buffer.isEmpty {
                    found.append(Span(role: role, text: buffer))
                    buffer = ""
                }
                found.append(Span(role: .action, text: quote.text, quoted: true))
                index = quote.end
                continue
            }
            buffer.append(text[index])
            index = text.index(after: index)
        }
        if !buffer.isEmpty { found.append(Span(role: role, text: buffer)) }
        return found
    }
}

// MARK: - rendering

extension UI {
    private static let reset = "\u{1B}[0m"

    /// What a run actually shows: the backticks come back without the paint.
    public func visible(_ span: Span) -> String {
        span.quoted && !rich ? "`\(span.text)`" : span.text
    }

    /// One line of markup, painted or plain.
    ///
    /// Trailing whitespace is removed: a padded last column makes a copied
    /// line longer than what it shows, and a screen full of invisible spaces
    /// is a diff nobody can read.
    public func line(_ markup: String) -> String {
        var out = ""
        for span in Self.spans(markup) {
            let text = visible(span)
            guard rich, span.role != .body || span.quoted else {
                out += text
                continue
            }
            out += "\u{1B}[\(span.role.sgr)m" + text + Self.reset
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// The markup with every escape removed — what a pipe would have seen.
    public func stripped(_ markup: String) -> String {
        Self.spans(markup).map(visible).joined()
    }

    /// "1 files, 3 lines" is what an unchecked interpolation reads like.
    ///
    /// ⚠ In Kit and not beside the CLI's other helpers, because the screens
    /// are here and could not reach it: `summary` shipped "1 issues" and
    /// "0 of 1 conditions" on the same screen, under a helper that had
    /// existed for weeks three files away.
    public static func counted(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    /// Display width, in cells.
    ///
    /// ⚠ `count` counts Characters and would be right here by luck;
    /// `utf8.count` counts bytes and is the classic miscount in hand-rolled
    /// padding, because every screen in this design has an em dash in it.
    /// Measured properly, so a wide glyph in a project name
    /// cannot push one row two cells right of every other row.
    public func cells(_ markup: String) -> Int {
        Self.width(stripped(markup))
    }

    static func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (isWide(scalar) ? 2 : (isZeroWidth(scalar) ? 0 : 1))
        }
    }

    /// East Asian Wide and Fullwidth, which occupy two cells.
    ///
    /// The ranges rather than a Foundation call: Swift exposes no equivalent
    /// of Python's `unicodedata`, which the design model uses, so the blocks
    /// that can turn up in a project name or a path are listed. Emoji are
    /// in here because a repository called `🛒-shop` is not hypothetical.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
            0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
            0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
            0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            true
        default:
            false
        }
    }

    /// Combining marks, which add nothing to the width of what they sit on.
    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        (0x0300...0x036F).contains(scalar.value) || scalar.value == 0x200B
    }
}

// MARK: - layout

extension UI {
    public enum Align: Sendable { case left, right }

    /// Markup padded to a column, measured by display width.
    ///
    /// The padding is plain spaces appended to the markup, so it survives the
    /// paint pass untouched — and it is measured against `visible`, which is
    /// why a backticked command pads correctly in both modes even though it
    /// is two cells narrower in one of them.
    public func pad(_ markup: String, to column: Int, align: Align = .left) -> String {
        let gap = String(repeating: " ", count: max(0, column - cells(markup)))
        return align == .left ? markup + gap : gap + markup
    }

    /// A rule, and only when `rich`.
    ///
    /// Box drawing is used for rules only, and only under the condition we
    /// already believe escapes will render — so the status gutter, which is
    /// the part of the output the eye follows, never risks a mojibake box.
    /// Indented to the body margin: a rule flush at column zero reads as a
    /// separator between screens rather than as a heading attached to what
    /// follows it.
    public func rule(_ label: String = "") -> [String] {
        guard rich, measure > 8 else { return [] }
        guard !label.isEmpty else { return ["  {note|" + String(repeating: "─", count: measure - 4) + "}"] }
        let dashes = max(1, measure - 5 - Self.width(label))
        return ["  {bold|" + label + "} {note|" + String(repeating: "─", count: dashes) + "}"]
    }

    /// A table, its columns sized to their content and joined by a gutter.
    ///
    /// ⚠ Sized to the content rather than to fixed widths, because the first
    /// column of most of these tables IS the project key — `follow` and
    /// `--stop` take exactly that string — and a table that truncated it to
    /// fit would be showing something nobody can use.
    ///
    /// ⚠ And the columns are joined by a GUTTER, not butted together. Without
    /// one a right-aligned cell fills its whole width and touches the next
    /// column — `1m 12s~/src/storefront` — which is invisible while every
    /// column happens to have slack and appears the moment one does not.
    public func table(
        headers: [String], rows: [[String]], align: [Align] = [], gutter: Int = 2
    ) -> [String] {
        guard !headers.isEmpty else { return [] }
        let widths = headers.indices.map { column in
            max(
                cells(headers[column]),
                rows.map { cells($0.indices.contains(column) ? $0[column] : "") }.max() ?? 0)
        }
        let gap = String(repeating: " ", count: gutter)
        func compose(_ cellsIn: [String]) -> String {
            "  "
                + widths.indices.map { column in
                    pad(
                        cellsIn.indices.contains(column) ? cellsIn[column] : "",
                        to: widths[column],
                        align: align.indices.contains(column) ? align[column] : .left)
                }.joined(separator: gap)
        }
        return [compose(headers.map { "{note|" + $0 + "}" })] + rows.map(compose)
    }

    /// Markup wrapped to the measure, with a hanging indent to the message
    /// column.
    ///
    /// ⚠ The single biggest defect this exists to fix. A long `doctor`
    /// message used to wrap back to column ZERO, so its second line sat flush
    /// against the left margin and read as the next check. A continuation
    /// line carries the indent now, so a long row is unmistakably one row.
    ///
    /// ⚠ A WORD IS NEVER BROKEN. If a token is longer than the line it
    /// overflows. Almost every over-long token here is a path, a URL or a
    /// command, and all three exist to be copied — a path broken across two
    /// lines is a path that cannot be double-clicked. Ragged right beats
    /// unusable.
    ///
    /// Unknown width wraps nothing at all, which is the honest behaviour: the
    /// bytes a pipe gets must not depend on the window they were produced
    /// from.
    public func wrap(_ markup: String, hanging: Int = 0) -> [String] {
        guard measure > hanging + 8 else { return [markup] }
        let indent = String(repeating: " ", count: hanging)
        var lines: [String] = []
        var current: [Span] = indent.isEmpty ? [] : [Span(role: .body, text: indent)]
        // ⚠ `hanging`, never 0: the indent is already ON the first line, so a
        // budget starting at zero lets every first line run that many cells
        // past the measure while the continuations stay right.
        var used = hanging
        // ⚠ Not `used > 0`: indentation counts toward `used` without being
        // content, so a long first word never wraps and a line holding only
        // the hanging indent wraps again immediately.
        var hasContent = false

        // ⚠ Adjacent words of one role are ONE run. A run per word is visually
        // identical and eight times the bytes, unreadable in a transcript.

        // ⚠ Quoted runs merge too: `oilbird --help` is one command, and two
        // spans put the ticks around each half. Two genuinely separate
        // backticked runs cannot be adjacent, since body text divides them.
        func append(_ span: Span) {
            if let last = current.last, last.role == span.role, last.quoted == span.quoted {
                current[current.count - 1] = Span(
                    role: last.role, text: last.text + span.text, quoted: last.quoted)
                return
            }
            current.append(span)
        }

        for span in Self.spans(markup) {
            // ⚠ Split KEEPING the empties, restoring the delimiter after the
            // first piece: emitting a space only for an empty piece deletes
            // every single-space gap, since one space produces no empty piece.

            // A run boundary is not a word boundary, which is why the spans are
            // walked and not the rendered string.
            let pieces = span.text.split(separator: " ", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index > 0 {
                    append(Span(role: span.role, text: " ", quoted: span.quoted))
                    used += 1
                }
                guard !piece.isEmpty else { continue }
                let word = String(piece)
                let wide = Self.width(
                    visible(Span(role: span.role, text: word, quoted: span.quoted)))
                if hasContent, used + wide > measure {
                    lines.append(serialised(current))
                    current = indent.isEmpty ? [] : [Span(role: .body, text: indent)]
                    used = hanging
                    hasContent = false
                }
                append(Span(role: span.role, text: word, quoted: span.quoted))
                used += wide
                hasContent = true
            }
        }
        lines.append(serialised(current))
        return lines
    }

    /// Runs put back into the markup they came out of, so wrapping a line
    /// yields lines this same type can paint.
    ///
    /// Trailing whitespace goes: a padded line makes a copied one longer than
    /// what it shows.
    private func serialised(_ spans: [Span]) -> String {
        // ⚠ Trimmed on the RUNS, before anything is serialised. Trimming the
        // finished markup instead means chasing a closing brace back through
        // the spaces it sits behind, which is a parser written backwards.
        var runs = spans
        while let last = runs.last {
            let trimmedText = String(last.text.reversed().drop { $0 == " " }.reversed())
            if trimmedText.isEmpty {
                runs.removeLast()
                continue
            }
            runs[runs.count - 1] = Span(
                role: last.role, text: trimmedText, quoted: last.quoted)
            break
        }
        return runs.map { span in
            if span.quoted { return "`" + span.text + "`" }
            if span.role == .body { return span.text }
            return "{" + span.role.rawValue + "|" + span.text + "}"
        }.joined()
    }
}

// MARK: - capability

extension UI {
    /// The capabilities of this process's streams.
    ///
    /// ⚠ Human output leaves this CLI on STDERR — `--json` owns stdout, so
    /// `oilbird scan . --json | jq` works while a person still sees progress
    /// — and both streams are consulted. Painting requires both to be
    /// terminals: a reader who has redirected either half of a screen is not
    /// "at a known terminal" for the whole of it, and a redirect must emit no
    /// escapes at all whichever half it captured.
    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UI {
        derive(
            stdoutIsTerminal: isatty(1) == 1, stderrIsTerminal: isatty(2) == 1,
            columns: terminalColumns(), environment: environment)
    }

    /// The decision, over facts rather than over the process — so every rule
    /// below is a test rather than an opinion.
    public static func derive(
        stdoutIsTerminal: Bool, stderrIsTerminal: Bool, columns: Int,
        environment: [String: String]
    ) -> UI {
        let terminal = stdoutIsTerminal && stderrIsTerminal
        let term = environment["TERM"] ?? ""
        // ⚠ NO_COLOR is honoured by PRESENCE, whatever its value: no-color.org
        // is explicit that it is set or unset, and `NO_COLOR=0` meaning "yes
        // colour" makes an accessibility setting unreliable.
        let muted =
            environment["NO_COLOR"] != nil || term.isEmpty || term == "dumb" || isCI(environment)
        return UI(
            columns: terminal || stderrIsTerminal ? columns : 0, rich: terminal && !muted)
    }

    /// CI, where escapes are noise and nobody is watching a live screen.
    ///
    /// A list rather than one variable: `CI` is the convention and four of
    /// the five runners here also set their own, so a job that unsets `CI`
    /// for a step is still recognised.
    static func isCI(_ environment: [String: String]) -> Bool {
        if let flag = environment["CI"], !flag.isEmpty, flag != "0", flag.lowercased() != "false" {
            return true
        }
        return ["GITHUB_ACTIONS", "GITLAB_CI", "BUILDKITE", "JENKINS_URL", "TEAMCITY_VERSION"]
            .contains { environment[$0]?.isEmpty == false }
    }

    /// The window's width, from the kernel.
    ///
    /// stderr first, because that is the stream the screens are written to.
    /// `COLUMNS` is deliberately not consulted: it is exported by some shells
    /// and stale in every one of them after a resize, and a stale width is
    /// worse than a known one.
    static func terminalColumns() -> Int {
        for descriptor in [Int32(2), Int32(1), Int32(0)] {
            guard isatty(descriptor) == 1 else { continue }
            var size = winsize()
            guard ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { continue }
            return Int(size.ws_col)
        }
        return 0
    }

    /// The window's height, from the kernel, or 0 without one.
    ///
    /// ⚠ Only the browser reads this, and only to decide how many rows fit.
    /// Every other screen is as long as it needs to be and lets the terminal
    /// scroll — a screen that trims itself to the window is a screen whose
    /// output changes with the reader's window size, which is exactly what a
    /// pipe must never see.
    public static func terminalRows() -> Int {
        for descriptor in [Int32(2), Int32(1), Int32(0)] {
            guard isatty(descriptor) == 1 else { continue }
            var size = winsize()
            guard ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_row > 0 else { continue }
            return Int(size.ws_row)
        }
        return 0
    }

    /// Whether a screen may ask the reader a question.
    ///
    /// ⚠ Derived separately from `rich`, and stricter: it needs STDIN as
    /// well. `oilbird < /dev/null` in a cron job has a terminal on both
    /// output streams and nobody to answer, and a menu that blocks there is a
    /// hang rather than a feature. `NO_COLOR` does not enter into it —
    /// removing the paint does not remove the reader.
    public static func interactive(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isatty(0) == 1 && isatty(1) == 1 && isatty(2) == 1 && !isCI(environment)
    }
}
