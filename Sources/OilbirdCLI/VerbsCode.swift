import Foundation
import OilbirdKit
import OilbirdModel

// The verbs that look at your code. Every one of them starts an engine if
// none is running, which is what `--help` promises under LOOK AT CODE.

/// `oilbird configure`.
func configureVerb(_ cmd: Invocation) async {
    let arguments = cmd.arguments
    let json = cmd.json
    let positional = cmd.positional
    let valueAfter = cmd.valueAfter
    let argument = requireArgument(
        positional, 1, verb: "configure", needs: "a project key", json: json)
    let wantsName = arguments.contains("--name")
    let wantsTags = arguments.contains("--tags")
    let wantsNewCode = arguments.contains("--new-code")
    let wantsExclude = arguments.contains("--exclude")
    let wantsBranch = arguments.contains("--branch")

    // Reading, not writing. A `configure` you cannot use to check what
    // you set is half a command.
    guard wantsName || wantsTags || wantsNewCode || wantsExclude || wantsBranch else {
        await startEngineDrawing(json: json)
        do {
            let current = try await Oilbird.configuration(of: argument)
            if json {
                emit([
                    "project": current.project, "name": current.chosenName as Any,
                    "tags": current.tags, "newCode": current.newCode as Any,
                    "newCodeInherited": current.newCodeInherited,
                    "exclusions": current.exclusions, "branch": current.branch as Any,
                ])
            } else {
                let columns = ui.columns
                say(
                    await MainActor.run {
                        Frames.configuration(current, width: columns)
                    })
            }
            exit(Exit.ok.rawValue)
        } catch let error as Oilbird.Error {
            die(error, json: json)
        } catch {
            die(String(describing: error), .failed, json: json)
        }
    }

    var changed: [String] = []
    func apply(_ what: String, _ write: () async throws -> Oilbird.Wrote) async {
        do {
            switch try await write() {
            case .done: changed.append(what)
            // ⚠ The server's own words, not ours. It names the parameter
            // and lists the legal values; replacing that with "it did not
            // work" throws away the one useful thing the refusal said.
            case .refused(let said): die("\(what) was refused: \(said)", .failed, json: json)
            }
        } catch let error as Oilbird.Error {
            die(error, json: json)
        } catch {
            die(String(describing: error), .failed, json: json)
        }
    }

    if wantsName {
        let chosen = valueAfter("--name") ?? ""
        do { try Oilbird.name(argument, as: chosen) } catch {
            die("Oilbird could not save that: \(error)", .failed, json: json)
        }
        changed.append(chosen.isEmpty ? "name cleared" : "name")
    }
    if wantsTags || wantsNewCode || wantsExclude || wantsBranch {
        await startEngineDrawing(json: json)
    }
    if wantsTags {
        let tags = (valueAfter("--tags") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        await apply("tags") { try await Oilbird.tag(argument, tags) }
    }
    if wantsNewCode {
        guard let asked = valueAfter("--new-code") else {
            die("--new-code needs a value, like `30` or `previous`.", .usage, json: json)
        }
        // Said the way a person says it, sent the way the server takes
        // it. `30` is plainly "the last thirty days".
        let (type, value): (String, String?) =
            Int(asked) != nil
            ? ("NUMBER_OF_DAYS", asked)
            : (asked.lowercased() == "previous" ? ("PREVIOUS_VERSION", nil) : ("", nil))
        guard !type.isEmpty else {
            die(
                "'\(asked)' is not a new-code rule. Pass a number of days, like `30`, "
                    + "or `previous` for since the previous version.", .usage, json: json)
        }
        await apply("new code") { try await Oilbird.newCode(argument, type, value: value) }
    }
    if wantsExclude {
        let patterns = (valueAfter("--exclude") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        await apply("exclusions") { try await Oilbird.exclude(argument, patterns) }
    }

    if wantsBranch {
        guard let name = valueAfter("--branch"), !name.isEmpty else {
            die("--branch needs a name, like `main` or `master`.", .usage, json: json)
        }
        await apply("branch") { try await Oilbird.renameBranch(argument, to: name) }
    }

    if json {
        emit(["project": argument, "changed": changed])
    } else {
        // ⚠ Only the NAME waits. Tags, new code and exclusions are on
        // the server the moment they are written; saying "at the next
        // scan" about all four would be wrong about three.
        let columns = ui.columns
        let where_ = wantsName ? Oilbird.scan(named: argument)?.path : nil
        let lines =
            wantsName
            ? [
                "The name lands at the next scan — SonarQube has no rename, and only an "
                    + "analysis sets one."
            ] : []
        let offers: [Offers.Offer] =
            wantsName
            ? [
                .init(
                    command: where_.map { "oilbird scan \(Oilbird.displayPath($0))" }
                        ?? "oilbird scan <path>", what: "do it now")
            ] : []
        say(
            await MainActor.run {
                Frames.notice(
                    .init(
                        mark: "saved", markRole: Role.ok,
                        subject: changed.joined(separator: ", "),
                        lines: lines, offers: offers),
                    width: columns)
            })
    }
    exit(Exit.ok.rawValue)
}

/// `oilbird forget`.
func forgetVerb(_ cmd: Invocation) async {
    let json = cmd.json
    let positional = cmd.positional
    let argument = requireArgument(
        positional, 1, verb: "forget", needs: "a project key", json: json)
    do {
        let gone = try await Oilbird.forget(projectKey: argument)
        if json {
            emit(["project": argument, "removed": gone])
        } else if gone {
            let columns = ui.columns
            say(
                await MainActor.run {
                    Frames.notice(
                        .init(mark: "removed", markRole: Role.ok, subject: argument),
                        width: columns)
                })
        } else {
            let columns = ui.columns
            say(
                await MainActor.run {
                    Frames.notice(
                        .init(
                            mark: "none", markRole: Role.warn,
                            subject: "there is no project called \(argument)",
                            offers: [.init(command: "oilbird projects", what: "lists them")]),
                        width: columns)
                })
        }
        exit(gone ? Exit.ok.rawValue : Exit.failed.rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }

    // "How is this code, and what should I fix first?" in one command. The
    // server has already aggregated it; the alternative is pulling every issue
    // and counting them by hand.
}

/// `oilbird summary`.
func summaryVerb(_ cmd: Invocation) async {
    let json = cmd.json
    let positional = cmd.positional
    let argument = requireArgument(
        positional, 1, verb: "summary", needs: "a project key", json: json)
    do {
        let s = try await Oilbird.summary(projectKey: argument)
        if json {
            emit([
                "project": s.project, "gate": s.gate.gate.rawValue,
                "judgedNothing": s.gate.judgedNothing,
                "readNothing": s.gate.readNothing, "issues": s.total,
                "severities": s.severities, "types": s.types, "measures": s.measures,
            ])
        } else {
            let columns = ui.columns
            say(await MainActor.run { Frames.summary(of: s, width: columns) })
        }
        exit(Exit.ok.rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }

    // "Is this better than it was?" — the question after a change, which
    // needed the previous analysis and had no way to reach it.
}

/// `oilbird history`.
func historyVerb(_ cmd: Invocation) async {
    let json = cmd.json
    let positional = cmd.positional
    let argument = requireArgument(
        positional, 1, verb: "history", needs: "a project key", json: json)
    do {
        let snapshots = try await Oilbird.history(projectKey: argument)
        let changes = try await Oilbird.changeSinceLast(projectKey: argument)
        if json {
            emit([
                "project": argument,
                "analyses": snapshots.map { ["date": $0.date, "measures": $0.measures] },
                "sinceLast": changes.map {
                    [
                        "metric": $0.metric, "before": $0.before, "after": $0.after,
                        "delta": $0.delta,
                    ]
                },
            ])
        } else if snapshots.isEmpty {
            show([
                "  {attn|none}{body|  \(argument) has no analyses yet.}",
                "      {action|oilbird scan <path>}",
            ])
        } else {
            // ⚠ Eight of N, WITH the N. Without it a project of 21 analyses
            // shows a window reading 0 → 1 while the hidden earliest was 2,
            // so the visible trend says "worse" where the truth is "better".
            let columns = ui.columns
            say(
                await MainActor.run {
                    Frames.history(
                        project: argument, snapshots: snapshots,
                        changes: changes.map(\.summary), width: columns)
                })
        }
        exit(Exit.ok.rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}

/// `oilbird scan`.
func scanVerb(_ cmd: Invocation) async {
    let arguments = cmd.arguments
    let json = cmd.json
    let positional = cmd.positional
    let argument = requireArgument(
        positional, 1, verb: "scan", needs: "a path", json: json)
    let path = URL(filePath: argument).standardizedFileURL
    // Checked here, so a missing path is a sentence rather than a raw
    // `Error Domain=NSCocoaErrorDomain Code=4 ... UserInfo={...}` blob
    // with a pointer address in it.
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
        await scanNoSuchPath(path, json: json)
    }
    guard isDirectory.boolValue else {
        die("\(path.path) is a file — scan takes a project directory", .usage, json: json)
    }
    if arguments.contains("--detach") { await scanDetached(path, json: json) }
    do {
        // ⚠ `onLine:`, as the scanner speaks. Iterating the collected stdout
        // prints nothing for 11.4 seconds then 125 lines at once, under a
        // progress line claiming to be live; the `calls` check refuses it.
        let waiting = UI.Slot(ui)
        // ⚠ Reported from inside the scan. The engine start is a scan's first
        // fifteen seconds against a paused engine, and drawing it outside puts
        // it ahead of the recording `--detach`'s parent waits for.
        let phases = UI.Phases(ui)
        let result = try await Oilbird.scan(path: path) { phase in
            guard !json else { return }
            waiting.clear()
            if let done = phases.advance(to: phase) { show(done) }
            waiting.working(waitingLabel(phase))
        } onLine: { line in
            guard !json else { return }
            waiting.clear()
            show("  {note|" + UI.escapingMarkup(line) + "}")
            // ⚠ The one silent stretch, so the only one animated. Keyed on
            // `Total time:`, the scanner's LAST line: six lines follow
            // `Analysis report uploaded` and the spinner flickers six times.
            if line.contains("Total time:") {
                waiting.working("the server is computing measures…")
            }
        }
        waiting.clear()
        if !json, let done = phases.close() { show(done) }
        if json {
            emit([
                "project": result.key, "toolchain": result.toolchain.rawValue,
                "degraded": result.degraded, "reason": result.degradedReason ?? "",
                "dashboard": result.dashboard?.absoluteString as Any,
                "filesAnalysed": result.filesAnalysed, "linesAnalysed": result.linesAnalysed,
                "readNothing": result.readNothing,
            ])
        } else if result.readNothing {
            // ⚠ Not `scanned <key>` when the scanner read no source. Saying
            // "scanned" is how an empty directory, a docs folder and a
            // dot-prefixed checkout all come back looking like clean code.
            show(ui.rule())
            let columns = ui.columns
            let shown = Oilbird.displayPath(path.path)
            let why = reasonNothingWasRead(path)
            say(
                await MainActor.run {
                    Frames.readNothing(path: shown, because: why, width: columns)
                })
        } else {
            let read =
                "\(counted(result.filesAnalysed, "file")), "
                + "\(counted(result.linesAnalysed, "line"))"
            show(ui.rule())
            show("  {good|scanned}{note|   }{bold|\(result.key)}{note|   \(read)}")
            if result.degraded {
                // Reported, never silently substituted: an analysis
                // without coverage looks exactly like one with 0% coverage
                // unless something says which it was.
                show([""] + ui.statusDetail("WITHOUT COVERAGE — " + (result.degradedReason ?? "")))
            }
            if let dashboard = result.dashboard {
                show(["", "  {note|dashboard  }{action|" + dashboard.absoluteString + "}"])
            }
            show([
                "",
                "  {action|oilbird summary \(result.key)}{note|   gate, measures and counts}",
            ])
        }
        // `unhealthy`, not `ok` and not `failed`: the scan itself
        // succeeded, so calling it a failure would be wrong too. The
        // honest answer is "I cannot tell you anything about this".
        exit((result.readNothing ? Exit.unhealthy : Exit.ok).rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        // Nothing else should reach here: every failure Oilbird raises is
        // an OilbirdError, which cannot exist without a recovery. If one
        // does, say so plainly rather than crash.
        Oilbird.record(error)
        if json { emit(["error": String(describing: error)]) }
        die(String(describing: error), .failed, json: json)
    }
}

/// `oilbird scan <path>` where there is no such path.
///
/// ⚠ The one usage error that gets a full screen, because it is the one people
/// hit. Both causes have a command that fixes them, and naming it is the
/// difference between an error and a dead end.
func scanNoSuchPath(_ path: URL, json: Bool) async -> Never {
    if json { emit(["error": "there is nothing at \(path.path).", "cause": "usage"]) }
    let columns = ui.columns
    let shownPath = Oilbird.displayPath(path.path)
    say(
        await MainActor.run {
            Frames.error(
                "there is nothing at \(shownPath)",
                advice: [
                    .init(
                        command: "oilbird scan <path-to-your-repo>",
                        what: "if the checkout is somewhere else"),
                    .init(
                        command: "oilbird projects",
                        what: "if you meant a key, these are the keys"),
                ],
                note: "Oilbird looked for a directory to analyse and found no "
                    + "such path. Nothing was started and nothing was changed. "
                    + "exit 2 — usage. A scan that starts and then fails exits 1, "
                    + "and a gate that fails exits 4, so a script can tell the "
                    + "three apart.",
                width: columns)
        })
    exit(Exit.usage.rawValue)
}

/// `oilbird scan --detach`: the same scan in a process that outlives this
/// terminal, answering with the handle and the three commands that act on it.
///
/// ⚠ A background job you cannot name again is a dead end.
func scanDetached(_ path: URL, json: Bool) async -> Never {
    do {
        let started = try await Oilbird.detach(path: path)
        if json { emit(started.fields) }
        // ⚠ The handle is the PROJECT KEY and not a new id: computable
        // before the scanner starts, taken by every other verb already,
        // and collision-free because two scans of one project are refused.
        show([
            "  {good|started}{note|   }{bold|\(started.key)}",
            "",
            "  {note|Running in the background. The engine is held open until it "
                + "finishes,}",
            "  {note|so the idle timer will not stop it underneath the scan.}",
            "",
            "  {body|Follow it}{note|            }"
                + "{action|oilbird follow \(started.key)}",
            "  {body|See what is running}{note|  }{action|oilbird scans}",
            "  {body|Stop it}{note|              }"
                + "{action|oilbird scans --stop \(started.key)}",
            "",
            "  {note|Output is kept, so following late still shows the whole run from "
                + "the}",
            "  {note|beginning rather than whatever is happening when you arrive.}",
        ])
        exit(Exit.ok.rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}

/// `oilbird issues`.
func issuesVerb(_ cmd: Invocation) async {
    let arguments = cmd.arguments
    let json = cmd.json
    let severities = cmd.severities
    let positional = cmd.positional
    let argument = requireArgument(
        positional, 1, verb: "issues", needs: "a project key", json: json)
    do {
        let found = try await Oilbird.issues(projectKey: argument, severities: severities)
        if arguments.contains("--browse") {
            // ⚠ REFUSED without a terminal, not degraded. A full-screen
            // program writing into a pipe is garbage, and plain
            // `oilbird issues` is one word shorter and right there.
            guard UI.interactive(), !json else {
                die(
                    json
                        ? "--browse and --json are different questions. --browse is a screen "
                            + "for a person; --json is the answer for a program."
                        : "--browse needs a terminal. Plain `oilbird issues \(argument)` "
                            + "prints the same findings and survives a pipe.",
                    .usage, json: json)
            }
            // ⚠ No row budget is computed here: the browser is a scene, so
            // the runtime owns the viewport and a resize is a frame rather
            // than a defect.
            let rows = found.issues.map {
                IssueRow(
                    id: $0.key, severity: $0.severity(in: found.taxonomy),
                    file: $0.component, line: $0.line, rule: $0.rule,
                    message: $0.message)
            }
            do {
                try await Frames.browse(
                    project: argument, issues: rows,
                    severities: found.taxonomy.severities)
                exit(Exit.ok.rawValue)
            } catch {
                Oilbird.record(error)
                die(String(describing: error), .failed, json: false)
            }
        }
        if json {
            emit([
                "project": argument, "count": found.total,
                "shown": found.issues.count, "truncated": found.truncated,
                "issues": found.issues.map {
                    [
                        "key": $0.key, "rule": $0.rule, "severity": $0.severity,
                        "component": $0.component, "line": $0.line as Any,
                        "type": $0.type as Any, "message": $0.message,
                    ]
                },
            ])
        } else {
            for issue in found.issues {
                // `line ?? 0` printed ":0" for an issue with no line. That
                // is not a location, and it was the only visible sign of
                // the resolved-issue bug — worth not printing at all.
                let where_ = issue.line.map { ":\($0)" } ?? ""
                // ⚠ Only the severity token is painted: a column of red tokens
                // is a column the eye runs down, a thousand red lines is not.
                // The project key comes off, being the fact they just gave.
                let file =
                    issue.component.hasPrefix(argument + ":")
                    ? String(issue.component.dropFirst(argument.count + 1))
                    : issue.component
                show(
                    "  "
                        + ui.pad(
                            ui.severityToken(issue.severity(in: found.taxonomy)), to: 10)
                        + "{body|" + file + where_ + "}")
                show(
                    ui.statusDetail(
                        UI.escapingMarkup(issue.message)
                            + "  {note|" + issue.rule + "}"))
            }
            // Says WHAT was counted. Without it a filtered list and an
            // unfiltered one print the same sentence with different
            // numbers, and the reader cannot tell which they asked for.
            let scope = severities.isEmpty ? "" : " at \(severities.joined(separator: ", "))"
            show("")
            // The server's total, not the length of what fitted.
            if found.truncated {
                show([
                    "  {bold|\(counted(found.total, "issue"))\(scope)}{note| — showing "
                        + "\(found.issues.count).}",
                    "  {note|Narrow it to see the rest: }"
                        + "{action|oilbird issues \(argument) --severity BLOCKER}",
                ])
            } else {
                show("  {bold|\(counted(found.total, "issue"))\(scope)}")
            }
        }
        exit(Exit.ok.rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}

/// `oilbird gate`.
func gateVerb(_ cmd: Invocation) async {
    let json = cmd.json
    let positional = cmd.positional
    let argument = requireArgument(
        positional, 1, verb: "gate", needs: "a project key", json: json)
    do {
        let result = try await Oilbird.qualityGate(projectKey: argument)
        if json {
            // ⚠ `readNothing` too, and it was missing: the exit code and the
            // drawn screen carried it while the payload an agent parses said
            // `"gate": "OK"` with nothing to contradict it.
            emit([
                "project": argument, "gate": result.gate.rawValue,
                "judgedNothing": result.judgedNothing,
                "readNothing": result.readNothing,
                "conditions": result.conditions.map {
                    [
                        "metric": $0.metricKey, "status": $0.status,
                        "threshold": $0.errorThreshold as Any,
                        "actual": $0.actualValue as Any,
                    ]
                },
            ])
        } else {
            let columns = ui.columns
            say(
                await MainActor.run {
                    Frames.gate(project: argument, result: result, width: columns)
                })
        }
        // ⚠ A failed gate has its own exit code, and neither a gate that
        // judged NOTHING nor an unrecognised verdict is a pass: both exit
        // `unhealthy`, or `oilbird gate x && deploy` deploys.
        if result.gate == .error || !result.gate.isRecognised {
            exit(Exit.gateFailed.rawValue)
        }
        exit((result.judgedNothing || result.readNothing ? Exit.unhealthy : Exit.ok).rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}

/// `oilbird projects`.
func projectsVerb(_ cmd: Invocation) async {
    let json = cmd.json
    do {
        let found = try await Oilbird.projects()
        if json {
            emit(["projects": found.map { ["key": $0.key, "name": $0.name] }])
        } else {
            // ⚠ To stderr, so `--json | jq` is unaffected, and through a real
            // `await MainActor.run`: a `View` is `@MainActor` and top-level
            // code reaches here carrying no isolation.
            let rows = found.map { ProjectsScreen.Project(id: $0.key, name: $0.name) }
            let columns = ui.columns
            say(await MainActor.run { Frames.projects(rows, width: columns) })
        }
        exit(Exit.ok.rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}

/// `oilbird api`.
///
/// ⚠ One verb, and the nesting IS the path, so no generated verb list goes
/// stale and a later SonarQube's endpoint works on an older binary.
/// Describing is the default: 126 of these WRITE.
func apiVerb(_ cmd: Invocation) async {
    let json = cmd.json
    do {
        let rest = Array(cmd.positional.dropFirst())
        let wantsCall = cmd.arguments.contains("--call")
        let pairs = rest.dropFirst().filter { $0.contains("=") }
        let query = rest.dropFirst().joined(separator: " ")

        // Nothing after `api`: browse it, with the same menu every other
        // picker in this binary uses.
        guard let first = rest.first else { try await apiBrowse(json: json) }
        if first == "find" { try await apiFind(query, json: json) }

        let catalogue = try await Oilbird.apiCatalogue()
        // A whole service, if that is what was named. Asked of the
        // catalogue, so it is whatever this server groups things into.
        if let service = catalogue.services.first(where: {
            $0.short == first || $0.name == APICatalogue.normalise(first)
        }) {
            await apiService(service, in: catalogue, json: json)
        }
        if pairs.isEmpty && !wantsCall { await apiDescribe(first, in: catalogue, json: json) }
        try await apiRun(first, rest, json: json)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}

/// `oilbird api` with nothing after it: the catalogue, then a menu through it.
func apiBrowse(json: Bool) async throws -> Never {
    let catalogue = try await Oilbird.apiCatalogue()
    if json {
        emit([
            "services": catalogue.services.map {
                ["name": $0.name, "about": $0.about, "endpoints": $0.endpoints]
            },
            "endpoints": catalogue.endpoints.count,
        ])
        exit(Exit.ok.rawValue)
    }
    say(await MainActor.run { Frames.apiServices(catalogue, width: ui.columns) })
    guard UI.interactive() else { exit(Exit.ok.rawValue) }
    let serviceRows = catalogue.services.map {
        (value: $0.short, detail: $0.about)
    }
    guard let chosen = await pick("Which service?", rows: serviceRows)
    else { exit(Exit.ok.rawValue) }
    let inArea = catalogue.endpoints
        .filter { $0.service == APICatalogue.normalise(chosen) }
        .sorted { $0.path < $1.path }
    let rows = inArea.map {
        (
            value: $0.path.replacingOccurrences(of: "api/", with: ""),
            detail: ($0.post ? "writes · " : "") + $0.summary
        )
    }
    guard let picked = await pick("Which call?", rows: rows),
        let endpoint = catalogue.endpoint(picked)
    else { exit(Exit.ok.rawValue) }
    show([""])
    let detailColumns = ui.columns
    say(
        await MainActor.run {
            Frames.apiEndpoint(endpoint, width: detailColumns)
        })
    // ⚠ And then it RUNS it. A menu that walks you to the right
    // call and then asks you to retype it as a command is the
    // project-key picker's defect with a new subject.
    guard let filled = await fill(endpoint) else {
        show(["", "  {note|Nothing sent.}"])
        exit(Exit.ok.rawValue)
    }
    let ran = commandFor(endpoint, filled)
    do {
        let answer = try await Oilbird.apiCall(
            path: endpoint.path, parameters: filled)
        show([""])
        if answer.isEmpty {
            show(["  {ok|done}{note|  the server accepted it and returned nothing.}"])
        } else {
            print(answer)
        }
        show(["", "  {note|That was:}"])
        show(ui.offers([(ran, "next time, without the menu")]))
        exit(Exit.ok.rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: false)
    }
}

/// `oilbird api find <words>`.
func apiFind(_ query: String, json: Bool) async throws -> Never {
    guard !query.isEmpty else {
        die(
            "What should I look for? Try `oilbird api find custom rule`.",
            .usage, json: json)
    }
    let catalogue = try await Oilbird.apiCatalogue()
    let found = catalogue.matching(query)
    if json {
        emit([
            "endpoints": found.map {
                ["path": $0.path, "writes": $0.post, "summary": $0.summary]
            }
        ])
    } else {
        let columns = ui.columns
        say(
            await MainActor.run {
                Frames.apiEndpoints(
                    found, title: "matching \u{201C}\(query)\u{201D}",
                    width: columns)
            })
    }
    exit(Exit.ok.rawValue)
}

/// `oilbird api <service>`: every endpoint this server groups under it.
func apiService(
    _ service: APICatalogue.Service, in catalogue: APICatalogue, json: Bool
) async -> Never {
    let found = catalogue.endpoints.filter { $0.service == service.name }
    if json {
        emit([
            "service": service.name,
            "endpoints": found.map {
                ["path": $0.path, "writes": $0.post, "summary": $0.summary]
            },
        ])
    } else {
        let columns = ui.columns
        say(
            await MainActor.run {
                Frames.apiEndpoints(
                    found, title: service.short, about: service.about,
                    width: columns)
            })
    }
    exit(Exit.ok.rawValue)
}

/// `oilbird api <path>`: what the call takes, without making it.
func apiDescribe(_ first: String, in catalogue: APICatalogue, json: Bool) async -> Never {
    guard let endpoint = catalogue.endpoint(first) else {
        die(
            Oilbird.unknownEndpoint(APICatalogue.normalise(first), in: catalogue),
            .usage, json: json)
    }
    if json {
        emit([
            "path": endpoint.path, "writes": endpoint.post,
            "unsupported": endpoint.unsupported, "summary": endpoint.summary,
            "parameters": endpoint.parameters.map {
                [
                    "key": $0.key, "required": $0.required,
                    "values": $0.possibleValues, "description": $0.description,
                ]
            },
        ])
    } else {
        say(await MainActor.run { Frames.apiEndpoint(endpoint, width: ui.columns) })
    }
    exit(Exit.ok.rawValue)
}

/// `oilbird api <path> key=value ...`: the call itself.
func apiRun(_ first: String, _ rest: [String], json: Bool) async throws -> Never {
    // `key=value`, so a value may contain anything but the first `=`.
    var parameters: [String: String] = [:]
    for argument in rest.dropFirst() where argument != "--call" {
        guard let split = argument.firstIndex(of: "=") else {
            die(
                "`\(argument)` is not `key=value`. Parameters are given as "
                    + "`ps=10 q=null`.", .usage, json: json)
        }
        parameters[String(argument[argument.startIndex..<split])] =
            String(argument[argument.index(after: split)...])
    }
    let answer = try await Oilbird.apiCall(path: first, parameters: parameters)
    if json {
        print(answer.isEmpty ? "{\"done\": true}" : answer)
    } else if answer.isEmpty {
        show(["  {ok|done}{note|  the server accepted it and returned nothing.}"])
    } else {
        print(answer)
    }
    exit(Exit.ok.rawValue)
}
