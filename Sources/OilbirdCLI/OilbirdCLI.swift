import Foundation
import OilbirdKit
import OilbirdModel

// OilbirdCLI is composition only: argv in, an OilbirdKit call, a shape out.
// Every verb here exists on the facade, and none exists only here.

/// What the process exits with.
///
/// A published contract the moment a script depends on one (scripts and
/// agents branch on them), which is why these numbers may not move.
///
/// - `ok`: it worked.
/// - `failed`: the operation failed.
/// - `usage`: the command line was wrong.
/// - `unhealthy`: a dependency is missing or does not work.
/// - `gateFailed`: the analysis ran and the quality gate said no.
///
/// ⚠ `gateFailed` is its own code and not `failed`. `oilbird scan . && deploy`
/// must not deploy on a failed gate, and must not read a failed gate as a
/// broken scan either.
enum Exit: Int32 {
    case ok = 0, failed = 1, usage = 2, unhealthy = 3, gateFailed = 4
}

/// The design system, derived once from this process's streams.
///
/// ⚠ Derived, not chosen. Nothing below asks "am I in a terminal?" for
/// itself: every screen hands markup to `ui` and `ui` decides whether there is
/// anything to paint it with. That is what keeps a pipe byte-stable while a
/// terminal gets the layout.
let ui = UI.detect()

/// One line of markup, painted if there is a terminal to paint on.
///
/// Human output goes to stderr and machine output to stdout — so
/// `oilbird scan . --json | jq` works while a person still sees progress.
func show(_ markup: String) {
    say(ui.line(markup))
}

func show(_ markup: [String]) {
    for line in markup { show(line) }
}

/// ⚠ `json` is not optional-with-a-default by accident. This is the path
/// every usage error leaves by, and it used to write only to stderr — so
/// `oilbird gate --json | python3 -c 'json.load(sys.stdin)'` died on an
/// empty stdin rather than on a readable `{"cause":"usage"}`. A machine
/// surface that is machine-readable only when it succeeds is not one.
///
/// ⚠ The JSON is byte-for-byte what it always was. `--json` is a machine
/// contract that agents depend on, and the whole of this design lives on the
/// other stream for that reason.
/// ⚠ Still markup, and deliberately. This is synchronous and returns `Never`,
/// and the renderer is main-actor only: reaching it from here needs either an
/// `assumeIsolated` that TRAPS when this is called off the main actor, or an
/// `await` that `Never` cannot have. The error path is the worst possible
/// place to put a trap, so it keeps the one renderer that cannot fail.
func die(_ message: String, _ code: Exit, json: Bool) -> Never {
    if json { emit(["error": message + ".", "cause": "usage"]) }
    let columns = ui.columns
    let note =
        code == .usage
        ? "exit 2 — usage. A scan that starts and then fails exits 1, and a gate that fails "
            + "exits 4, so a script can tell the three apart." : ""
    if let frame = Frames.ifOnMain({ Frames.error(message, note: note, width: columns) }) {
        say(frame)
        exit(code.rawValue)
    }
    show(
        ui.errorScreen(
            message,
            exit: code == .usage
                ? "exit 2 — usage. A scan that starts and then fails exits 1, and a gate "
                    + "that fails exits 4, so a script can tell the three apart." : ""))
    exit(code.rawValue)
}

/// Why an analysis might have read nothing, for the directory it was given.
///
/// Guessing is better than silence here, and these four cover every case
/// reproduced so far. The last one is the trap: a folder whose name begins
/// with a dot is walked, and then every file under it is marked hidden by the
/// engine and skipped by every sensor — so `~/.dotfiles` analysed clean while
/// a byte-identical copy one directory up reported a CRITICAL.
func reasonNothingWasRead(_ path: URL) -> String {
    let manager = FileManager.default
    let contents = (try? manager.contentsOfDirectory(atPath: path.path)) ?? []
    if contents.isEmpty { return "\(path.lastPathComponent) is empty." }
    if path.lastPathComponent.hasPrefix(".") {
        return "SonarQube skips hidden files, and \(path.lastPathComponent) begins with a dot, "
            + "so everything inside it counted as hidden. Scan the folder from a "
            + "non-hidden path, or move the checkout."
    }
    return "Either \(path.lastPathComponent) holds no source in a language this SonarQube "
        + "analyses, or everything in it was excluded. `oilbird log` lists what the "
        + "scanner skipped and why."
}

