import Foundation
import OilbirdKit
import OilbirdModel

/// One method per tool, in the order `call` routes them.
///
/// ⚠ `static` rather than `private static`, which is what moving them out
/// of `OilbirdMCP.swift` costs: `private` is file-scoped, so `call` could
/// not reach them from the other file. This is an executable target, so
/// `internal` is still module-private and nothing outside can call one.
extension Tools {
    /// `oilbird_doctor`.
    static func doctor(_ arguments: [String: Any]) async throws -> String {
        // ⚠ Starts nothing. An agent that cannot ask "is Oilbird healthy?"
        // without spending 1.6 GB and forty seconds has no way to be careful.
        let report = await Oilbird.doctor()
        // Each line says what to do about it, which is why this reports
        // `waiting` and not `corrupt`: `corrupt` sends an agent to
        // `oilbird_install`, which re-downloads and changes nothing.
        var lines = report.map { entry in
            switch entry.outcome {
            case .checked(.missing): "\(entry.id.rawValue): missing"
            case .checked(.present(let version)): "\(entry.id.rawValue): present (\(version))"
            case .checked(.corrupt(let reason)): "\(entry.id.rawValue): corrupt — \(reason)"
            case .unverifiable(let blocked, _):
                "\(entry.id.rawValue): installed, not yet checked — \(blocked.detail) "
                    + "(\(blocked.recovery.actionLabel))"
            }
        }
        // Says a version bump is a version bump, in the same breath: without
        // it `missing` after an upgrade sends an agent to `oilbird_install`
        // with no idea why.
        lines += Oilbird.versionChanges().map { "\($0.summary) (pinned by this build)" }
        return lines.joined(separator: "\n")
    }

    /// `oilbird_scan`.
    static func scan(_ arguments: [String: Any]) async throws -> String {
        let path = try required(arguments, "path", "a path")
        let detached = try flag(arguments, "detach")
        // ⚠ A call that blocks for the minutes a large scan takes is a client
        // timeout that loses finished work. `detach` returns the key at once
        // and `oilbird_follow` answers "how far has it got".
        if detached {
            let started = try await Oilbird.detach(
                path: URL(filePath: path)
                    .standardizedFileURL)
            return """
                Started \(started.key) in the background.
                Call oilbird_follow with that key to read its progress, or \
                oilbird_scans to see everything running.
                Output is kept, so following late still shows the whole run.
                """
        }
        let result = try await Oilbird.scan(path: URL(filePath: path).standardizedFileURL)
        // ⚠ The key, which no other tool can derive from the path, and the
        // COUNT leads: told only "Scanned X", an agent reports a clean bill of
        // health for a directory the analysis never opened.
        guard !result.readNothing else {
            return "Scanned \(result.key), but NO CODE WAS READ — 0 files, 0 lines.\n"
                + "Nothing was analysed, so any issue count, measure or quality gate "
                + "for this project describes nothing. Do not report it as clean.\n"
                + "Common causes: the directory is empty; it holds no source in a "
                + "language this SonarQube analyses; everything in it was excluded; or "
                + "its folder name begins with a dot, which makes SonarQube treat every "
                + "file inside as hidden."
        }
        var text = "Scanned \(result.key) (\(result.toolchain.rawValue)) — "
        text += "\(result.filesAnalysed) files, \(result.linesAnalysed) lines."
        text += "\nThe analysis has been processed; issues are ready to read."
        if let dashboard = result.dashboard { text += "\nDashboard: \(dashboard)" }
        if result.degraded { text += "\n\nDEGRADED: \(result.degradedReason ?? "")" }
        return text

        // ⚠ Not the CLI's `follow`, which holds a terminal open until the scan
        // ends and times an agent out. This reads the log as it stands and
        // returns, re-askable because the log is a file nobody consumes.

        // ⚠ Starts nothing: a fifteen-second engine start makes polling worse
        // than not asking, and writing a string Oilbird records itself would
        // not justify one either.
    }

