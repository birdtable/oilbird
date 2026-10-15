import Foundation
import OilbirdKit
import OilbirdModel

// OilbirdMCP is composition only: JSON-RPC in, an OilbirdKit call, JSON out.

// It adds NO capability the CLI lacks: every tool here has a verb, and a
// behaviour existing only in MCP is a defect. An agent and a shell script
// cannot disagree about what Oilbird can do.

// The agent never receives a credential: it asks for issues, and the facade
// loads the token, injects it and returns data.

@main
struct OilbirdMCP {
    static func main() async {
        await Server().serve()
    }
}

/// JSON-RPC 2.0 over stdio, framed by newline-delimited JSON.
///
/// ⚠ **This server never holds the engine open.** An MCP session lasts as
/// long as the editor is open, so treating "connected" as "in use" would
/// silently turn the user's 30-minute setting into "never" — for exactly the
/// audience that drives Oilbird programmatically. Each tool call starts the
/// engine if it needs one and attaches only for its own duration: the app
/// and the engine have separate lifetimes.
///
/// The server itself stays reachable throughout, because an agent that cannot
/// ask whether Oilbird is there without paying 1.6 GB is not reachable in any
/// useful sense.
struct Server {
    func serve() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                let data = line.data(using: .utf8),
                let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let response = await handle(request) { emit(response) }
        }
    }

    func handle(_ request: [String: Any]) async -> [String: Any]? {
        let method = request["method"] as? String ?? ""
        let id = request["id"]

        switch method {
        case "initialize":
            return reply(
                id,
                [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "oilbird", "version": "0.1.0"],
                ])

        case "tools/list":
            return reply(id, ["tools": Tools.definitions])

        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return reply(
                    id,
                    [
                        "content": [
                            [
                                "type": "text", "text": try await Tools.call(name, arguments),
                            ]
                        ]
                    ])
            } catch let error as Oilbird.Error {
                // The recovery goes to the agent too: an agent that knows the
                // action can take it, where "failed" leaves it guessing.
                return failure(id, "\(error.detail) — \(error.recovery.actionLabel)")
            } catch {
                return failure(id, String(describing: error))
            }

        // Notifications carry no id and expect no reply.
        case _ where id == nil:
            return nil

        default:
            return failure(id, "unknown method '\(method)'")
        }
    }

    func reply(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    func failure(_ id: Any?, _ message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "error": ["code": -32000, "message": message],
        ]
    }

    func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