/// What the animation says while a phase is in flight.
///
/// The search index names itself as the slow part. Twenty-five seconds under a
/// label that says nothing is indistinguishable from a hang; twenty-five
/// seconds under a label that says "usually about 25 seconds" is a wait.
func waitingLabel(_ phase: Oilbird.Phase) -> String {
    switch phase {
    case .waitingForServer(let status, let elapsed):
        "\(phase.label) — \(Int(elapsed))s so far (SonarQube says: \(status))"
    case .migratingDatabase(let status, let elapsed):
        "\(phase.label) — \(status), \(Oilbird.humanDuration(elapsed))"
    default:
        phase.label
    }
}

/// Bring the engine up for a verb that needs it, drawing the wait.
///
/// ⚠ This does not decide WHETHER the engine starts — `Oilbird.connected`
/// does, for every client — it decides only whether the fifteen seconds are
/// visible. Six read verbs used to fail outright against a paused engine
/// while `--help` promised they would start one; now they start it, and
/// without this they would do it in silence, which is the defect `doctor`
/// had and `up` was given a renderer to avoid.
///
/// Run before the verb, so the `ensureRunning` inside `connected` finds the
/// engine already up and short-circuits on a probe: one start, not two. And
/// silent when the engine is already running, because no phase ever fires.
func startEngineDrawing(json: Bool) async {
    let slot = UI.Slot(ui)
    let phases = UI.Phases(ui)
    do {
        _ = try await Oilbird.ensureRunning { phase in
            guard !json else { return }
            slot.clear()
            if let done = phases.advance(to: phase) { show(done) }
            slot.working(waitingLabel(phase))
        }
        slot.clear()
        if !json, let done = phases.close() { show(done) }
    } catch let error as Oilbird.Error {
        slot.clear()
        die(error, json: json)
    } catch {
        slot.clear()
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}

/// A count and its noun, agreeing.
///
/// "1 files, 3 lines" is what an unchecked interpolation reads like.
/// One implementation, in Kit, because the screens are there too.
func counted(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
    UI.counted(n, singular, plural)
}

/// An argument that is present and not blank, or a usage error.
///
/// ⚠ Every guard was a lower bound — `positional.count >= 2` — so an empty
/// string sailed through all six of them, and an empty string is not a
/// harmless nothing:
///
/// - `oilbird scan ''` resolves `URL(filePath: "")` to the process's own
///   working directory, which passes both the exists and is-a-directory
///   checks. It analysed a folder nobody named. Run from a CI checkout with
///   an unset variable, `oilbird scan "$PROJECT_DIR"` scans the runner.
///   Measured here: three and a half minutes chewing through `/tmp`.
/// - `oilbird issues ""` sends `componentKeys=`, which SonarQube ignores,
///   so it returned every issue on the server — 2,018 of them, from five
///   projects, reported under the empty key as though they were one
///   project's. The existence guard could not fire: it is conditioned on
///   the result being empty, and this input is the one that returns
///   everything.
///
/// Whitespace counts as blank. A shell that expands a variable to a space
/// is the same accident with a different quote.
func requireArgument(
    _ positional: [String], _ index: Int, verb: String, needs: String, json: Bool
) -> String {
    let given = positional.count > index ? positional[index] : ""
    if given.isEmpty && positional.count <= index {
        die("\(verb) needs \(needs)", .usage, json: json)
    }
    guard !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        // Said differently from "you gave none", because the two are
        // different mistakes: one is a forgotten argument, the other is
        // usually a variable that expanded to nothing.
        die("\(verb) needs \(needs), and an empty one is not one", .usage, json: json)
    }
    return given
}

