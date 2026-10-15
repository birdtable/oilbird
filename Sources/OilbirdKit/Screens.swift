import Foundation
import OilbirdCore
import OilbirdModel

/// The composed screens, transcribed from the design they were agreed as.
///
/// They are here and not in `Sources/OilbirdCLI` for the reason the `targets` check
/// enforces: an executable target cannot be `@testable import`-ed (SwiftPM
/// #7596), so a screen written there is untestable by construction — and every
/// one of these has a rule in it worth a test. The CLI stays composition: argv
/// in, a Kit call, one of these out.
///
/// Each returns markup lines for `UI.line` to paint. Nothing here writes to a
/// stream, and nothing here decides an exit code.
extension UI {
    /// `oilbird --help`, the most-read screen of any CLI.
    ///
    /// Verbs are grouped by what you are trying to do rather than listed
    /// alphabetically, and the ones that need an engine running say so once,
    /// in a line at the bottom, rather than in seven descriptions.
    ///
    /// ⚠ The gap between a verb and its description is COMPUTED, not typed.
    /// Hand-padded columns have been a cell out of true three times in this
    /// repository, the last of them `up | down` — which sat one cell right of
    /// every other row in its own section, on the screen more people read than
    /// any other. `cells` measures the visible text, so a verb can be renamed
    /// without anyone counting spaces afterwards.
    public func helpScreen() -> [String] {
        typealias Row = (verb: String, what: String)
        let code: [Row] = [
            ("{action|scan}{note| <path>}", "analyse a directory"),
            ("{action|issues}{note| <key>}", "what the last scan found"),
            (
                "{action|gate}{note| <key>}",
                "the quality gate's verdict {note|(exit 4 if it failed)}"
            ),
            ("{action|summary}{note| <key>}", "gate, measures, issue counts"),
            ("{action|history}{note| <key>}", "how it changed, analysis by analysis"),
            ("{action|projects}", "everything scanned so far"),
            ("{action|forget}{note| <key>}", "remove a project and its results"),
            // ⚠ Under LOOK AT CODE because it starts an engine — the
            // catalogue is read off the running server, which is the whole
            // reason there is no list of endpoints in this binary.
            (
                "{action|api}{note| [call] [k=v]}",
                "every other call this SonarQube has {note|(302 of them)}"
            ),
        ]
        let engine: [Row] = [
            ("{action|status}", "what is running, if anything"),
            ("{action|doctor}", "check every dependency by running it"),
            ("{action|version}", "this build, and the versions it pins"),
            ("{action|log}{note| [lines]}", "the log every failure points at"),
            ("{action|scans}", "what is running, and what has run"),
            (
                "{action|follow}{note| <key>}",
                "attach to a running scan, or read a finished one"
            ),
            // ⚠ Here and not under LOOK AT CODE, though it takes a key: the
            // name lives in Oilbird's own preferences until a scan carries it
            // over, so it starts no engine, which is what this section says.
            ("{action|configure}{note| <key>}", "what a project is called"),
        ]
        let run: [Row] = [
            ("{action|up}{note| | }{action|down}", "start or stop the engine"),
            ("{action|idle}{note| [45|2h|never]}", "when it stops itself"),
            ("{action|install}", "download and unpack what is missing"),
            ("{action|cli-install}", "put {action|oilbird} on your PATH"),
            ("{action|watch}", "supervise a running engine and stop it when idle"),
        ]
        let sections: [(String, [Row])] = [
            ("LOOK AT CODE", code), ("LOOK AT OILBIRD", engine), ("RUN IT", run),
        ]
        let widest: Int = sections.flatMap { $0.1 }.map { cells($0.verb) }.max() ?? 0
        let column = widest + 3
        var listed: [String] = []
        for section in sections {
            listed.append("  {note|" + section.0 + "}")
            for row in section.1 { listed.append("    " + pad(row.verb, to: column) + row.what) }
            listed.append("")
        }
        var lines: [String] = banner()
        lines += [
            "",
            "  {bold|oilbird}{note| — a local SonarQube, with nothing to install first}",
            "",
            "  {note|USAGE}",
            "    {action|oilbird}{note| <command> [--json] [--severity LEVEL]}",
            "",
        ]
        lines += listed
        lines += [
            // ⚠ Named by SECTION, never counted: "the first six need an
            // engine" is a fact that goes stale the next time a verb is added,
            // and nobody re-counts it.
            "  {note|Everything under LOOK AT CODE starts an engine if one is not running,}",
            "  {note|which costs about 15 seconds and 1.6 GB. Nothing under LOOK AT OILBIRD}",
            "  {note|ever does.}",
            "",
            "  {note|--json on any verb for machine-readable output. --severity BLOCKER}",
            "  {note|(repeatable) narrows }{action|issues}{note|; --browse opens it as a screen}",
            "  {note|you can move around, which needs a terminal.}",
        ]
        return lines
    }

