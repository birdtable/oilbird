import Foundation
import OilbirdKit
import OilbirdModel

// The verbs that look at Oilbird itself, or run it. None of these starts an
// engine, which is the other half of what `--help` promises.

/// `oilbird doctor`.
func doctorVerb(_ cmd: Invocation) async {
    let json = cmd.json
    // ⚠ Every row RUNS the thing it names, so the wait is real work and looks
    // like a hang. Each row prints as its check completes: the rows arriving
    // IS the progress, and the spinner covers only the gap between them.
    if !json { show(ui.rule("CHECKED BY RUNNING IT")) }
    let slot = UI.Slot(ui)
    let report = await Oilbird.doctor(reporting: { id, diagnosis in
        guard !json else { return }
        guard let diagnosis else {
            slot.working("checking \(id.rawValue) by running it…")
            return
        }
        slot.clear()
        let columns = ui.columns
        say(await MainActor.run { Frames.diagnosis(diagnosis, width: columns) })
    })
    slot.clear()
    var unhealthy = false
    var rows: [[String: String]] = []
    for entry in report {
        // `waiting` is its own state and mark: it is not a failure, and ✗
        // beside a correct dependency sends people to reinstall it. The exit
        // code follows, since an agent reads it to decide about `install`.
        let row: DoctorRow =
            switch entry.outcome {
            case .checked(.missing): DoctorRow(state: "missing")
            case .checked(.present(let version)):
                DoctorRow(state: "present", detail: version)
            case .checked(.corrupt(let reason)):
                DoctorRow(state: "corrupt", detail: reason)
            case .unverifiable(let blocked, _):
                DoctorRow(
                    state: "waiting", detail: blocked.detail,
                    action: blocked.recovery.actionLabel)
            }
        if entry.needsInstall { unhealthy = true }
        rows.append([
            "dependency": entry.id.rawValue, "state": row.state, "detail": row.detail,
            "action": row.action,
        ])
    }
    // What is installed against what this build pins: `missing` right after
    // an app upgrade is a bump and not a broken install, and without this the
    // two are the same word.
    let changes = Oilbird.versionChanges()
    if json {
        emit([
            "dependencies": rows,
            "changes": changes.map {
                [
                    "dependency": $0.id.rawValue, "installed": $0.installed,
                    "expected": $0.expected,
                ]
            },
        ])
    } else {
        if !changes.isEmpty { show("") }
        let columns = ui.columns
        for change in changes {
            let summary = change.summary
            say(
                await MainActor.run {
                    Frames.notice(
                        .init(
                            mark: "note", markRole: Role.warn, subject: summary,
                            offers: [.init(command: "oilbird install", what: "")]),
                        width: columns)
                })
        }
        // Counted from the outcomes, not from `unhealthy`: a dependency that
        // could not be checked is neither ready nor broken, and rolling it
        // into either is the flattening `Outcome` exists to stop.
        let ready = report.filter {
            if case .checked(.present) = $0.outcome { return true }
            return false
        }
        let counts = (ready.count, report.count)
        say(
            await MainActor.run {
                Frames.notice(
                    .init(
                        lines: [
                            "\(counts.0) of \(counts.1) ready. Nothing here is checked by "
                                + "looking for a folder — every row above ran the thing it "
                                + "names. Presence on disk is not presence."
                        ]),
                    width: columns)
            })
    }
    exit((unhealthy ? Exit.unhealthy : Exit.ok).rawValue)

    // The watchdog's own body. A documented verb rather than a hidden
    // `_watch`: a process a user finds in `ps` and cannot look up is a dead
    // end of its own kind.
}

/// `oilbird watch`.
func watchVerb(_ cmd: Invocation) async {
    await Oilbird.runWatchdog()
    exit(Exit.ok.rawValue)

    // The idle interval is a user setting, and until now no
    // client exposed it — a CLI-only user could not choose.
}