/// The one way a failure leaves this tool.
///
/// It was eight copies of the same three lines, and every one of them dropped
/// `underlying` — so the exit code, the response body and the paths that had
/// been carefully assembled at the throw site went nowhere at all. One
/// function, and the log gets the diagnosis while the user gets the sentence
/// and the action.
func die(_ error: Oilbird.Error, json: Bool) -> Never {
    Oilbird.record(error)
    if json {
        // ⚠ `underlying` and `cause` both travel, or `--json` is the mode that
        // discards why it failed. `cause` so a script branches on a value and
        // not on a sentence a copy edit will change.
        emit([
            "error": error.detail, "action": error.recovery.actionLabel,
            "cause": error.cause.rawValue, "detail": error.underlying as Any,
        ])
    }
    // ⚠ A paused engine is not a fault, so it gets its own screen. Told apart
    // by `underlying`, the one string separating it from the nine other
    // `serverUnhealthy` throws, which are.
    if error.cause == .serverUnhealthy, error.underlying == "no running.json" {
        let retry = retryCommand()
        let idle = idlePhrase()
        let columns = ui.columns
        if let frame = Frames.ifOnMain({
            Frames.paused(retrying: retry, idle: idle, width: columns)
        }) {
            say(frame)
        } else {
            show(ui.pausedScreen(retrying: retry, idle: idle))
        }
        exit(Exit.failed.rawValue)
    }
    let detail = error.detail
    let action = error.recovery.actionLabel
    let width = ui.columns
    if let frame = Frames.ifOnMain({ Frames.error(detail, note: action, width: width) }) {
        say(frame)
        exit(Exit.failed.rawValue)
    }
    show(
        ui.errorScreen(
            error.detail,
            then: ui.wrap("{body|" + error.recovery.actionLabel + "}", hanging: 6)
                .map { "      " + $0 }))
    exit(Exit.failed.rawValue)
}

/// The command the reader just typed, so the recovery can offer to run it
/// again rather than describing it.
///
/// ⚠ No dead ends, in one line. "Start it" is not a command, and a recovery that names
/// no command is a dead end wearing a button.
func retryCommand() -> String {
    let parts = CommandLine.arguments.dropFirst().filter { $0 != "--json" }
    return (["oilbird"] + parts).joined(separator: " ")
}

/// The idle rule as a clause, read from the setting rather than written down.
///
/// ⚠ A stated RULE, never a claim about this particular stop. The lock the
/// paused state is derived from carries no reason across processes, so nothing
/// can honestly say whether the watchdog stopped it or the user pressed Pause
/// thirty seconds ago — the finding `EngineState.heading` already records.
/// One implementation, in Kit, because the menu bar says this too.
func idlePhrase() -> String { Oilbird.idlePhrase() }