    /// First contact: nothing installed yet.
    ///
    /// ⚠ A different sentence from the one a person who mistyped a verb gets.
    /// Bare `oilbird` used to print usage and exit 2 whether you had used it
    /// for a year or had just downloaded it.
    public func welcomeScreen(rows: [WelcomeScreen.Item], total: String) -> [String] {
        let widest = rows.map { Self.width($0.id) }.max() ?? 0
        return banner() + [
            "",
            "  {bold|Oilbird runs SonarQube privately on this Mac.}",
            "",
            "  {body|Nothing is installed yet. Oilbird needs four things and will fetch them}",
            "  {body|itself — you do not need Java, PostgreSQL or Docker.}",
            "",
        ]
            + rows.map { row in
                "    {note|" + pad(row.id, to: widest + 3) + pad(row.size, to: 11) + row.what + "}"
            }
            + [
                "",
                "  {bold|" + total + "}{note|, once, resumable. Each is checked against a "
                    + "pinned SHA-256}",
                "  {note|before it is unpacked. None of your code leaves this machine.}",
                "",
                "  Set it up now?  {action|oilbird up}",
                "  See the list first?  {action|oilbird version}",
                "",
                "  {note|Already set up and seeing this? The container moved — }"
                    + "{action|oilbird doctor}{note| says where it looked.}",
            ]
    }

    /// One `doctor` row: the status token, the dependency, what it found.
    ///
    /// ⚠ The token is FIXED WIDTH and the message starts at the same column on
    /// every row, including rows whose token is shorter. The eye locks onto a
    /// straight edge; it cannot lock onto a ragged one. And severity is
    /// carried by CASE as well as by colour — `FAIL` shouts, `ok` does not —
    /// which survives `NO_COLOR`, a monochrome terminal and a screenshot
    /// pasted into Slack.
    public func statusRow(_ token: String, _ role: Role, _ subject: String, _ detail: String)
        -> String
    {
        let head = pad("  {\(role.rawValue)|" + token + "}", to: Self.gutter)
        guard !detail.isEmpty else { return head + "{body|" + subject + "}" }
        // ⚠ At LEAST two cells between subject and detail, whatever the
        // width. Padded to a flat 14 it prints `Starting the database0s`, the
        // defect `table`'s gutter exists to prevent.
        let body = "{body|" + subject + "}"
        return head + pad(body, to: max(14, cells(body) + 2)) + "{note|" + detail + "}"
    }

    /// The column every message in a status report starts at: two of indent,
    /// four for the widest token (`FAIL`, `wait`, `done`, `none`), two of gap.
    ///
    /// ⚠ A constant rather than a number written at each call site, because it
    /// is shared by the row and by the continuation UNDER the row — and the
    /// whole point of the hanging indent is that the two agree.
    public static let gutter = 8

    /// The engine, on one line, under the wordmark when there is one to draw.
    ///
    /// ⚠ The mark is decoration: `mark()` is nil without a terminal and the line
    /// then begins with the state word. Not a plainer wordmark — none.
    ///
    /// ⚠ **And the decoration is what goes when the line does not fit.** At a
    /// terminal `status` measured 103 cells against a 96-column measure — the
    /// mark, four facts and three separators — and every terminal narrower than
    /// that wrapped it wherever it happened to land. Through a pipe the same line
    /// was 89 and fine, which is why nothing noticed: the overflow existed only
    /// on the surface that has a width.
    public func engineLine(_ word: String, detail: [String]) -> [String] {
        // An empty note token leaves three painted spaces on the end of the line,
        // which `line()` cannot trim because the reset escape comes after them.
        guard !detail.isEmpty else {
            return ["  " + (mark().map { $0 + "{note|   }" } ?? "") + word]
        }
        let tail = "{note|   " + detail.joined(separator: "   ·   ") + "}"
        let plain = "  " + word + tail
        // The facts are the answer and the mark is not, so the mark is dropped
        // first — and only then, because on a wide enough terminal both fit.
        if let mark = mark() {
            let withMark = "  " + mark + "{note|   }" + word + tail
            if cells(withMark) <= measure { return [withMark] }
        }
        guard cells(plain) > measure else { return [plain] }
        // ⚠ Wrapped to a hanging indent, never truncated: which fact a reader
        // wanted is not ours to guess, and letting the terminal fold breaks
        // `127.0.0.1:50296`. No leading indent, or `wrap` doubles it.
        return wrap(word + tail, hanging: 2)
    }