/// `oilbird idle`.
func idleVerb(_ cmd: Invocation) async {
    let json = cmd.json
    let positional = cmd.positional
    if let choice = positional.dropFirst().first {
        guard let timeout = Oilbird.IdleTimeout(rawValue: choice) else {
            // Say the actual rule, not a list of three. The floor is a
            // real constraint with a reason; "not one of 30m, 2h, never"
            // was the enum talking, and the enum was arbitrary.
            let floor = Oilbird.IdleTimeout.floorMinutes
            var why = "'\(choice)' is not an interval oilbird understands. "
            why += "Give minutes (45), hours (2h), or 'never' — "
            why += "minimum \(floor) minutes, because a warm start takes about "
            why += "15 seconds and anything shorter stops the engine between your own clicks."
            die(why, .usage, json: json)
        }
        do { try Oilbird.setIdleTimeout(timeout) } catch {
            Oilbird.record(error)
            die(String(describing: error), .failed, json: json)
        }
        // Applies now, not at next start: switching away from "never"
        // must actually begin watching something already running.
        Oilbird.ensureWatching()
    }
    let current = Oilbird.idleTimeout()
    if json {
        emit(["idleTimeout": current.rawValue, "label": current.label])
    } else {
        let columns = ui.columns
        say(
            await MainActor.run {
                Frames.notice(
                    .init(
                        mark: current.rawValue, subject: current.label,
                        offers: [
                            .init(command: "oilbird idle 45", what: "minutes"),
                            .init(command: "oilbird idle 2h", what: "hours"),
                            .init(command: "oilbird idle never", what: "leave it running"),
                        ]),
                    width: columns)
            })
    }
    exit(Exit.ok.rawValue)

    // Half the failures in this tool recover with "Show log", so the log must
    // be showable. An action naming a command that does not exist is a dead
    // end wearing a button.
}

/// `oilbird log`.
func logVerb(_ cmd: Invocation) async {
    let json = cmd.json
    let positional = cmd.positional
    // ⚠ A count that is not a number is REFUSED, never replaced with 80:
    // `oilbird log abc` printing eighty lines looks like it worked, the same
    // substitution as `oilbird scan ''` scanning the working directory.
    let asked = positional.dropFirst().first
    let lines: Int
    if let asked {
        guard let count = Int(asked), count >= 0 else {
            die(
                "'\(asked)' is not a number of lines. `oilbird log` takes a count, "
                    + "like `oilbird log 200`, or nothing for the last 80.", .usage, json: json)
        }
        lines = count
    } else {
        lines = 80
    }
    let text = Oilbird.recentLog(lines: lines)
    if json {
        emit(["log": text, "path": Oilbird.logPath])
    } else if lines == 0 {
        // Distinct from an empty log, which is the sentence below. Zero
        // lines was asked for and zero lines is the honest answer; saying
        // "nothing logged yet" about a full log would be a lie.
        let columns = ui.columns
        let path = Oilbird.displayPath(Oilbird.logPath)
        say(
            await MainActor.run {
                Frames.notice(
                    .init(
                        mark: "0 lines asked for", markRole: Role.dim,
                        subject: "the log is at \(path)"),
                    width: columns)
            })
    } else if text.isEmpty {
        let columns = ui.columns
        let path = Oilbird.displayPath(Oilbird.logPath)
        say(
            await MainActor.run {
                Frames.notice(
                    .init(
                        mark: "nothing logged yet", markRole: Role.dim, subject: path),
                    width: columns)
            })
    } else {
        // ⚠ Unstyled, deliberately. These are somebody else's bytes —
        // SonarQube's, the scanner's, PostgreSQL's — and a design system
        // that reinterprets a log line is one that can misreport it.
        say(text)
    }
    exit(Exit.ok.rawValue)

    // A throwaway scan leaves a project behind for ever and the REST API
    // refuses a client holding no credential. ⚠ One verb for a project's
    // settings, not one per endpoint, so there is one thing to discover.
}