/// Human output goes to stderr, machine output to stdout — so
/// `oilbird scan . --json | jq` works while a person still sees progress.
func say(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func emit(_ object: Any) {
    guard
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Bare `oilbird`, at a terminal: what would you like to do?
///
/// A command typed on its own should offer a choice of what to run rather
/// than just print help. Oilbird goes one step further, because its verbs
/// mostly READ rather than DO: a read comes back here instead of dropping you
/// at a prompt to retype the next one.
///
/// ⚠ **It runs each verb as a CHILD of this process rather than falling
/// through to the switch below.** That switch ends every case with `exit`,
/// which is right — a verb's exit code is a published contract — and a menu
/// that has to come back afterwards cannot use it. A child gets its own clean
/// process, its own exit code, and the same terminal, so the screen it paints
/// is exactly the screen `oilbird doctor` paints. The alternative was making
/// twenty cases return instead of exit, which is twenty chances to change an
/// exit code by accident.
///
/// ⚠ It never returns. Quitting exits 0; a verb that ends the session exits
/// with whatever the child exited with.
func menu() async -> Never {
    // Nothing installed is not a menu. Every row but one needs an engine that
    // does not exist yet, and offering nine of them to somebody who has just
    // downloaded this is a list of ways to wait fifteen minutes.
    if case .notInstalled = await Oilbird.engineState() { welcome() }
    let rows = UI.menuRows(scanning: Oilbird.displayPath(FileManager.default.currentDirectoryPath))
    // Where the reading half ends and the acting half begins, so the divider
    // is drawn from the data rather than from a counted index that a new row
    // would silently move.
    let divider = rows.firstIndex { !$0.returns && $0.verb != "scan" } ?? rows.count
    guard let keyboard = UI.Keyboard() else { await typedMenu(rows, divider: divider) }
    await chosenMenu(rows, divider: divider, keyboard: keyboard)
}

/// The menu a key at a time: `↑↓` move, `⏎` runs, a digit jumps.
///
/// ⚠ It repaints IN PLACE. Printing the menu again under itself is what the
/// first version did, and with a selection that moves on every keystroke it
/// fills the scrollback with twenty copies of the same screen in a second.
func chosenMenu(_ rows: [UI.MenuRow], divider: Int, keyboard: UI.Keyboard) async -> Never {
    var selected = 0
    var jumped = ""
    var painted = 0
    while true {
        let screen = ui.menuScreen(
            rows, state: await menuState(), divider: divider, selected: selected)
        ui.rewind(painted)
        show(screen)
        painted = screen.count
        keyboard.raise()
        let key = keyboard.next()
        keyboard.restore()
        switch key {
        case .eof, .quit: exit(Exit.ok.rawValue)
        case .up: selected = (selected + rows.count - 1) % rows.count
        case .down: selected = (selected + 1) % rows.count
        case .digit(let digit):
            // ⚠ Accumulated, so row 10 is reachable — and the selection
            // moves on every digit, so there is no hidden state: `1` selects
            // the first row and `0` after it selects the tenth.
            jumped += String(digit)
            if let row = Int(jumped), rows.indices.contains(row - 1) {
                selected = row - 1
            } else if let row = Int(String(digit)), rows.indices.contains(row - 1) {
                jumped = String(digit)
                selected = row - 1
            } else {
                jumped = ""
            }
            continue
        case .letter(let letter):
            // Type-ahead, the way a list of files answers a keypress.
            if let found = rows.firstIndex(where: { $0.verb.hasPrefix(String(letter)) }) {
                selected = found
            }
        case .tab: selected = (selected + 1) % rows.count
        case .enter:
            // ⚠ The chosen frame is LEFT standing, marker and all. Repainting
            // it unselected first puts the typed menu's legend above output
            // that is not a menu.
            let row = rows[selected]
            painted = 0
            show([""])
            let code = await runChosen(row)
            // ⚠ A doing verb ENDS, a reading verb comes back. Pausing the
            // engine and then being shown a menu that still says "running"
            // is the drift this rule exists to stop.
            if !row.returns { exit(code) }
            show([""])
        case .escape, .backspace, .slash, .other: break
        }
        if case .digit = key {} else { jumped = "" }
    }
}

/// The menu a line at a time, where the terminal cannot be read a key at a
/// time. Numbers and names, and a footer that offers nothing else.
func typedMenu(_ rows: [UI.MenuRow], divider: Int) async -> Never {
    while true {
        show(ui.menuScreen(rows, state: await menuState(), divider: divider))
        FileHandle.standardError.write(Data("\n  ".utf8))
        guard let typed = readLine(strippingNewline: true) else {
            // End of input. Not an error and not a hang: somebody closed the
            // terminal, or a wrapper that looked interactive was not.
            exit(Exit.ok.rawValue)
        }
        let answer = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if answer.isEmpty { continue }
        if answer == "q" || answer == "quit" || answer == "exit" { exit(Exit.ok.rawValue) }
        guard let row = choose(answer, from: rows) else {
            show(["", "  {bad|?}     {body|" + typed + " is not one of these.}", ""])
            continue
        }
        let code = await runChosen(row)
        if !row.returns { exit(code) }
        show([""])
    }
}

/// Choose a project from the ones there are.
///
/// ⚠ It asks the engine, which means starting it if it is paused — and that
/// is the honest cost: there is no list without a server, and a picker that
/// offered a remembered one would offer projects that may have been deleted
/// since. The wait is drawn, like every other start.
func pickProject(for verb: String) async -> String? {
    await startEngineDrawing(json: false)
    let found = (try? await Oilbird.projects()) ?? []
    guard !found.isEmpty else {
        show([
            "",
            "  {attn|none}{body|  nothing has been scanned yet, so there is nothing to "
                + "look at.}",
            "",
        ])
        show(ui.offers([("oilbird scan <path>", "analyse a directory first")]))
        return nil
    }
    let rows = found.map { (value: $0.key, detail: $0.name == $0.key ? "" : $0.name) }
    // ⚠ A phrase per verb, not the verb interpolated into a sentence: that
    // asks "Which project would you like to summary?", and a menu that cannot
    // say what it will do is worse than no menu.
    let title =
        switch verb {
        case "issues": "Which project's issues?"
        case "summary": "Which project would you like a summary of?"
        case "history": "Which project's history?"
        default: "Which project?"
        }

    return await pick(title, rows: rows)
}

/// One menu, driven by the keyboard when there is one and by a typed answer
/// when there is not.
///
/// ⚠ Extracted from `pickProject` rather than written again beside it. The
/// API browser needs exactly this — a list, arrows, a letter to jump, `q` to
/// leave — and a second copy would be a second set of keys to keep level
/// with `UIKeys`.
func pick(_ title: String, rows: [(value: String, detail: String)]) async -> String? {
    guard !rows.isEmpty else { return nil }
    guard let keyboard = UI.Keyboard() else {
        // No keys a press at a time: numbers and names, and the list is
        // still ON SCREEN rather than a command away.
        show([""])
        show(ui.chooseScreen(title, rows: rows, selected: nil))
        FileHandle.standardError.write(Data("\n  ".utf8))
        guard
            let typed = readLine(strippingNewline: true)?
                .trimmingCharacters(in: .whitespaces), !typed.isEmpty, typed.lowercased() != "q"
        else { return nil }
        if let number = Int(typed), rows.indices.contains(number - 1) {
            return rows[number - 1].value
        }
        return rows.first { $0.value == typed }?.value ?? typed
    }

    var selected = 0
    var painted = 0
    show([""])
    while true {
        let screen = ui.chooseScreen(title, rows: rows, selected: selected)
        ui.rewind(painted)
        show(screen)
        painted = screen.count
        keyboard.raise()
        let key = keyboard.next()
        keyboard.restore()
        switch key {
        case .quit, .eof, .escape: return nil
        case .up: selected = (selected + rows.count - 1) % rows.count
        case .down: selected = (selected + 1) % rows.count
        case .tab: selected = (selected + 1) % rows.count
        case .enter: return rows[selected].value
        case .digit(let digit):
            if let number = Int(String(digit)), rows.indices.contains(number - 1) {
                selected = number - 1
            }
        case .letter(let letter):
            if let found = rows.firstIndex(where: { $0.value.lowercased().hasPrefix(String(letter)) }) {
                selected = found
            }
        case .slash, .backspace, .other: break
        }
    }
}

/// Fill in an endpoint's parameters from the menu, and say what was typed.
///
/// ⚠ **The picker used to stop at "here is what it takes".** You chose an area,
/// chose a call, read its parameters — and then had to retype the whole thing
/// as a command. That is the same defect as making someone type a project key
/// under a list of projects: the information needed to act was on screen and
/// the act was not offered.
///
/// So: an enumerated parameter is CHOSEN, never typed; one that names a
/// project offers the projects there are; everything else is asked for with
/// its own description as the hint. Optional parameters are offered, not
/// marched through — several endpoints have thirty.
func fill(_ endpoint: APICatalogue.Endpoint) async -> [String: String]? {
    var parameters: [String: String] = [:]

    for parameter in endpoint.required {
        guard let value = await value(for: parameter, of: endpoint) else { return nil }
        parameters[parameter.key] = value
    }

    // Then as many optional ones as wanted, and no more.
    let optional = endpoint.parameters.filter { !$0.required }
    while true {
        let command = commandFor(endpoint, parameters)
        show([""])
        show(["  {note|As it stands:}"])
        show(ui.offers([(command, "")]))
        var rows: [(value: String, detail: String)] = [
            (value: endpoint.post ? "run it" : "read it", detail: "send it to the server")
        ]
        if !optional.isEmpty, optional.contains(where: { parameters[$0.key] == nil }) {
            rows.append((value: "add a setting", detail: "narrow it, page it, change a default"))
        }
        rows.append((value: "cancel", detail: "change nothing"))
        guard let choice = await pick("Ready?", rows: rows), choice != "cancel" else {
            return nil
        }
        if choice == "add a setting" {
            let offered = optional.filter { parameters[$0.key] == nil }
                .map { (value: $0.key, detail: hint(for: $0)) }
            guard let key = await pick("Which setting?", rows: offered),
                let parameter = optional.first(where: { $0.key == key })
            else { continue }
            if let value = await value(for: parameter, of: endpoint) {
                parameters[parameter.key] = value
            }
            continue
        }
        return parameters
    }
}

/// One parameter's value: chosen where there is a set to choose from, and
/// typed only where there genuinely is not.
func value(for parameter: APICatalogue.Parameter, of endpoint: APICatalogue.Endpoint) async
    -> String?
{
    if !parameter.possibleValues.isEmpty {
        let rows = parameter.possibleValues.map { (value: $0, detail: "") }
        return await pick("\(parameter.key)?", rows: rows)
    }
    // ⚠ A parameter that names a project gets the project list. The keys are
    // hashed — `web-app-deaa` — so this is the one place where typing it from
    // memory is close to impossible.
    if namesAProject(parameter) {
        let found = (try? await Oilbird.projects()) ?? []
        if !found.isEmpty {
            let rows = found.map {
                (value: $0.key, detail: $0.name == $0.key ? "" : $0.name)
            }
            return await pick("Which project?", rows: rows)
        }
    }
    show([""])
    show([
        "  {body|" + parameter.key + "}"
            + (parameter.required ? "  {attn|required}" : "  {note|optional}"),
        "  {note|" + hint(for: parameter) + "}",
    ])
    FileHandle.standardError.write(Data("\n  ".utf8))
    guard let typed = readLine(strippingNewline: true), !typed.isEmpty else { return nil }
    return typed
}

/// Whether a parameter is asking for a project key.
///
/// ⚠ Read off the parameter's OWN description — "Project key" — rather than a
/// list of parameter names kept here. The list was `project`, `projectKey`,
/// `component`, `componentKey`, `componentKeys`, `projects`, which is six
/// guesses about 302 endpoints and six things to be wrong about when SonarQube
/// renames one. The server labels them; this reads the label.
func namesAProject(_ parameter: APICatalogue.Parameter) -> Bool {
    let said = parameter.description.lowercased()
    return said.hasPrefix("project key") || said.hasPrefix("project keys")
        || said.hasPrefix("component key")
}

func hint(for parameter: APICatalogue.Parameter) -> String {
    var said = parameter.description.isEmpty ? parameter.key : parameter.description
    if let example = parameter.example { said += "   e.g. " + example }
    if let fallback = parameter.defaultValue { said += "   defaults to " + fallback }
    return said
}

/// The command that would have done the same thing.
///
/// ⚠ Printed before it runs and again after. The menu is for finding the
/// call; the command is what goes in a script tomorrow, and a tool that only
/// ever does it FOR you never teaches it.
func commandFor(_ endpoint: APICatalogue.Endpoint, _ parameters: [String: String]) -> String {
    let short = endpoint.path.replacingOccurrences(of: "api/", with: "")
    let pairs = parameters.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value.contains(" ") ? "\"\($0.value)\"" : $0.value)" }
    return (["oilbird api", short] + pairs).joined(separator: " ")
}

/// A row by its number or by its verb. Both, because a menu that only takes
/// numbers makes the reader count, and one that only takes words makes them
/// type.
func choose(_ answer: String, from rows: [UI.MenuRow]) -> UI.MenuRow? {
    if let number = Int(answer), rows.indices.contains(number - 1) { return rows[number - 1] }
    return rows.first { $0.verb == answer || $0.label == answer }
}

/// What the engine is holding right now, as the facts beside the state word.
///
/// ⚠ Read from disk and from the kernel at the moment it is asked for, never
/// remembered: the CLI, the window, an agent and the idle watchdog all change
/// this and none of them can call back into the others.
func engineFacts(_ port: UInt16) -> [String] {
    let detail = Oilbird.engineDetail()
    return [
        "127.0.0.1:\(port)", detail.map { "up " + $0.uptimeLabel },
        detail?.residentBytes.map(Oilbird.humanBytes), "stops " + idlePhrase(),
    ].compactMap { $0 }
}

/// First contact, when nothing has been installed yet.
///
/// ⚠ A different screen from the one a returning user gets, and that is the
/// point: bare `oilbird` printed usage and exited 2 whether you had used it
/// for a year or had downloaded it a minute ago. The size of what a first
/// run moves must be disclosed before the first byte, so it is here, in the
/// screen that precedes it.
func welcome() -> Never {
    let pins = (try? Oilbird.pinned()) ?? []
    let what: [String: String] = [
        "sonarqube": "the analysis server",
        "jdk": "a Java runtime, used only by Oilbird",
        "postgres": "where results are kept",
        "scanner": "what reads your code",
    ]
    let rows = pins.map {
        WelcomeScreen.Item(id: $0.id, size: Oilbird.humanBytes($0.bytes), what: what[$0.id] ?? "")
    }
    let total = Oilbird.humanBytes((try? Oilbird.firstRunBytes()) ?? 0)
    let columns = ui.columns
    if let frame = Frames.ifOnMain({
        Frames.welcome(items: rows, total: total, width: columns)
    }) {
        say(frame)
    } else {
        show(ui.welcomeScreen(rows: rows, total: total))
    }
    exit(Exit.ok.rawValue)
}

/// The one line above the menu: what the engine is doing right now.
///
/// ⚠ Shorter than `status`'s, and deliberately. It shares its line with a
/// wordmark padded to 44 cells, so there are about fifty left of a 96-column
/// measure — and the first version ran to 145 and wrapped, which turns the
/// heading of the menu into two lines of heading. The port and the memory live
/// one keystroke away in `status`.

func menuState() async -> String {
    let state = await Oilbird.engineState()
    guard case .running = state else { return state.word }
    let detail = Oilbird.engineDetail()
    let timeout = Oilbird.idleTimeout()
    return
        ([state.word]
        + [
            detail.map { "up " + $0.uptimeLabel },
            timeout == .never ? "runs until told" : "stops after \(timeout.rawValue) unused",
        ].compactMap { $0 }).joined(separator: " · ")
}

/// Run one menu row, asking for the argument it needs.
func runChosen(_ row: UI.MenuRow) async -> Int32 {
    var argv = [row.verb]
    switch row.verb {
    case "scan":
        argv.append(FileManager.default.currentDirectoryPath)
    case "issues", "summary", "history":
        // ⚠ Picked from the list, never typed from memory. A prompt naming
        // another command defeats the one thing a menu is for.
        guard let key = await pickProject(for: row.verb) else { return Exit.ok.rawValue }
        argv.append(key)
    default:
        break
    }
    show([""])
    guard let binary = Oilbird.cliBinary() else {
        let what = "oilbird cannot find its own binary to run that with"
        let columns = ui.columns
        if let frame = Frames.ifOnMain({ Frames.error(what, width: columns) }) {
            say(frame)
        } else {
            show(ui.errorScreen(what))
        }
        return Exit.failed.rawValue
    }
    let child = Process()
    child.executableURL = binary
    child.arguments = argv
    guard (try? child.run()) != nil else { return Exit.failed.rawValue }
    child.waitUntilExit()
    return child.terminationStatus
}

@main
struct OilbirdCLI {
    static func main() async {
        await run()
    }
}

private func run() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let json = arguments.contains("--json")
    await refuseUnknownFlags(in: arguments, json: json)

    // ⚠ The menu is an ADDITION at a terminal, never a replacement for
    // documented behaviour: one that blocks on a keypress in a cron job is a
    // hang, so `UI.interactive` needs stdin, which `< /dev/null` takes away.
    guard let cmd = Invocation.parse(arguments) else {
        if UI.interactive() { await menu() }
        let columns = ui.columns
        say(await MainActor.run { Frames.help(build: Oilbird.build.version, width: columns) })
        exit(Exit.usage.rawValue)
    }
    if Usage.startsBeforeDispatch.contains(cmd.verb) { await startEngineDrawing(json: json) }
    await dispatch(cmd)
}