    /// What is set on one project, and what is not.
    ///
    /// ⚠ Absent is said, not omitted. A settings screen that shows only what
    /// has been chosen leaves the reader unable to tell "no tags" from "tags
    /// are a thing Oilbird cannot do" — and the second is what this screen
    /// existed to fix.
    ///
    /// ⚠ The new-code rule says whether it is INHERITED. A project sitting
    /// under the instance default and a project explicitly set to the same
    /// rule are different facts, and showing them identically claims a
    /// choice nobody made — which is exactly how a failed new-code gate was
    /// once misdiagnosed.
    /// The API, as the server groups it.
    ///
    /// ⚠ Every word here comes off `api/webservices/list` — the service
    /// names, the descriptions, the counts. Nothing is written down, so a
    /// SonarQube that adds a service shows it without a release of Oilbird,
    /// and one that drops a service stops showing it without a stale row.
    public func servicesScreen(_ catalogue: APICatalogue) -> [String] {
        let services = catalogue.services
        let writes = catalogue.endpoints.filter(\.post).count
        return [
            "  {bold|\(catalogue.endpoints.count) calls}{note|   across \(services.count) "
                + "services, \(writes) of them writes}",
            "",
        ]
            + table(
                headers: ["", "", ""],
                rows: services.map {
                    [
                        "{body|" + $0.short + "}", "{note|\($0.endpoints)}",
                        "{note|" + $0.about + "}",
                    ]
                }
            ).dropFirst()
            + [
                "",
                "  {note|This is what this server says it has. Not all of it can work here "
                    + "— one machine, one user, Community Build — and the ones that cannot "
                    + "will say so in their own words.}",
                "",
            ]
            + offers([
                ("oilbird api rules", "one service"),
                ("oilbird api rules/create", "what one call takes"),
                ("oilbird api find custom rule", "search all of them"),
            ])
    }

    /// A set of endpoints, grouped by the service they belong to.
    public func endpointsScreen(
        _ endpoints: [APICatalogue.Endpoint], titled title: String, about: String = ""
    ) -> [String] {
        guard !endpoints.isEmpty else {
            return [
                "  {attn|none}{body|  nothing \(title).}",
                "      {action|oilbird api}{note|  the areas}",
            ]
        }
        var lines = ["  {bold|" + title + "}"]
        if !about.isEmpty { lines.append("  {note|" + about + "}") }
        lines.append("")
        // Grouped, because a flat list of sixty paths is a wall. The service
        // is the natural heading and it is already in the path.
        let grouped = Dictionary(grouping: endpoints, by: \.service).sorted { $0.key < $1.key }
        for (service, group) in grouped {
            lines.append("  {note|" + service + "}")
            lines += table(
                headers: ["", "", ""],
                rows: group.sorted { $0.path < $1.path }.map { endpoint in
                    [
                        "{body|"
                            + endpoint.path.replacingOccurrences(of: "api/", with: "") + "}",
                        endpoint.post ? "{attn|writes}" : "{note|reads}",
                        "{note|" + endpoint.summary + "}",
                    ]
                }
            ).dropFirst()
            lines.append("")
        }
        return lines + [
            "  {note|Any of them: }{action|oilbird api <call>}{note| to see what it takes, "
                + "then add }{action|key=value}{note| to run it.}"
        ]
    }

    /// One endpoint, as a thing you could call in the next line.
    ///
    /// ⚠ Ends in a runnable example built from the endpoint's OWN required
    /// parameters, not in a list of them. A
    /// screen that describes a capability without showing the way to use it
    /// makes the reader assemble the command, and they assemble it wrong.
    public func endpointScreen(_ endpoint: APICatalogue.Endpoint) -> [String] {
        var lines = [
            "  {bold|" + endpoint.path + "}"
                + (endpoint.post ? "   {attn|writes}" : "   {note|reads}"),
            "",
        ]
        if !endpoint.summary.isEmpty {
            lines += ["  {note|" + endpoint.summary + "}", ""]
        }
        if endpoint.unsupported {
            lines += [
                "  {attn|unsupported}{note|  SonarSource marks this one internal: it is "
                    + "undocumented and may change between versions.}",
                "",
            ]
        }
        if endpoint.parameters.isEmpty {
            lines.append("  {note|It takes no parameters.}")
        } else {
            let rows = endpoint.parameters.map { parameter -> [String] in
                var says = parameter.description
                if !parameter.possibleValues.isEmpty {
                    let shown = parameter.possibleValues.prefix(8)
                    says =
                        "one of: " + shown.joined(separator: ", ")
                        + (parameter.possibleValues.count > 8 ? ", …" : "")
                }
                return [
                    "{body|" + parameter.key + "}",
                    parameter.required ? "{attn|required}" : "{note|optional}",
                    "{note|" + says + "}",
                ]
            }
            lines += table(headers: ["parameter", "", ""], rows: rows)
        }
        let example =
            endpoint.required
            .map { parameter in
                let value =
                    parameter.example ?? parameter.possibleValues.first
                    ?? "<\(parameter.description.isEmpty ? parameter.key : parameter.description)>"
                return "\(parameter.key)=\(value)"
            }
            .joined(separator: " ")
        return lines + [
            "",
            "  {note|Call it:}",
        ]
            + offers([
                (
                    "oilbird api \(endpoint.path.replacingOccurrences(of: "api/", with: ""))"
                        + (example.isEmpty ? "" : " " + example),
                    example.isEmpty ? "as it stands" : "with what it requires"
                )
            ])
    }