    /// `oilbird_configure`.
    static func configure(_ arguments: [String: Any]) async throws -> String {
        let project = try required(arguments, "project", "a project key")
        let writes = ["name", "tags", "newCode", "exclusions", "branch"]
            .filter { arguments[$0] != nil }
        guard !writes.isEmpty else {
            let now = try await Oilbird.configuration(of: project)
            return
                ([
                    "\(now.project)",
                    "name: "
                        + (now.chosenName.map { "\"\($0)\" at the next scan" }
                            ?? "after its directory"),
                    "tags: " + (now.tags.isEmpty ? "none" : now.tags.joined(separator: ", ")),
                    "new code: " + (now.newCode ?? "the server's default")
                        + (now.newCodeInherited ? " (inherited)" : ""),
                    "branch: " + (now.branch ?? "not analysed yet"),
                    "excluded: "
                        + (now.exclusions.isEmpty
                            ? "nothing beyond the global list"
                            : now.exclusions.joined(separator: ", ")),
                ]).joined(separator: "\n")
        }

        var did: [String] = []
        func apply(_ what: String, _ write: () async throws -> Oilbird.Wrote) async throws {
            switch try await write() {
            case .done: did.append(what)
            // ⚠ The server's own words. It names the parameter and lists
            // the legal values, which "it did not work" would throw away.
            case .refused(let said):
                throw Oilbird.Error(
                    .verifyFailed, "\(what) was refused: \(said)",
                    recovery: .chooseAlternative("Read the message and try another value"))
            }
        }

        if let chosen = arguments["name"] {
            guard let wanted = chosen as? String else {
                throw Oilbird.Error(
                    .verifyFailed, "'\(chosen)' is not a name. Pass a string.",
                    recovery: .chooseAlternative("Pass a string"))
            }
            try Oilbird.name(project, as: wanted)
            did.append(wanted.isEmpty ? "name cleared" : "name")
        }
        if arguments["tags"] != nil {
            let tags = try strings(arguments, "tags")
            try await apply("tags") { try await Oilbird.tag(project, tags) }
        }
        if let asked = arguments["newCode"] {
            guard let text = asked as? String else {
                throw Oilbird.Error(
                    .verifyFailed, "'\(asked)' is not a new-code rule. Pass a string.",
                    recovery: .chooseAlternative("Pass a string"))
            }
            let (type, value): (String, String?) =
                Int(text) != nil
                ? ("NUMBER_OF_DAYS", text)
                : (text.lowercased() == "previous" ? ("PREVIOUS_VERSION", nil) : ("", nil))
            guard !type.isEmpty else {
                throw Oilbird.Error(
                    .verifyFailed,
                    "'\(text)' is not a new-code rule. Pass a number of days, like "
                        + "\"30\", or \"previous\".",
                    recovery: .chooseAlternative("Pass days or previous"))
            }
            try await apply("new code") {
                try await Oilbird.newCode(project, type, value: value)
            }
        }
        if arguments["exclusions"] != nil {
            let patterns = try strings(arguments, "exclusions")
            try await apply("exclusions") { try await Oilbird.exclude(project, patterns) }
        }
        if let branch = arguments["branch"] {
            guard let name = branch as? String, !name.isEmpty else {
                throw Oilbird.Error(
                    .verifyFailed, "'\(branch)' is not a branch name. Pass a string.",
                    recovery: .chooseAlternative("Pass a string"))
            }
            try await apply("branch") { try await Oilbird.renameBranch(project, to: name) }
        }
        guard arguments["name"] != nil else { return "Saved: \(did.joined(separator: ", "))." }
        let wanted = (arguments["name"] as? String) ?? ""
        // ⚠ Says the rename has NOT happened, because SonarQube has no
        // endpoint that renames: only an analysis carrying `sonar.projectName`
        // does. Reporting success would report a write that never happened.
        let path = Oilbird.scan(named: project)?.path
        let next = path.map { "oilbird_scan on \($0)" } ?? "the next scan of it"
        guard !wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(project) goes back to its directory name, from \(next)."
        }
        return "Saved. \(project) will be called \"\(wanted)\" — but NOT YET: "
            + "SonarQube has no rename, and only an analysis sets a name. "
            + "Run \(next) to apply it."
    }

    /// `oilbird_follow`.
    static func follow(_ arguments: [String: Any]) async throws -> String {
        let key = try required(arguments, "project", "a project key")
        let tail = try count(arguments, "lines", default: Self.followTail)
        // ⚠ The output FIRST, then the state, or the state is older than the
        // lines beside it: `running` under a log ending in EXECUTION SUCCESS.
        let said = Oilbird.scanOutput(key: key)
        guard let entry = Oilbird.scan(named: key) else {
            throw Oilbird.Error(
                .verifyFailed, "Nothing has been scanned under '\(key)' on this machine.",
                recovery: .chooseAlternative("List scans"))
        }
        // The END of the log, not the start: the scanner's last words are
        // where a failure says why, and the first are boilerplate.
        let shown = tail == 0 ? said : Array(said.suffix(tail))
        var report = [
            "\(entry.key) — \(entry.state == .running ? "running" : entry.verdict)"
                + " after \(Oilbird.humanDuration(entry.elapsed))"
        ]
        if entry.state == .running, let phase = entry.phase {
            report.append("Phase: \(phase.rawValue)")
        }
        if shown.count < said.count {
            report.append("Showing the last \(shown.count) of \(said.count) lines.")
        }
        return (report + [""] + shown).joined(separator: "\n")

        // ⚠ Starts nothing, like `oilbird_status`. "Did that scan finish?" is
        // asked most often of this surface, and a fifteen-second, 1.6 GB
        // answer makes polling worse than not asking.
    }

    /// `oilbird_scans`.
    static func scans(_ arguments: [String: Any]) async throws -> String {
        let stop = ((arguments["stop"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stop.isEmpty {
            let (entry, ended) = try Oilbird.stopScan(key: stop)
            return ended
                ? "Stopped \(entry.key). Anything it had already uploaded is kept — the "
                    + "compute engine has it."
                : "\(entry.key) is not running: \(entry.verdict)."
        }
        let scans = Oilbird.scans()
        guard !scans.isEmpty else { return "Nothing has been scanned yet." }
        let running = scans.filter { $0.state == .running }.map {
            "\($0.key)  \($0.verdict)  \(Oilbird.humanDuration($0.elapsed))  \($0.path)"
        }
        let done = scans.filter { $0.state != .running }.prefix(20).map {
            "\($0.key)  \($0.verdict)  "
                + "\(Oilbird.humanAgo($0.finished ?? $0.started))  \($0.read)"
        }
        var text = running.isEmpty ? ["No scan is running."] : ["RUNNING"] + running
        if !done.isEmpty { text += [""] + ["FINISHED"] + done }
        return text.joined(separator: "\n")
    }

    /// `oilbird_issues`.
    static func issues(_ arguments: [String: Any]) async throws -> String {
        let project = try required(arguments, "project", "a project key")
        let severities = try strings(arguments, "severities").map { $0.uppercased() }
        // ⚠ Checked here against both vocabularies, not left to the server:
        // SonarQube refuses an unknown value by naming the LEGACY five even
        // under MQR, sending an agent to `CRITICAL` when the word is `HIGH`.
        let known = Set(
            Oilbird.mqrSeverities + Oilbird.standardSeverities)
        if let wrong = severities.first(where: { !known.contains($0) }) {
            throw Oilbird.Error(
                .verifyFailed,
                "'\(wrong)' is not a severity. This server uses "
                    + Oilbird.mqrSeverities.joined(separator: ", ")
                    + " in MQR mode, or "
                    + Oilbird.standardSeverities.joined(separator: ", ")
                    + " in standard mode. oilbird_issues names which in its answer.",
                recovery: .chooseAlternative("Use a severity this server knows"))
        }
        let limit = try count(arguments, "limit", default: Self.issuePage)
        try await Oilbird.ensureRunning()
        let found = try await Oilbird.issues(projectKey: project, severities: severities)
        let scope = severities.isEmpty ? "" : " at \(severities.joined(separator: "/"))"
        guard !found.issues.isEmpty else { return "No issues in \(project)\(scope)." }
        // ⚠ BOUNDED, and the WORST are kept rather than the first: one call
        // returned about 80,000 tokens, and the server's order is not severity
        // order, so a plain prefix drops blockers.
        let shown = Oilbird.worst(found.issues, taxonomy: found.taxonomy, limit: limit)
        // The real total first, then a truncation notice: a count silently
        // meaning "the first page" hid 116 of 187 findings.

        // ⚠ The vocabulary travels with the answer, since it differs by server
        // and an agent would otherwise call `oilbird_summary` purely to learn
        // which words its filter may use.
        var header = "\(Oilbird.counted(found.total, "issue")) in \(project)\(scope)"
        if shown.count < found.total {
            header += " — showing the \(shown.count) worst"
        }
        header += "."
        if severities.isEmpty {
            header +=
                " Severities on this server: "
                + found.taxonomy.severities.joined(separator: ", ") + "."
        }
        if shown.count < found.total {
            header += " Narrow with severities, or raise limit (0 for all)."
        }
        // ⚠ The rule id travels, and the label is in the taxonomy the SERVER
        // judges by: under MQR the payload carries both and they disagree, so
        // an agent and a person would read different verdicts.
        let rows = shown.map { issue in
            let where_ = issue.line.map { line in ":\(line)" } ?? ""
            // ⚠ The project key comes off, as on the CLI's rows: it is the one
            // fact the caller just supplied, repeated fifty times in front of
            // the one they asked for.
            let file = UI.shorten(issue.component, of: project)
            let kind =
                found.taxonomy == .mqr
                ? issue.impacts.map { " [\($0.softwareQuality)]" }.joined()
                : (issue.type.map { " [\($0)]" } ?? "")
            return "\(issue.severity(in: found.taxonomy))\(kind) \(issue.rule) "
                + "\(file)\(where_) — \(issue.message)"
        }
        return ([header, ""] + rows).joined(separator: "\n")
    }

    /// `oilbird_quality_gate`.
    static func qualityGate(_ arguments: [String: Any]) async throws -> String {
        let project = try required(arguments, "project", "a project key")
        try await Oilbird.ensureRunning()
        let result = try await Oilbird.qualityGate(projectKey: project)
        guard !result.readNothing else {
            // ⚠ Checked BEFORE `judgedNothing`, which catches only a first
            // analysis: from the second scan on, SonarQube evaluates its
            // conditions against no code and passes them all.
            return "\(result.gate.rawValue) — but NO CODE WAS READ. Nothing was "
                + "analysed for this project, so the gate judged nothing. This is "
                + "not a pass."
        }
        guard !result.judgedNothing else {
            // An agent that reads `OK` here and proceeds is acting on a
            // gate that evaluated no conditions at all.
            return "\(result.gate.rawValue) — but no conditions were evaluated. "
                + "This gate scores new code and there is no baseline yet, "
                + "so it is not a pass."
        }
        // ⚠ The count travels. A bare `OK` says nothing about how much was
        // checked, and an agent deciding whether to ship needs the same fact
        // the CLI gives a person.
        let judged =
            "\(result.gate.rawValue) — \(result.failed.count) of "
            + "\(result.conditions.count) "
            + (result.conditions.count == 1 ? "condition" : "conditions")
            + " failed"
        let failed = result.failed.map {
            "  \($0.metricKey): \($0.actualValue ?? "?") (limit \($0.errorThreshold ?? "?"))"
        }
        return ([judged] + failed).joined(separator: "\n")

        // ⚠ Starts nothing, like `oilbird_doctor`. "Is Oilbird there?" costing
        // a fifteen-second start and 1.6 GB leaves an agent no way to be
        // careful.
    }

    /// `oilbird_status`.
    static func status(_ arguments: [String: Any]) async throws -> String {
        switch await Oilbird.engineState() {
        case .running(let running):
            // ⚠ "in use", not "a scan is running". `inUse()` is true for ANY
            // holder of the idle attachment, and an open dashboard takes one.
            // Naming a scan that is not running sends an agent looking.
            return "running on http://127.0.0.1:\(running.webPort)"
                + (Oilbird.inUse() ? " — in use, so it will not stop itself yet" : "")
        case .paused:
            return "paused. It stopped when nothing needed it. "
                + "Any tool that needs it will start it again, which takes about 15 seconds."
        case .notInstalled:
            return "not set up yet. Run `oilbird install`, or call any tool that needs it."
        case .starting:
            return "starting. Another client is bringing the engine up; "
                + "it will be ready in a few seconds."
        case .unresponsive(let running):
            return "recorded as running on port \(running.webPort) but not answering. "
                + "The next tool that needs it will restart it."
        }
    }

    /// `oilbird_summary`.
    static func summary(_ arguments: [String: Any]) async throws -> String {
        let project = try required(arguments, "project", "a project key")
        try await Oilbird.ensureRunning()
        let summary = try await Oilbird.summary(projectKey: project)
        var lines = ["\(summary.project)"]
        // ⚠ Three cases, and `readNothing` leads. A summary of a directory
        // nothing analysed used to read `gate: OK`, all-A ratings, 0 issues.
        // From the second scan `judgedNothing` goes false and nothing looked.
        if summary.gate.readNothing {
            lines.append(
                "gate: \(summary.gate.gate.rawValue) — but NO CODE WAS READ. Every measure, "
                    + "rating and count below describes nothing. Do not report it as clean.")
        } else if summary.gate.judgedNothing {
            lines.append(
                "gate: \(summary.gate.gate.rawValue) — but no conditions were evaluated, "
                    + "so this is not a pass. The gate scores new code and there is no "
                    + "baseline yet.")
        } else {
            lines.append("gate: \(summary.gate.gate.rawValue)")
        }
        for condition in summary.gate.failed {
            lines.append(
                "  failed \(condition.metricKey): \(condition.actualValue ?? "?") "
                    + "(limit \(condition.errorThreshold ?? "?"))")
        }
        for (key, label) in [
            ("ncloc", "lines"), ("coverage", "coverage %"),
            ("duplicated_lines_density", "duplication %"),
            ("cognitive_complexity", "cognitive complexity"), ("sqale_index", "debt (min)"),
        ] where summary.measures[key] != nil {
            lines.append("\(label): \(summary.measures[key] ?? "")")
        }
        // The letter judgement the dashboard leads with, which neither
        // surface printed — so a project the window rated D reported no
        // rating at all to the agent asked to fix it.
        let ratings = [
            ("reliability_rating", "reliability"), ("security_rating", "security"),
            ("sqale_rating", "maintainability"), ("security_review_rating", "hotspots"),
        ].compactMap { key, label -> String? in
            Oilbird.ratingLetter(summary.measures[key]).map { "\(label) \($0)" }
        }
        if !ratings.isEmpty { lines.append("ratings: \(ratings.joined(separator: ", "))") }
        lines.append("issues: \(summary.total)")
        // ⚠ Worst first, not alphabetical. "What do I fix first" is
        // answered by an ordering, and `blocker, critical, info, major,
        // minor` is not one — it put INFO third.
        let order = summary.taxonomy.severities
        let bySeverity = order.compactMap { key in
            summary.severities[key].map { "\(key.lowercased()) \($0)" }
        }.joined(separator: ", ")
        if !bySeverity.isEmpty { lines.append("  by severity: \(bySeverity)") }
        let byType = summary.types.sorted { $0.value > $1.value }
            .map { "\($0.key.lowercased()) \($0.value)" }.joined(separator: ", ")
        if !byType.isEmpty {
            lines.append("  by \(summary.taxonomy == .mqr ? "quality" : "type"): \(byType)")
        }
        return lines.joined(separator: "\n")

        // Also does not start the engine: reading the log is what you do
        // when starting it is what failed.
    }

    /// `oilbird_log`.
    static func log(_ arguments: [String: Any]) async throws -> String {
        // ⚠ A wrong-typed argument used to become "the default" silently, and
        // an agent cannot see the request it did not make. `"lines": "abc"`
        // and `"lines": -5` are refused by name.
        let lines = try count(arguments, "lines", default: 80)
        let text = Oilbird.recentLog(lines: lines)
        if lines == 0 { return "0 lines asked for. The log is at \(Oilbird.logPath)." }
        return text.isEmpty ? "Nothing logged yet (\(Oilbird.logPath))." : text
    }

    /// `oilbird_forget`.
    static func forget(_ arguments: [String: Any]) async throws -> String {
        let project = try required(arguments, "project", "a project key")
        try await Oilbird.ensureRunning()
        let gone = try await Oilbird.forget(projectKey: project)
        return gone ? "Removed \(project)." : "There is no project called \(project)."
    }

    /// `oilbird_history`.
    static func history(_ arguments: [String: Any]) async throws -> String {
        let project = try required(arguments, "project", "a project key")
        try await Oilbird.ensureRunning()
        let snapshots = try await Oilbird.history(projectKey: project)
        guard !snapshots.isEmpty else { return "\(project) has not been analysed yet." }
        // ⚠ Eight of N, with the N. A window shown without a word that it is
        // a window reads as a trend that is not there.
        let window = min(snapshots.count, Oilbird.historyWindow)
        var lines: [String] = []
        if window < snapshots.count {
            lines.append(
                "Showing the last \(window) of \(snapshots.count) analyses, oldest first.")
        }
        lines += snapshots.suffix(window).map { snapshot -> String in
            let issues = snapshot.measures["violations"] ?? "—"
            let coverage = snapshot.measures["coverage"].map { "\($0)%" } ?? "—"
            return "\(snapshot.date.prefix(19))  issues \(issues)  coverage \(coverage)"
        }
        let changes = try await Oilbird.changeSinceLast(projectKey: project)
        // ⚠ One analysis has nothing before it, and "nothing changed" reads to
        // an agent as "no regressions" for a project measured exactly once.
        if snapshots.count < 2 {
            lines.append("This is the only analysis, so there is nothing to compare it with.")
        } else {
            lines.append(
                changes.isEmpty
                    ? "Nothing changed since the analysis before this one."
                    : "Since the last analysis: "
                        + changes.map(\.summary).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// `oilbird_projects`.
    static func projects(_ arguments: [String: Any]) async throws -> String {
        try await Oilbird.ensureRunning()
        let found = try await Oilbird.projects()
        guard !found.isEmpty else { return "Nothing has been scanned yet." }
        return found.map { "\($0.key)  \($0.name)" }.joined(separator: "\n")
    }

    /// `oilbird_api`.
    static func api(_ arguments: [String: Any]) async throws -> String {
        let action = (arguments["action"] as? String) ?? "list"
        switch action {
        case "list":
            let catalogue = try await Oilbird.apiCatalogue()
            let query = (arguments["query"] as? String) ?? ""
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let services = catalogue.services
                    .map { "\($0.name)  \($0.endpoints) calls  \($0.about)" }
                    .joined(separator: "\n")
                return """
                    \(catalogue.endpoints.count) endpoints across \
                    \(catalogue.services.count) services, read from this server. Not \
                    all of them can work on it — one machine, one user, Community \
                    Build — and the ones that cannot say so in their own words when \
                    called. Search with a query, or ask for one with action "show".

                    \(services)
                    """
            }
            let found = catalogue.matching(query)
            guard !found.isEmpty else {
                return "No endpoint matches \(query). Omit the query to list the services."
            }
            let rows = found.prefix(60)
                .map { "\($0.path)  \($0.post ? "writes" : "reads")  \($0.summary)" }
                .joined(separator: "\n")
            return found.count > 60
                ? rows + "\n\n\(found.count - 60) more — narrow the query."
                : rows
        case "show":
            let path = try required(arguments, "path", "an endpoint path such as api/rules/create")
            let catalogue = try await Oilbird.apiCatalogue()
            guard let endpoint = catalogue.endpoint(path) else {
                return Oilbird.unknownEndpoint(APICatalogue.normalise(path), in: catalogue)
            }
            let parameters =
                endpoint.parameters.isEmpty
                ? "It takes no parameters."
                : endpoint.parameters.map { parameter -> String in
                    let need = parameter.required ? "required" : "optional"
                    let values =
                        parameter.possibleValues.isEmpty
                        ? parameter.description
                        : "one of: " + parameter.possibleValues.joined(separator: ", ")
                    return "\(parameter.key)  \(need)  \(values)"
                }.joined(separator: "\n")
            return """
                \(endpoint.path)  \(endpoint.post ? "writes" : "reads")\
                \(endpoint.unsupported ? "  unsupported: SonarSource marks it internal" : "")
                \(endpoint.summary)

                \(parameters)
                """
        case "call":
            let path = try required(arguments, "path", "an endpoint path such as api/rules/create")
            let given = (arguments["parameters"] as? [String: Any]) ?? [:]
            // Numbers and booleans arrive as themselves through JSON, and
            // the API takes strings. Coerced rather than refused: an agent
            // sending `ps: 10` has made no mistake worth a round trip.
            var parameters: [String: String] = [:]
            for (key, value) in given {
                if let text = value as? String {
                    parameters[key] = text
                } else if let flag = value as? Bool {
                    parameters[key] = flag ? "true" : "false"
                } else {
                    parameters[key] = String(describing: value)
                }
            }
            let answer = try await Oilbird.apiCall(path: path, parameters: parameters)
            return answer.isEmpty
                ? "Done — the server accepted it and returned nothing." : answer
        default:
            return "`\(action)` is not one of: list, show, call."
        }
    }

    /// `oilbird_version`.
    static func version(_ arguments: [String: Any]) async throws -> String {
        // Starts nothing, for the same reason `oilbird_doctor` starts
        // nothing: "what am I running?" must be answerable without
        // spending 1.6 GB and forty seconds to answer it.
        let build = Oilbird.build
        let stamp = build.commit.map { " (\($0))" } ?? ""
        let pins = try Oilbird.pinned().map { "\($0.id)  \($0.version)  \($0.licence)" }
        return
            (["oilbird \(build.version)\(stamp)"] + pins
            + ["", "Pinned by this build. oilbird_doctor says what is installed."])
            .joined(separator: "\n")
    }
}