/// Refused BEFORE the verb runs, and `--help` answered here for the same
/// reason: discarding a flag silently made `oilbird down --help` stop the
/// server. A command a CLI does not understand must do nothing.
func refuseUnknownFlags(in arguments: [String], json: Bool) async {
    // ⚠ Asked BEFORE the stray-flag scan, which only looks at arguments
    // beginning `--`. Its `-h` and `help` arms were unreachable, so both
    // answered "unknown command" — the first thing anybody types.
    if arguments.contains(where: { ["--help", "-h", "-help", "help"].contains($0) }) {
        let columns = ui.columns
        say(await MainActor.run { Frames.help(build: Oilbird.build.version, width: columns) })
        exit(Exit.ok.rawValue)
    }
    guard
        let stray = arguments.first(where: {
            $0.hasPrefix("--") && !Invocation.knownFlags.contains($0)
                && !$0.hasPrefix("--severity=")
        })
    else { return }
    // ⚠ Names the way out. A short flag list is fine; refusing `--version` in
    // a build that has a `version` verb, without saying so, is a dead end.
    let instead =
        switch stray {
        case "--version", "-v": " Try `oilbird version`."
        case "--help": ""
        default: " Run `oilbird --help` for the verbs."
        }
    die(
        "'\(stray)' is not a flag oilbird knows. Only --json, --force, --severity, "
            + "--detach, --stop, --browse, --name, --tags, --new-code, --exclude and "
            + "--branch are.\(instead)", .usage, json: json)
}