    public func configurationScreen(_ configuration: Oilbird.Configuration) -> [String] {
        var rows: [[String]] = []
        rows.append([
            "{note|name}",
            configuration.chosenName.map { "{body|" + $0 + "}{note|   at the next scan}" }
                ?? "{note|after its directory}",
        ])
        rows.append([
            "{note|tags}",
            configuration.tags.isEmpty
                ? "{note|none}" : "{body|" + configuration.tags.joined(separator: ", ") + "}",
        ])
        rows.append([
            "{note|new code}",
            configuration.newCode.map {
                "{body|" + $0 + "}"
                    + (configuration.newCodeInherited ? "{note|   inherited}" : "")
            } ?? "{note|the server's default}",
        ])
        rows.append([
            "{note|branch}",
            configuration.branch.map { "{body|" + $0 + "}" } ?? "{note|not analysed yet}",
        ])
        rows.append([
            "{note|excluded}",
            configuration.exclusions.isEmpty
                ? "{note|nothing beyond the global list}"
                : "{body|" + configuration.exclusions.joined(separator: ", ") + "}",
        ])
        return ["  {bold|" + configuration.project + "}", ""]
            + table(
                headers: ["", ""], rows: rows
            ).dropFirst()
            + [
                "",
                "  {note|Set any of them:}",
            ]
            + offers([
                (
                    "oilbird configure \(configuration.project) --name \"A Name\"",
                    "what it is called"
                ),
                ("oilbird configure \(configuration.project) --tags a,b", "how you group it"),
                (
                    "oilbird configure \(configuration.project) --new-code 30",
                    "days, or `previous`"
                ),
                (
                    "oilbird configure \(configuration.project) --exclude \"**/gen/**\"",
                    "paths this project never analyses"
                ),
                (
                    "oilbird configure \(configuration.project) --branch master",
                    "what the one branch is called"
                ),
            ])
    }

    /// A list of "here is a command, here is what it does", aligned and
    /// wrapped.
    ///
    /// ⚠ The gap is COMPUTED and the description WRAPS. Typed by hand to fit
    /// 96 columns, these lines ran past an 80-column terminal — the fourth
    /// hand-padding miscount in this repository, and the second one the
    /// `screens` check caught rather than a person.
    public func offers(_ rows: [(command: String, what: String)]) -> [String] {
        let widest = rows.map { cells($0.command) }.max() ?? 0
        let column = widest + 5
        return rows.flatMap { row -> [String] in
            let head = "  {action|" + row.command + "}"
            // ⚠ No measure means a PIPE, which gets one line with the gap
            // padded. Falling through to the narrow branch applies a layout
            // invented for 40 columns to something with no width at all.
            guard measure > 0 else {
                return [pad(head, to: column) + "{note|" + row.what + "}"]
            }
            guard measure > column + 12 else {
                // Too narrow to sit them side by side: the command on its
                // own line, and what it does under it, rather than a column
                // squeezed to nothing.
                return [head] + wrap("{note|" + row.what + "}", hanging: 4)
            }
            let lines = wrap("{note|" + row.what + "}", hanging: column)
            guard let first = lines.first else { return [head] }
            // The first line joins the command; the rest hang under it.
            return [pad(head, to: column) + first.trimmingCharacters(in: .whitespaces)]
                + lines.dropFirst()
        }
    }

    /// A continuation under a status row, indented to the message column.
    ///
    /// ⚠ The markup is passed through, NOT wrapped in `{body|…}`. It was, and
    /// the wrapper swallowed any role a caller had already put inside it: the
    /// parser closes a token at the first `}`, so `{body|… {note|rule}}` ended
    /// at the inner brace and the outer one leaked onto the screen. Plain text
    /// needs no wrapper anyway — the default role IS body.
    /// ⚠ **It indented its first line TWICE.** `wrap` puts the hanging indent
    /// on every line it returns, the first included, and this added another
    /// gutter on top — sixteen spaces under a rule that says eight, and a
    /// first line of 102 cells against a 96-column measure. On every error
    /// screen in the product, and invisible because the SECOND line was right
    /// and the eye reads the pair as deliberate.
    public func statusDetail(_ markup: String) -> [String] {
        wrap(markup, hanging: Self.gutter)
    }

    /// `error: <what happened>`, and then what to do about it.
    ///
    /// ⚠ Today's equivalent is `oilbird: The scan did not finish.  → Show
    /// log`, which names no command — and "Show log" is not one. A useful
    /// error says what is missing, where it looked, what that means, and the
    /// literal command that fixes it, which is the whole difference between
    /// an error and a dead end.
    public func errorScreen(_ what: String, then advice: [String] = [], exit note: String = "")
        -> [String]
    {
        var lines = wrap("{bad|error}{note|: }{body|" + what + "}", hanging: 2)
            .map { $0.hasPrefix(" ") ? $0 : "  " + $0 }
        if !advice.isEmpty { lines += [""] + advice }
        // ⚠ Wrapped like everything else. It was one long line and the
        // sentence about exit codes ran to 122 cells — a footnote about
        // reading the output that itself did not fit in the window.
        if !note.isEmpty {
            lines +=
                [""]
                + wrap("{note|" + note + "}", hanging: 2)
                .map { $0.hasPrefix(" ") ? $0 : "  " + $0 }
        }
        return lines
    }