enum Tools {
    /// Computed, not stored: `[[String: Any]]` is not Sendable, and a stored
    /// global would be shared mutable state under Swift 6. Built once per
    /// `tools/list`, which happens once per session.
    static var definitions: [[String: Any]] {
        [
            [
                "name": "oilbird_doctor",
                "description":
                    "Check every dependency Oilbird needs by running it, not by looking for it. "
                    + "Returns each dependency's state: missing, present or corrupt.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "oilbird_scan",
                "description":
                    "Analyse a local project directory. Reports whether the scan was degraded — "
                    + "a JVM project without its own build toolchain is analysed without coverage, "
                    + "and that is stated rather than hidden.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to the project"],
                        "detach": [
                            "type": "boolean",
                            "description":
                                "Optional. Start the scan and return its key immediately "
                                + "rather than waiting. A large repository takes minutes; "
                                + "read progress with oilbird_follow.",
                        ],
                    ],
                    "required": ["path"],
                ],
            ],
            [
                "name": "oilbird_scans",
                "description":
                    "What is running and what has run: phase and elapsed time for a scan in "
                    + "flight, verdict and size for one that finished. Reads the disk and "
                    + "starts nothing, so it is safe to poll. There is deliberately no "
                    + "follow tool — attaching a terminal to a stream is not something an "
                    + "agent needs: call oilbird_scan and wait for its result, or poll this "
                    + "for a scan another client started. Pass `stop` to end a running one; "
                    + "whatever it has already uploaded is kept.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "stop": [
                            "type": "string",
                            "description": "Optional: the project key of a running scan to end",
                        ]
                    ],
                ],
            ],
            [
                "name": "oilbird_issues",
                "description": "The issues found in a project by its last scan.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "The project key"],
                        "severities": [
                            "type": "array", "items": ["type": "string"],
                            "description":
                                "Optional. BLOCKER, HIGH, MEDIUM, LOW, INFO on a server in "
                                + "MQR mode, or BLOCKER, CRITICAL, MAJOR, MINOR, INFO on one "
                                + "in standard mode. oilbird_summary reports which, and its "
                                + "counts use the same words.",
                        ],
                        "limit": [
                            "type": "integer",
                            "description":
                                "Optional, default \(Self.issuePage). The worst N are "
                                + "returned; 0 means every one, which on a large project is "
                                + "tens of thousands of tokens.",
                        ],
                    ],
                    "required": ["project"],
                ],
            ],
            [
                "name": "oilbird_configure",
                "description":
                    "Read or set what a project is called. Called with only a project, it "
                    + "reports the chosen name. SonarQube has no rename endpoint, so a name "
                    + "set here is applied by the next scan of that project, not now.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "The project key"],
                        "name": [
                            "type": "string",
                            "description":
                                "Optional. What to call it from its next scan. An empty "
                                + "string puts it back to its directory name.",
                        ],
                        "tags": [
                            "type": "array", "items": ["type": "string"],
                            "description": "Optional. Replaces the project's tags.",
                        ],
                        "newCode": [
                            "type": "string",
                            "description":
                                "Optional. A number of days, like \"30\", or \"previous\" "
                                + "for since the previous version. This is what a quality "
                                + "gate scores.",
                        ],
                        "exclusions": [
                            "type": "array", "items": ["type": "string"],
                            "description":
                                "Optional. Glob patterns this project never analyses, like "
                                + "\"generated/**\". Replaces the project's list.",
                        ],
                        "branch": [
                            "type": "string",
                            "description":
                                "Optional. Renames the one branch. Community Build analyses "
                                + "everything onto a single branch, so this is a label, not "
                                + "a choice between branches.",
                        ],
                    ],
                    "required": ["project"],
                ],
            ],
            [
                "name": "oilbird_follow",
                "description":
                    "How a scan is going, or how it went. Returns the end of its output and "
                    + "its state, and returns straight away — ask again to see more. Starts "
                    + "no engine.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": [
                            "type": "string",
                            "description": "The key oilbird_scan handed back",
                        ],
                        "lines": [
                            "type": "integer",
                            "description":
                                "Optional, default \(Self.followTail). The last N lines; "
                                + "0 for the whole log.",
                        ],
                    ],
                    "required": ["project"],
                ],
            ],
            [
                "name": "oilbird_quality_gate",
                "description": "A project's quality gate verdict: OK, ERROR, or NONE if never scanned.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["project": ["type": "string"]],
                    "required": ["project"],
                ],
            ],
            [
                "name": "oilbird_status",
                "description":
                    "Whether the analysis engine is running, paused, not set up, or recorded "
                    + "but not answering. Does NOT start it — asking whether Oilbird is there "
                    + "must not cost the 15 seconds and 1.6 GB that starting it does.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "oilbird_summary",
                "description":
                    "How a project actually is, in one call: quality gate with its conditions, "
                    + "lines, coverage, duplication, complexity, debt, and issue counts by "
                    + "severity and type. Use this instead of listing every issue to judge a "
                    + "codebase — it is one request rather than thousands of rows.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "The project key"]
                    ],
                    "required": ["project"],
                ],
            ],
            [
                "name": "oilbird_log",
                "description":
                    "Oilbird's own log. Every failure it reports names this as the next step, "
                    + "so read it when something went wrong and the message was not enough.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "lines": [
                            "type": "integer",
                            "description": "How many trailing lines (default 80)",
                        ]
                    ],
                ],
            ],
            [
                "name": "oilbird_forget",
                "description":
                    "Remove a project and its results. Scanning a throwaway directory leaves a "
                    + "project behind otherwise, and nothing else can remove it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "The project key"]
                    ],
                    "required": ["project"],
                ],
            ],
            [
                "name": "oilbird_history",
                "description":
                    "How a project has changed across its past analyses, and what moved since "
                    + "the one before. Use this after fixing something to confirm it actually "
                    + "improved — counting the issues that remain does not tell you that.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "The project key"]
                    ],
                    "required": ["project"],
                ],
            ],
            [
                "name": "oilbird_projects",
                "description": "Every project scanned so far.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                // ⚠ ONE tool, not one per endpoint: a client loads every tool's
                // schema before the first question, so 250 of them spend the window
                // on a catalogue. Discovery is an action here, not a schema.
                "name": "oilbird_api",
                "description":
                    "The whole of SonarQube's web API. `list` finds endpoints (no query "
                    + "lists the services), `show` gives one endpoint's parameters and which "
                    + "are required, `call` performs it. The catalogue is read from the "
                    + "running server, so it matches this SonarQube exactly. Use this for "
                    + "anything the other tools do not cover: quality profiles, custom "
                    + "rules, issue transitions, hotspots, webhooks, quality gate "
                    + "conditions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["list", "show", "call"],
                            "description": "list, show or call.",
                        ],
                        "path": [
                            "type": "string",
                            "description":
                                "The endpoint, as `api/rules/create`. Required for show and "
                                + "call.",
                        ],
                        "query": [
                            "type": "string",
                            "description":
                                "For list: words that must all appear in the path or the "
                                + "summary, as `rule create`. Omit to list the services.",
                        ],
                        "parameters": [
                            "type": "object",
                            "description":
                                "For call: the endpoint's parameters, as given by show. "
                                + "Values are strings.",
                            "additionalProperties": ["type": "string"],
                        ],
                    ],
                    "required": ["action"],
                ],
            ],
            [
                "name": "oilbird_version",
                "description":
                    "Which build of Oilbird this is, and the versions of SonarQube, the JDK, "
                    + "PostgreSQL and the scanner it pins. Answers without starting anything.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
        ]
    }

    /// A string argument that is present and not blank.
    ///
    /// ⚠ `arguments["project"] as? String` accepts `""`, and an empty
    /// project key is not a harmless nothing: `componentKeys=` is ignored
    /// by SonarQube, so the query comes back with every issue on the server
    /// reported under the empty key as though they belonged to one. An agent
    /// cannot tell that apart from a real answer. The CLI has the same guard.
    static func required(_ arguments: [String: Any], _ key: String, _ what: String) throws
        -> String
    {
        let given = (arguments[key] as? String) ?? ""
        guard !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Oilbird.Error(
                .verifyFailed, "\(what) is required, and an empty one is not one.",
                recovery: .chooseAlternative("Pass \(what)"))
        }
        return given
    }

    /// ⚠ **Arguments are read BEFORE the engine is started, and were not.**
    /// Every tool that takes one began `try await Oilbird.ensureRunning()`
    /// and validated afterwards, so a request that could never be honoured
    /// paid a fifteen-second engine start first — and on a machine with
    /// nothing installed it came back "PostgreSQL is not installed" for a
    /// message whose real problem was a number where a list of severities
    /// goes. The CLI has had this the right way round since `scan` learned
    /// not to start an engine for a mistyped path.
    ///
    /// A flag, or a refusal. Absent is false.
    ///
    /// ⚠ The same rule as `count` and `strings`: `as? Bool ?? false` turns
    /// `"detach": "true"` — which a client that stringifies everything will
    /// send — into "no", silently, and the agent waits out a scan it asked
    /// to be given back immediately.
    static func flag(_ arguments: [String: Any], _ key: String) throws -> Bool {
        guard let given = arguments[key] else { return false }
        switch given {
        case let value as Bool: return value
        case let value as Int: return value != 0
        case let value as String:
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: break
            }
        default: break
        }
        throw Oilbird.Error(
            .verifyFailed, "'\(given)' is not true or false for \(key).",
            recovery: .chooseAlternative("Pass true or false"))
    }

    /// How many lines of a scan's log `oilbird_follow` returns.
    ///
    /// ⚠ Bounded for the reason `issuePage` is: a finished scan's log is
    /// about 120 lines of scanner INFO, and an agent polling it every few
    /// seconds would pay for all of them every time.
    static let followTail = 40

    /// How many issues a tool result carries unless asked for more.
    ///
    /// ⚠ Fifty rather than five hundred. This is read by a model with a
    /// context window, not scrolled by a person: the question an agent asks
    /// is "what should I fix", and the answer to that is the worst handful,
    /// with the real total beside it and the way to see more.
    static let issuePage = 50

    /// A list of strings, however a client spelt it — or a refusal.
    ///
    /// ⚠ **`arguments["severities"] as? [String] ?? []` turned every
    /// wrong-typed value into "no filter".** `"severities": "BLOCKER"` — a
    /// bare string, which several clients send for a single value — asked
    /// for five issues and returned all 1,559, about 80,000 tokens, with a
    /// header that said `1559 issue(s)` and nothing at all to say the filter
    /// had been dropped. Silence is the worst possible answer here: the
    /// agent cannot see the request it did not make.
    ///
    /// A bare string is ACCEPTED as one value, because that is plainly what
    /// was meant and refusing it would be pedantry. Anything else is refused
    /// by name.
    static func strings(_ arguments: [String: Any], _ key: String) throws -> [String] {
        guard let given = arguments[key] else { return [] }
        switch given {
        case let list as [String]: return list
        case let one as String: return one.isEmpty ? [] : [one]
        case let list as [Any]:
            let strings = list.compactMap { $0 as? String }
            guard strings.count == list.count else { break }
            return strings
        default: break
        }
        throw Oilbird.Error(
            .verifyFailed,
            "'\(given)' is not a list of \(key). Pass a list of strings, like "
                + "[\"BLOCKER\"], or leave it out for all of them.",
            recovery: .chooseAlternative("Pass a list of strings"))
    }

    /// A whole, non-negative count, or a refusal naming what was sent.
    ///
    /// ⚠ `arguments["lines"] as? Int ?? 80` turned every wrong-typed value
    /// into the default. JSON also makes `5` a `Double` through some clients,
    /// so the cast alone refused perfectly good numbers — which is why this
    /// accepts anything that IS a whole number and refuses only what is not.
    static func count(_ arguments: [String: Any], _ key: String, default fallback: Int) throws
        -> Int
    {
        guard let given = arguments[key] else { return fallback }
        let number: Int? =
            switch given {
            case let value as Int: value
            case let value as Double: value == value.rounded() ? Int(value) : nil
            case let value as String: Int(value)
            default: nil
            }
        guard let number, number >= 0 else {
            throw Oilbird.Error(
                .verifyFailed,
                "'\(given)' is not a number of \(key). Pass a whole number of \(key), "
                    + "or leave it out for \(fallback).",
                recovery: .chooseAlternative("Pass a whole number"))
        }
        return number
    }

    /// One tool call, routed to the method that answers it.
    ///
    /// ⚠ Was one 590-line switch with every tool's body inline, at
    /// complexity 73. The bodies are methods now and this is the routing
    /// table, which is the only thing a reader comes here for.
    static func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        switch name {
        case "oilbird_doctor": try await doctor(arguments)
        case "oilbird_scan": try await scan(arguments)
        case "oilbird_configure": try await configure(arguments)
        case "oilbird_follow": try await follow(arguments)
        case "oilbird_scans": try await scans(arguments)
        case "oilbird_issues": try await issues(arguments)
        case "oilbird_quality_gate": try await qualityGate(arguments)
        case "oilbird_status": try await status(arguments)
        case "oilbird_summary": try await summary(arguments)
        case "oilbird_log": try await log(arguments)
        case "oilbird_forget": try await forget(arguments)
        case "oilbird_history": try await history(arguments)
        case "oilbird_projects": try await projects(arguments)
        case "oilbird_api": try await api(arguments)
        case "oilbird_version": try await version(arguments)
        default:
            throw Oilbird.Error(
                .verifyFailed, "There is no tool called '\(name)'.",
                recovery: .reportIssue("Check the tool list"))
        }
    }
}