/// Every verb, and the function that answers it.
///
/// ⚠ Its own function, and the only thing in it. The arm count IS the verb
/// count, so every complexity measure reads a CLI with twenty-two verbs as a
/// function with thirty-four decisions: recorded in `.swiftlint-baseline.json`
/// rather than split, because a table cut in half is two places to look.
/// Nothing else lives here, so nothing else can grow under that allowance.
func dispatch(_ cmd: Invocation) async {
    switch cmd.verb {
    case "doctor": await doctorVerb(cmd)
    case "watch": await watchVerb(cmd)
    case "idle": await idleVerb(cmd)
    case "log": await logVerb(cmd)
    case "configure": await configureVerb(cmd)
    case "forget": await forgetVerb(cmd)
    case "summary": await summaryVerb(cmd)
    case "history": await historyVerb(cmd)
    case "install": await installVerb(cmd)
    case "up": await upVerb(cmd)
    case "down": await downVerb(cmd)
    case "status": await statusVerb(cmd)
    case "scan": await scanVerb(cmd)
    case "scans": await scansVerb(cmd)
    case "follow": await followVerb(cmd)
    case "issues": await issuesVerb(cmd)
    case "gate": await gateVerb(cmd)
    case "projects": await projectsVerb(cmd)
    case "api": await apiVerb(cmd)
    case "version": await versionVerb(cmd)
    case "cli-install": await cliInstallVerb(cmd)
    case "cli-uninstall": await cliUninstallVerb(cmd)
    default:
        // Nearest by edit distance, because `sacn` is what a typo looks
        // like and "unknown command" alone leaves someone reading --help
        // for a word they already know.
        let nearest = Usage.nearestVerb(to: cmd.verb)
        die(
            "unknown command '\(cmd.verb)'" + (nearest.map { ". Did you mean `\($0)`?" } ?? ""),
            .usage, json: cmd.json)
    }
}