    /// The engine is not running, and that is the product working.
    ///
    /// ⚠ The most common failure in the tool, because the engine stops itself
    /// by design. Today it is `Oilbird is not running. → Start it`.
    ///
    /// ⚠ It states the RULE rather than claiming a cause. The lock the state
    /// is derived from carries no reason across processes, so no surface can
    /// honestly say whether the watchdog stopped it or the user pressed Pause
    /// thirty seconds ago — the same finding as `EngineState.heading`.
    public func pausedScreen(retrying command: String, idle: String) -> [String] {
        [
            "  {attn|paused}{note|: }{body|the analysis engine is not running}",
            "",
            "  {body|Oilbird stops it " + idle + " and gives back about 1.6 GB.}",
            "  {body|Your results are all still here — reading them needs it running again.}",
            "",
            "  {body|Start it and ask again:}",
            "      {action|oilbird up && " + command + "}",
            "",
            "  {body|Or stop it stopping:}",
            "      {action|oilbird idle never}",
            "",
            "  {note|exit 1. }{action|oilbird status}{note| answers without starting anything, "
                + "and so do }{action|doctor}{note| and }{action|version}{note|.}",
        ]
    }

    /// A scan that finished and read nothing.
    ///
    /// ⚠ Exit 3, not 0. The scan succeeded and it measured nothing, and a CI
    /// step that treats that as a pass is the whole problem: a dot-prefixed
    /// checkout analysed `gate OK`, exit 0 — identical to clean code — while a
    /// byte-identical copy one directory up reported a CRITICAL.
    /// - Parameter reason: why nothing was read, which already carries the way
    ///   out for the case that has one. ⚠ There was a separate `retry` line
    ///   under it and it said the same thing twice — "Scan the folder from a
    ///   non-hidden path" immediately followed by "Scan it from a path that is
    ///   not hidden". One sentence, from the one place that knows which of the
    ///   four reasons this is.
    public func readNothingScreen(_ path: String, because reason: String) -> [String] {
        [
            "  {attn|read nothing}{note|: }{body|" + path + "}",
            "",
            "  {body|The scan finished and analysed no source at all — 0 files, 0 lines.}",
            "  {body|Any issue count, measure or gate for this project describes nothing.}",
            "",
        ]
            + wrap("{body|" + reason + "}", hanging: 2).map { $0.hasPrefix(" ") ? $0 : "  " + $0 }
            + [
                "",
                "  {note|exit 3. The other ways to read nothing: the directory is empty, it}",
                "  {note|holds no language this SonarQube analyses, or everything in it was}",
                "  {note|excluded — }{action|oilbird scans}{note| shows which.}",
            ]
    }
}

// MARK: - the report grammar

/// The vocabulary a verdict is said in: which token, which case, which colour.
///
/// ⚠ In Kit and not in the CLI because it is a rule rather than a rendering,
/// and because an executable target cannot be `@testable import`-ed — the
/// severity mapping is exactly the kind of thing that drifts between two
/// surfaces saying the same word differently.
extension UI {
    /// A finished scan's verdict, painted by which of the three it is.
    ///
    /// ⚠ `read nothing` is its own word and its own colour. A gate that failed
    /// and a scan that read nothing would otherwise both say FAILED, and only
    /// one of them has a codebase to fix.
    public func verdictCell(_ verdict: String) -> String {
        switch verdict {
        case "OK": "{good|OK}"
        case "FAILED": "{bad|FAILED}"
        default: "{attn|" + verdict + "}"
        }
    }

    /// A severity, as the painted token it is.
    ///
    /// ⚠ Kept UPPER CASE, which is the second channel: severity survives
    /// `NO_COLOR`, a monochrome terminal and a screenshot because the word
    /// itself shouts. `INFO` and `MINOR` are dim — they are the rows a reader
    /// may skip.
    public func severityToken(_ severity: String) -> String {
        "{" + Self.severityRole(severity) + "|" + severity + "}"
    }