/// `oilbird install`.
func installVerb(_ cmd: Invocation) async {
    let json = cmd.json
    do {
        // ⚠ No spinner: a download has REAL byte progress, and an
        // indeterminate animation over a known number says less. No bars
        // either, which in a CI log are a thousand carriage returns.
        let seen = UI.Phases.Downloads(ui)
        try await Oilbird.install { id, done, total in
            guard !json, total > 0 else { return }
            if let row = seen.progress(id, done: done, of: total) { show(row) }
        }
        if json {
            emit(["installed": true])
        } else {
            show([
                "",
                "  {note|Resuming is automatic: a partial download is kept and continued, "
                    + "so}",
                "  {note|closing this and running }{action|oilbird install}{note| again "
                    + "picks up where it stopped.}",
                "",
                "  {note|Each is fetched from its own official origin and checked against "
                    + "a pinned}",
                "  {note|digest before anything is unpacked. }{action|oilbird version}"
                    + "{note| lists them.}",
            ])
        }
        exit(Exit.ok.rawValue)
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

/// `oilbird up`.
func upVerb(_ cmd: Invocation) async {
    let json = cmd.json
    do {
        // ⚠ The most common wait: 15 seconds warm, 124 cold, most of it the
        // search index, which is worth naming rather than leaving as a silent
        // minute. One line per phase, no redraw.
        let began = Date()
        let slot = UI.Slot(ui)
        let phases = UI.Phases(ui)
        let running = try await Oilbird.ensureRunning { phase in
            guard !json else { return }
            slot.clear()
            if let done = phases.advance(to: phase) { show(done) }
            slot.working(waitingLabel(phase))
        }
        slot.clear()
        if !json, let done = phases.close() { show(done) }
        if json {
            emit(["webPort": Int(running.webPort), "databasePort": Int(running.databasePort)])
        } else {
            show(ui.rule())
            let columns = ui.columns
            let facts = [
                "127.0.0.1:\(running.webPort)",
                Oilbird.humanDuration(Date().timeIntervalSince(began)),
            ]
            let dashboard = "http://127.0.0.1:\(running.webPort)"
            say(
                await MainActor.run {
                    Frames.status(
                        .running(facts: facts, dashboard: dashboard), width: columns)
                })
            say(
                await MainActor.run {
                    Frames.notice(
                        .init(
                            lines: [
                                "It stops itself \(idlePhrase()), and any command starts "
                                    + "it again."
                            ],
                            offers: [
                                .init(
                                    command: "oilbird idle never",
                                    what: "if you would rather it did not")
                            ]),
                        width: columns)
                })
        }
        exit(Exit.ok.rawValue)
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

/// `oilbird down`.
func downVerb(_ cmd: Invocation) async {
    let arguments = cmd.arguments
    let json = cmd.json
    // Refuses while something is using the engine, rather than pulling
    // it out from under a running scan. `--force` is the user saying
    // they meant it.
    let force = arguments.contains("--force")
    // Several seconds of SIGTERM grace and then PostgreSQL stopping, and
    // it printed nothing for the whole of it. Nothing to count here —
    // indeterminate, which is what the animation is for.
    let stopping = json ? UI.Working.noStop : ui.working("stopping the engine…")
    let stopped = await Oilbird.down(force: force)
    stopping()
    if json {
        emit(["running": !stopped, "stopped": stopped, "inUse": !stopped])
    } else if stopped {
        let columns = ui.columns
        say(
            await MainActor.run {
                Frames.notice(
                    .init(
                        mark: "paused", markRole: Role.ok,
                        subject: "the engine is stopped and about 1.6 GB is back",
                        lines: ["Your results are all still here. Any command starts it again."],
                        offers: [.init(command: "oilbird up", what: "")]),
                    width: columns)
            })
    } else {
        // No count: the holder is usually another process, and this
        // process cannot see how many. Saying "0 task(s)" while
        // refusing for that very reason was worse than saying nothing.
        let columns = ui.columns
        say(
            await MainActor.run {
                Frames.error(
                    "something is using the engine, so it was not stopped",
                    advice: [
                        .init(command: "oilbird scans", what: "what is running"),
                        .init(command: "oilbird down --force", what: "stops it anyway"),
                    ], width: columns)
            })
    }
    exit((stopped ? Exit.ok : Exit.failed).rawValue)
}

/// `oilbird status`.
func statusVerb(_ cmd: Invocation) async {
    let json = cmd.json
    // Paused and stopped are identical on disk and different to read: an
    // engine that stopped because nobody used it is the product working, and
    // "stopped" makes that look like a fault.
    switch await Oilbird.engineState() {
    case .running(let running):
        if json {
            emit([
                "state": "running", "running": true, "webPort": Int(running.webPort),
                "inUse": Oilbird.inUse(),
            ])
        } else {
            let columns = ui.columns
            let facts = engineFacts(running.webPort)
            let dashboard = "http://127.0.0.1:\(running.webPort)"
            say(
                await MainActor.run {
                    Frames.status(
                        .running(facts: facts, dashboard: dashboard),
                        width: columns)
                })
        }
    case .paused:
        if json {
            emit(["state": "paused", "running": false, "idleTimeout": Oilbird.idleTimeout().rawValue])
        } else {
            // No invented reason: it states the RULE, whichever of the
            // watchdog or `down` stopped it, because the lock this derives
            // from carries no reason across processes.
            let columns = ui.columns
            let rule = "stops " + idlePhrase()
            say(
                await MainActor.run {
                    Frames.status(.paused(rule: rule), width: columns)
                })
        }
    case .notInstalled:
        if json {
            emit(["state": "notInstalled", "running": false])
        } else {
            let columns = ui.columns
            say(
                await MainActor.run {
                    Frames.status(.notInstalled, width: columns)
                })
        }
    case .starting:
        if json {
            emit(["state": "starting", "running": false])
        } else {
            let columns = ui.columns
            say(await MainActor.run { Frames.status(.starting, width: columns) })
        }
    case .unresponsive(let running):
        // Its own state and its own exit code. A script that treats this
        // as "running" makes the next call fail for no visible reason;
        // one that treats it as "stopped" never repairs it.
        if json {
            emit([
                "state": "unresponsive", "running": false, "recorded": true,
                "webPort": Int(running.webPort),
            ])
        } else {
            let columns = ui.columns
            let address = "127.0.0.1:\(running.webPort)"
            say(
                await MainActor.run {
                    Frames.status(
                        .unresponsive(address: address), width: columns)
                })
        }
        exit(Exit.unhealthy.rawValue)
    }
    exit(Exit.ok.rawValue)
}

/// `oilbird scans`.
///
/// ⚠ Reads the disk and starts nothing. "Did that finish?" is asked more
/// often than "what is running?", and an answer that costs a
/// fifteen-second, 1.6 GB engine start is an idle cost Oilbird refuses.
func scansVerb(_ cmd: Invocation) async {
    let arguments = cmd.arguments
    let json = cmd.json
    let positional = cmd.positional
    if arguments.contains("--stop") {
        let key = requireArgument(
            positional, 1, verb: "scans --stop", needs: "a project key", json: json)
        do {
            let (entry, ended) = try Oilbird.stopScan(key: key)
            if json {
                emit(entry.fields.merging(["ended": ended]) { _, new in new })
            } else if ended {
                // Said out loud, because the opposite assumption — that
                // stopping undid it — is what stops people from stopping
                // a scan they no longer need.
                show([
                    "  {attn|stopped}{note|   }{bold|\(entry.key)}",
                    "",
                    "  {body|Anything already uploaded is kept: the compute engine has it.}",
                ])
            } else {
                let columns = ui.columns
                let what =
                    "\(entry.key) is not running — \(entry.verdict), "
                    + "\(Oilbird.humanAgo(entry.finished ?? entry.started))"
                let key = entry.key
                say(
                    await MainActor.run {
                        Frames.error(
                            what,
                            advice: [
                                .init(command: "oilbird follow \(key)", what: "shows the run")
                            ], width: columns)
                    })
            }
            exit((ended ? Exit.ok : Exit.failed).rawValue)
        } catch let error as Oilbird.Error {
            die(error, json: json)
        } catch {
            Oilbird.record(error)
            die(String(describing: error), .failed, json: json)
        }
    }
    let entries = Oilbird.scans()
    if json {
        emit(["scans": entries.map(\.fields)])
        exit(Exit.ok.rawValue)
    }
    let columns = ui.columns
    say(await MainActor.run { Frames.scans(entries, width: columns) })
    exit(Exit.ok.rawValue)

    // ⚠ Its own verb, not a flag. `watch` is the idle watchdog
    // and means something else, and `scan --follow <key>` reads as a scan
    // taking a key instead of a path, the one thing `scan` does not do.
}

/// `oilbird follow`.
func followVerb(_ cmd: Invocation) async {
    let json = cmd.json
    let positional = cmd.positional
    let key = requireArgument(
        positional, 1, verb: "follow", needs: "a project key", json: json)
    do {
        // Read before attaching, so the header can say which of the two
        // this is: a run you are joining, or one you are reading back.
        if let before = Oilbird.scan(named: key), !json {
            if before.state == .running {
                show(
                    "  {action|following}{note|   }{bold|\(before.key)}{note|   "
                        + "\(Oilbird.displayPath(before.path))}")
            } else {
                // The state, not the word "finished": a scan the machine
                // was rebooted out from under did not finish, and saying
                // it did would contradict the verdict printed below it.
                let ended = before.state == .interrupted ? "interrupted" : "finished"
                show(
                    "  {bold|\(before.key)}{note|   \(ended) "
                        + "\(Oilbird.humanAgo(before.finished ?? before.started))}")
            }
            show("")
        }
        let entry = try await Oilbird.follow(key: key) { line in
            guard !json else { return }
            show("  {note|" + UI.escapingMarkup(line) + "}")
        }
        if json {
            emit(entry.fields)
            exit(Exit.ok.rawValue)
        }
        show("")
        show(ui.rule())
        switch entry.outcome {
        case .completed(let done):
            // The gate as it stood when the scan ended, recorded then
            // because reading it now would mean starting the engine.
            let gate: ScanResultScreen.Gate =
                if done.judgedNothing {
                    .judgedNothing
                } else if let said = done.gate {
                    .verdict(
                        said: said == "ERROR" ? "FAILED" : "OK", failed: said == "ERROR",
                        next: "oilbird gate \(entry.key)")
                } else {
                    .none
                }
            let columns = ui.columns
            let key = entry.key
            let read = entry.read
            let degraded = done.degraded
            say(
                await MainActor.run {
                    Frames.scanResult(
                        project: key,
                        outcome: .scanned(read: read, degraded: degraded, gate: gate),
                        width: columns)
                })
            exit(Exit.ok.rawValue)
        case .readNothing:
            let columns = ui.columns
            let shown = Oilbird.displayPath(entry.path)
            let why = reasonNothingWasRead(URL(filePath: entry.path))
            say(
                await MainActor.run {
                    Frames.readNothing(path: shown, because: why, width: columns)
                })
            exit(Exit.unhealthy.rawValue)
        case .failed(let why):
            let columns = ui.columns
            let what = "\(entry.key) did not finish — \(why)"
            say(
                await MainActor.run {
                    Frames.error(
                        what,
                        advice: [.init(command: "oilbird log", what: "has the detail")],
                        width: columns)
                })
            exit(Exit.failed.rawValue)
        case .stopped:
            let columns = ui.columns
            let key = entry.key
            say(
                await MainActor.run {
                    Frames.scanResult(project: key, outcome: .stopped, width: columns)
                })
            exit(Exit.failed.rawValue)
        case nil:
            // Recorded as running and the process is gone: a restart, or
            // something killed it. Never resumed — the pid may belong to
            // somebody else now.
            let columns = ui.columns
            let key = entry.key
            let rerun = "oilbird scan \(Oilbird.displayPath(entry.path))"
            say(
                await MainActor.run {
                    Frames.scanResult(
                        project: key, outcome: .interrupted(rerun: rerun), width: columns)
                })
            exit(Exit.failed.rawValue)
        }
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}

/// `oilbird version`.
func versionVerb(_ cmd: Invocation) async {
    let json = cmd.json
    // ⚠ `--version` is refused above on purpose: widening the allowed set for
    // one verb's convenience is how a flag list stops meaning anything. The
    // verb is the answer and `--help` names it.
    do {
        let build = Oilbird.build
        let pins = try Oilbird.pinned()
        if json {
            emit([
                "oilbird": build.version,
                "commit": build.commit as Any,
                "pinned": pins.map {
                    ["id": $0.id, "version": $0.version, "licence": $0.licence]
                },
            ])
        } else {
            // ⚠ Two columns, because pinned and installed are DIFFERENT
            // claims. That is the whole point of the screen: one column plus
            // "run doctor for the other" hides a bump that has not landed.
            let columns = ui.columns
            let rows = (try? Oilbird.versionTable()) ?? []
            say(
                await MainActor.run {
                    Frames.version(
                        build: build.version, commit: build.commit, rows: rows,
                        width: columns)
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

/// `oilbird cli-install`.
func cliInstallVerb(_ cmd: Invocation) async {
    let json = cmd.json
    do {
        try Oilbird.installCLI()
        if json {
            emit(["installed": true, "path": "/usr/local/bin/oilbird"])
        } else {
            show([
                "  {good|installed}{note|   }{action|/usr/local/bin/oilbird}",
                "",
                "  {note|A symlink, so an Oilbird update updates this too. }"
                    + "{action|oilbird cli-uninstall}{note| removes it.}",
            ])
        }
        exit(Exit.ok.rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}

/// `oilbird cli-uninstall`.
func cliUninstallVerb(_ cmd: Invocation) async {
    let json = cmd.json
    do {
        try Oilbird.uninstallCLI()
        if json { emit(["installed": false]) } else { show("  {good|removed}") }
        exit(Exit.ok.rawValue)
    } catch let error as Oilbird.Error {
        die(error, json: json)
    } catch {
        Oilbird.record(error)
        die(String(describing: error), .failed, json: json)
    }
}