    /// ⚠ Both vocabularies. An MQR server answers HIGH / MEDIUM / LOW where
    /// a standard one answers CRITICAL / MAJOR / MINOR, and a switch that
    /// knew only the second painted every MQR severity dim — including the
    /// 186 the dashboard beside it was showing in red.
    ///
    /// ⚠ An unknown word is `body` and not `note`. `note` is the role for text
    /// the reader may SKIP, so a severity SonarQube added after this build
    /// would have been painted as the least important thing on the screen,
    /// which is the opposite of what nobody knowing the word should mean. The
    /// `severities` check is the other half: it asks the running server for
    /// its own vocabulary and fails if a word here is missing from it, or one
    /// of its words is missing here.
    static func severityRole(_ severity: String) -> String {
        switch severity.uppercased() {
        case "BLOCKER", "CRITICAL", "HIGH": "bad"
        case "MAJOR", "MEDIUM": "attn"
        case "MINOR", "LOW", "INFO": "note"
        default: "body"
        }
    }

    /// SonarQube's letter rating, from the number it reports it as.
    ///
    /// ⚠ `1.0` through `5.0`, not `A` through `E` — the API answers with a
    /// double and every surface that shows a letter converts it. Absent is
    /// an em dash rather than an `A`: a project nothing has rated and a
    /// project rated best are not the same thing, and defaulting to the good
    /// news is how a scan that read nothing came to look clean.
    public func ratingCell(_ value: String?) -> String {
        // ⚠ The letter comes from `Oilbird.ratingLetter`, which MCP uses too.
        // Converted separately on each surface it is a conversion that will
        // disagree once, in one of them, silently.
        guard let letter = Oilbird.ratingLetter(value) else { return "{note|\u{2014}}" }
        let role =
            switch letter {
            case "A", "B": "good"
            case "C": "attn"
            default: "bad"
            }
        return "{" + role + "|" + letter + "}"
    }

    /// A severity count, dim at zero.
    ///
    /// ⚠ Zero is the good news and is not worth paint. A red `0` is the kind
    /// of colour that makes colour stop meaning anything.
    public func severityCell(_ key: String, _ count: Int) -> String {
        guard count > 0 else { return "{note|0}" }
        // ⚠ The same three roles as the token: a count that shouts where its
        // label whispers is worse than no colour, and 874 MINORs in red says
        // the codebase is on fire.
        return "{" + Self.severityRole(key) + "|" + grouped("\(count)") + "}"
    }

    /// A count with thousands separated, because `1559` and `15590` are the
    /// same shape at a glance and `1,559` and `15,590` are not.
    public func grouped(_ value: String) -> String {
        // ⚠ Hand-grouped, never `NumberFormatter`: its grouping is LOCALE dependent
        // (`1.559` in de_DE) and this number sits beside a comma-grouped one from
        // SonarQube's own page.
        guard let number = Int(value), abs(number) >= 1000 else { return value }
        var digits = Array(String(abs(number)))
        var out = ""
        while digits.count > 3 {
            out = "," + String(digits.suffix(3)) + out
            digits.removeLast(3)
        }
        return (number < 0 ? "-" : "") + String(digits) + out
    }

    /// SonarQube's metric keys in the words its own dashboard uses.
    ///
    /// `new_coverage` is not a sentence, and the reader is looking at the same
    /// figure the web page shows them under a different name.
    public func metricLabel(_ key: String) -> String {
        switch key {
        case "new_coverage": "coverage on new code"
        case "new_violations": "new issues"
        case "new_duplicated_lines_density": "duplication on new code"
        case "new_security_hotspots_reviewed": "hotspots reviewed on new code"
        case "coverage": "coverage"
        case "duplicated_lines_density": "duplication"
        default: key.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// A gate condition, as one status row.
    ///
    /// ⚠ The colour paints the FIGURE, never the sentence. A whole red line
    /// makes severity a property of prose rather than of a column the eye runs
    /// down — and `0.0%` against `required 80.0%` is the part a reader is
    /// looking for.
    public func conditionRow(_ condition: SonarAPI.GateResult.Condition) -> String {
        let bad = condition.status == "ERROR"
        let actual = condition.actualValue ?? "?"
        let limit = condition.errorThreshold ?? "?"
        return statusRow(
            bad ? "FAIL" : "ok", bad ? .bad : .good, metricLabel(condition.metricKey), "")
            + "  {" + (bad ? "bad" : "note") + "|" + actual + "}{note| — required " + limit + "}"
    }

    /// The flagship read verb: how is this code, and what should I fix first?
    ///
    /// ⚠ It carries a defect this design refuses to keep hiding. The server
    /// runs in MQR mode and Oilbird asks for the legacy metric family, so a
    /// project the window rates D for reliability reported `0 bugs`. The rows
    /// below are the ones the server actually answered with — the severity
    /// facets and the measures it returned — rather than a fixed list of
    /// legacy names that come back empty and read as zero.
    public func summaryScreen(_ summary: Oilbird.Summary) -> [String] {
        let size = summary.measures["ncloc"].map { grouped($0) + " lines" }
        var lines = [
            "  {bold|" + summary.project + "}" + (size.map { "{note|   " + $0 + "}" } ?? ""), "",
        ]
        // ⚠ A gate that judged nothing is NOT a pass, and neither is one whose
        // analysis read nothing. Printing `OK` for either is how
        // `oilbird gate $KEY && deploy` deploys anything for ever.
        if summary.gate.judgedNothing {
            lines.append(
                statusRow("none", .attn, "quality gate", "")
                    + "{note|   nothing was checked — no baseline yet}")
        } else {
            let bad = summary.gate.gate == .error || !summary.gate.gate.isRecognised
            lines.append(
                statusRow(bad ? "FAILED" : "OK", bad ? .bad : .good, "quality gate", "")
                    + "{note|   \(summary.gate.failed.count) of "
                    + Self.counted(summary.gate.conditions.count, "condition") + "}")
            lines += summary.gate.failed.map(conditionRow)
        }
        lines.append("")

        // Two halves side by side: what the analysis FOUND and what it
        // MEASURED. Counts and percentages read differently, and one column
        // makes the reader sort them out on every row.
        let families =
            summary.taxonomy == .mqr
            ? [
                ("security", "SECURITY", "security_rating"),
                ("reliability", "RELIABILITY", "reliability_rating"),
                ("maintainability", "MAINTAINABILITY", "sqale_rating"),
            ]
            : [
                ("security", "VULNERABILITY", "security_rating"),
                ("reliability", "BUG", "reliability_rating"),
                ("maintainability", "CODE_SMELL", "sqale_rating"),
            ]
        let measures = [
            ("coverage", "coverage", "%"), ("duplicated_lines_density", "duplication", "%"),
            ("sqale_index", "debt", " min"), ("cognitive_complexity", "complexity", ""),
        ]
        var rows: [[String]] = []
        for index in 0..<max(families.count + 1, measures.count) {
            var row = ["", "", "", "", "", ""]
            if index < families.count {
                let (label, family, ratingKey) = families[index]
                row[0] = "{note|" + label + "}"
                row[1] = ratingCell(summary.measures[ratingKey])
                row[2] =
                    summary.types[family].map { "{body|" + grouped("\($0)") + "}" }
                    ?? "{note|—}"
            } else if index == families.count {
                // ⚠ Hotspots are never a count of problems. SonarQube reports
                // how many need REVIEWING, and printing the number beside
                // three issue counts reads as "and this many more bugs".
                row[0] = "{note|hotspots}"
                row[1] = ratingCell(summary.measures["security_review_rating"])
                row[2] =
                    summary.measures["security_hotspots"]
                    .map { "{note|" + grouped($0) + " to review}" } ?? "{note|—}"
            }
            if index < measures.count {
                let (key, label, suffix) = measures[index]
                row[4] = "{note|" + label + "}"
                row[5] =
                    summary.measures[key].map { "{body|" + grouped($0) + suffix + "}" }
                    ?? "{note|—}"
            }
            rows.append(row)
        }
        lines += table(
            headers: ["", "rating", "issues", "", "measure", ""], rows: rows,
            align: [.left, .left, .right, .left, .left, .right])

        // The severities, on one line: the answer to "what do I fix first" is
        // an ordering, and an ordering is read across rather than down.
        let order = summary.taxonomy.severities
        let severities =
            order
            .map { key in
                "{note|" + key.lowercased() + " }"
                    + severityCell(key, summary.severities[key] ?? 0)
            }
            .joined(separator: "{note|   ·   }")
        lines += [
            "",
            "  {bold|" + grouped("\(summary.total)") + " "
                + (summary.total == 1 ? "issue" : "issues") + "}{note|   }" + severities,
        ]
        // ⚠ The worst severity that HAS issues, and no offer when there are
        // none. Fixed at BLOCKER it answers "no issues at BLOCKER" one line
        // after printing the counts that disprove it.
        if let worst = order.first(where: { (summary.severities[$0] ?? 0) > 0 }) {
            lines.append(
                "      {action|oilbird issues " + summary.project + " --severity " + worst + "}")
        }
        // ⚠ The parts do not always sum to the whole: this facet counts
        // IMPACTS, and under MQR one issue can be both a MEDIUM security and a
        // LOW maintainability problem. Said out loud only when it is true.
        let counted = order.reduce(0) { $0 + (summary.severities[$1] ?? 0) }
        if counted > summary.total {
            lines.append(
                "      {note|" + grouped("\(counted)") + " counts over "
                    + grouped("\(summary.total)")
                    + " issues \u{2014} one that harms two things is counted under each.}")
        }
        return lines
    }
}

// MARK: - the menu

extension UI {
    /// One row of the menu: what it is called, and WHEN you would want it.
    ///
    /// ⚠ "When you would want it" is the question a menu answers and a help
    /// listing does not, which is why the blurb is not the help text.
    public struct MenuRow: Sendable, Equatable {
        /// The verb this row runs. ⚠ Held against the dispatching switch by
        /// the `parity` check exactly as `Usage.verbs` is — a menu kept by
        /// hand drifts out of step with its commands, and a human notices
        /// before a test does.
        public let verb: String
        public let label: String
        public let blurb: String
        /// Read verbs come back to the menu; doing verbs end.
        ///
        /// ⚠ Oilbird's verbs mostly READ rather than DO things and end, so
        /// dropping the reader at a prompt to retype the next one is the
        /// wrong shape.
        public let returns: Bool

        public init(verb: String, label: String, blurb: String, returns: Bool) {
            self.verb = verb
            self.label = label
            self.blurb = blurb
            self.returns = returns
        }
    }

    /// What bare `oilbird` offers, in the order you meet them.
    ///
    /// Typing the bare command gives a choice of what to execute, instead of
    /// just printing help.
    public static func menuRows(scanning here: String) -> [MenuRow] {
        [
            MenuRow(
                verb: "scan", label: "scan this directory", blurb: here, returns: false),
            MenuRow(
                verb: "issues", label: "issues",
                blurb: "what the last scan found, for one project", returns: true),
            MenuRow(
                verb: "summary", label: "summary",
                blurb: "gate, measures and counts, for one project", returns: true),
            MenuRow(
                verb: "history", label: "history",
                blurb: "how a project changed, analysis by analysis", returns: true),
            MenuRow(
                verb: "projects", label: "projects", blurb: "everything scanned so far",
                returns: true),
            MenuRow(
                verb: "scans", label: "scans", blurb: "what is running, and what has run",
                returns: true),
            MenuRow(
                verb: "down", label: "pause the engine",
                blurb: "gives back 1.6 GB; anything starts it again", returns: false),
            MenuRow(
                verb: "doctor", label: "doctor",
                blurb: "check every dependency by running it", returns: true),
            MenuRow(
                verb: "idle", label: "idle", blurb: "when the engine stops itself",
                returns: true),
            MenuRow(
                verb: "version", label: "version", blurb: "what this build pins", returns: true),
        ]
    }

    /// The menu, drawn.
    ///
    /// ⚠ Without a selection the menu offers no arrow keys: the rows are
    /// numbered and one line is read. Arrow keys (`↑↓ choose`) are offered
    /// only by `menuScreen(_:state:divider:selected:)`, when the terminal can
    /// be driven a key at a time. Every row is still a verb, which the footer
    /// says.
    public func menuScreen(_ rows: [MenuRow], state: String, divider: Int) -> [String] {
        menuScreen(rows, state: state, divider: divider, selected: nil)
    }

    /// The same, with one row chosen.
    ///
    /// ⚠ `selected` is nil where the terminal cannot be driven a key at a
    /// time, and then the screen is exactly what it always was: numbers, and
    /// a footer that offers only what works. A marker on a row nobody can
    /// move is worse than no marker — it looks like a selection and is a
    /// decoration.
    ///
    /// ⚠ A separate function and not a defaulted parameter, for the reason
    /// `ensureRunning(onPhase:)` carries: a default argument changes the
    /// mangled symbol of the function it is added to, and `swift build` does
    /// not reliably rebuild the test target afterwards.
    public func menuScreen(
        _ rows: [MenuRow], state: String, divider: Int, selected: Int?
    ) -> [String] {
        let head = mark().map { pad($0, to: 44) } ?? ""
        var lines = ["  " + head + "{note|" + state + "}", "", "  {body|What do you want to do?}", ""]
        let widest = rows.map { Self.width($0.label) }.max() ?? 0
        for (index, row) in rows.enumerated() {
            if index == divider, measure > 8 {
                lines.append("    {note|" + String(repeating: "─", count: measure - 8) + "}")
            }
            // ⚠ Built with `pad`, never by counting spaces: the number is one
            // or two characters, so a hand-counted gutter puts the tenth row a
            // cell left of the first. The marker is the same trap.
            let here = index == selected
            let marker = selected == nil ? "" : (here ? "{action|▸ }" : "  ")
            let number = "{action|" + String(format: "%2d", index + 1) + "}{note|.} "
            let label = (here ? "{action|" : "{body|") + row.label + "}"
            lines.append(
                "  " + pad(marker + number + label, to: widest + 8 + (selected == nil ? 0 : 2))
                    + "{note|" + row.blurb + "}")
        }
        // ⚠ The footer offers only what the terminal can do. "⏎ run" over a
        // screen with nothing selected is a key named in a legend that does
        // nothing, the cheapest way to make a UI feel broken.
        let keys =
            selected == nil
            ? "{action|1}{note|–}{action|" + String(rows.count) + "}{note| or a name   }"
                + "{action|⏎}{note| run   }{action|q}{note| quit}"
            : "{action|↑↓}{note| choose   }{action|⏎}{note| run   }"
                + "{action|1}{note|–}{action|" + String(rows.count) + "}{note| jump   }"
                + "{action|q}{note| quit}"
        lines += [
            "",
            "  " + keys + pad("", to: 6) + "{note|Every row is also a verb: }"
                + "{action|oilbird scan <path>}",
        ]
        return lines
    }
}
