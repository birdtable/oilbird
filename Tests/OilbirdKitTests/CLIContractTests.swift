import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

/// The CLI's contract, exercised against the real binary.
///
/// These cannot be unit tests: the behaviour that broke lives in argument
/// parsing before any library call, and the failure was that a flag ran a
/// verb. Only running the thing can catch that.
func cliContractTests() {
    Harness.suite("CLI — a flag must never run a verb") {
        guard let binary = oilbirdBinary() else {
            Harness.expectTrue(false, "no oilbird binary beside the test runner")
            return
        }

        // ⚠ Dropping an unrecognised flag and running anyway makes
        // `oilbird down --help` stop the server. `down` is under test because
        // it is the destructive one.
        Harness.test("--help does not run the verb it follows") {
            let result = run(binary, ["down", "--help"])
            Harness.expectEqual(result.status, 0, "--help should succeed")
            Harness.expectTrue(
                result.output.contains("oilbird —"), "--help did not print usage")
            Harness.expectTrue(
                !result.output.contains("stopped"),
                "--help ran `down` — probing the tool changed its state")
        }

        // ⚠ All three spellings, because two of them did not work: the help
        // check sat inside a scan for arguments beginning `--`, so its `-h`
        // and `help` arms were unreachable dead code.
        Harness.test("-h, help and --help all reach the help screen") {
            for spelling in ["-h", "help", "--help"] {
                let result = run(binary, [spelling])
                Harness.expectEqual(result.status, 0, "`oilbird \(spelling)` did not succeed")
                Harness.expectTrue(
                    result.output.contains("oilbird —"),
                    "`oilbird \(spelling)` printed no help: \(result.output.prefix(60))")
            }
        }

        // ⚠ The example must be a flag that really does not exist. Using
        // `--severity` here passed for the wrong reason once it was
        // implemented, and it was the defect rather than the contract.
        Harness.test("an unknown flag is refused rather than ignored") {
            let result = run(binary, ["issues", "demo", "--nonsense"])
            Harness.expectTrue(
                result.status != 0,
                "an unimplemented flag reported success while doing nothing")
            Harness.expectTrue(
                result.output.contains("--nonsense"),
                "the refusal did not name the flag it refused")
        }

        // The flag that used to stand for "unknown" has to work, or the advice
        // beside a truncated list is a dead end.

        // ⚠ Asserted as "both runs fail the same way with the same code", not "the
        // output does not mention it": a failure screen ends with the command to
        // re-run.
        Harness.test("--severity is accepted, and narrows what it is given") {
            let refused = run(binary, ["issues", "demo", "--severity", "BLOCKER"])
            Harness.expectTrue(
                !refused.output.contains("is not a flag oilbird knows"),
                "--severity is still refused by the flag check")
            let plainRun = run(binary, ["issues", "demo"])
            Harness.expectEqual(
                refused.status, plainRun.status,
                "the flag changed the exit code, so it was not merely a filter")
            Harness.expectEqual(
                refused.output.replacingOccurrences(of: " --severity BLOCKER", with: ""),
                plainRun.output,
                "the flag changed the failure, so it was not understood as a filter")
        }

        // A mistyped verb that suggests nothing sends someone to `--help` for
        // a word they already know.

        // ⚠ A count that will not parse is REFUSED: replaced with the default,
        // `oilbird log abc` prints eighty lines and looks like it worked, and
        // `log 0` prints one, which reads as a quiet log.
        Harness.test("a line count that is not one is refused, not guessed") {
            for bad in ["abc", "-5", "3.5", ""] {
                let result = run(binary, ["log", bad])
                Harness.expectEqual(
                    result.status, 2, "`log \(bad)` was accepted and did something else")
                Harness.expectTrue(
                    result.output.contains("not a number of lines"),
                    "`log \(bad)` did not say what was wrong: \(result.output)")
            }
            // Zero is a coherent request with an empty answer, and says so
            // rather than printing a line.
            let none = run(binary, ["log", "0"])
            Harness.expectEqual(none.status, 0, "`log 0` is not an error")
            Harness.expectTrue(
                none.output.contains("0 lines"),
                "`log 0` did not say it printed nothing: \(none.output)")
            Harness.expectTrue(
                !none.output.contains(" INFO ") && !none.output.contains(" DEBUG "),
                "`log 0` printed a log line: \(none.output)")
        }

        Harness.test("a near-miss verb is offered the verb it nearly is") {
            let result = run(binary, ["sacn", "/tmp"])
            Harness.expectTrue(result.status != 0, "a typo was accepted")
            Harness.expectTrue(
                result.output.contains("scan"),
                "unknown command named no alternative: \(result.output)")
        }

        // ⚠ Usage errors wrote to stderr only, so `--json` piped into a
        // parser died on empty input rather than on a readable object.
        Harness.test("a usage error is machine-readable when asked to be") {
            let result = run(binary, ["nonsense-verb", "--json"])
            Harness.expectTrue(result.status != 0, "an unknown verb succeeded")
            Harness.expectTrue(
                result.output.contains("\"cause\"") && result.output.contains("usage"),
                "no JSON on a usage error: \(result.output)")
        }

        // The recovery on half of Oilbird's failures is "Show log". An action
        // naming a command that does not exist is a dead end wearing a
        // button.
        Harness.test("every verb a recovery action names actually exists") {
            for verb in ["log", "forget", "status", "idle", "up", "down", "doctor"] {
                let result = run(binary, [verb, "--json"])
                Harness.expectTrue(
                    !result.output.contains("unknown command"),
                    "a recovery points at `\(verb)`, which the CLI does not have")
            }
        }

        // ⚠ Asserted here AND in the `parity` check: that reads source and
        // this reads the running binary, so a tool declared and not
        // implemented passes one and fails the other.

        // ⚠ One unbounded call returned about 80,000 tokens, and a wrong-typed
        // `severities` was discarded silently: `"BLOCKER"` as a bare string
        // returned all 1,559 issues under a header saying so.
        Harness.test("an agent cannot ask for its whole context by accident") {
            func issues(_ arguments: String) -> String {
                run(
                    mcp(from: binary), [],
                    stdin: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"#
                        + #"{"name":"oilbird_issues","arguments":{"# + arguments + "}}}"
                ).output
            }

            // ⚠ The argument is read BEFORE the server is asked: a request that
            // cannot be honoured should not reach the engine. A bare string is
            // accepted as one value, never dropped.
            let bare = issues(#""project":"fixture-none","severities":"BLOCKER""#)
            Harness.expectTrue(
                !bare.contains("not a list"),
                "a bare string severity was refused rather than honoured")

            // Anything that is not a list of strings is refused BY NAME.
            let wrong = issues(#""project":"fixture-none","severities":5"#)
            Harness.expectTrue(
                wrong.contains("not a list"), "a number was coerced into no filter")

            // And the size bound, on whatever this machine has scanned.
            let listed = run(
                mcp(from: binary), [],
                stdin: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"#
                    + #"{"name":"oilbird_projects","arguments":{}}}"#
            ).output
            guard
                let match = listed.range(
                    of: #"[A-Za-z0-9._-]+-[0-9a-f]{4}"#, options: .regularExpression)
            else { return }
            let whole = issues(#""project":"\#(String(listed[match]))""#)
            Harness.expectTrue(
                whole.count < 60_000,
                "one tool result is \(whole.count) characters; it was 319,599")
        }

        // ⚠ Claude Code does not take the JSON form, and is the likeliest
        // client of a developer tool. Both routes are generated from the same
        // resolved binary, so they cannot name different servers.
        Harness.test("the app hands out a working command as well as a config") {
            guard let command = Oilbird.mcpCommandLine(), let binary = Oilbird.mcpBinary(),
                let snippet = Oilbird.mcpClientSnippet()
            else {
                // Running from a build directory: the pane says so instead,
                // and all three are nil together.
                Harness.expectTrue(
                    Oilbird.mcpCommandLine() == nil && Oilbird.mcpClientSnippet() == nil,
                    "one route was offered without the other")
                return
            }
            Harness.expectTrue(
                command.hasPrefix("claude mcp add "), "the command is not one Claude Code takes")
            Harness.expectTrue(
                command.contains("--scope user"),
                "without a scope the server exists only where it was added")
            Harness.expectTrue(
                command.contains(Oilbird.mcpServerName), "the server has no name in the command")
            // ⚠ Quoted. The bundle is one renamed account away from a path
            // with a space in it, and a line a person pastes without reading
            // would then register a server called half of it.
            Harness.expectTrue(
                command.contains("\"\(binary.path)\""), "the path is unquoted: \(command)")
            // The two routes name one server. Written separately they are
            // two chances to point somewhere different.
            Harness.expectTrue(
                snippet.contains(binary.path), "the JSON names a different binary")
            Harness.expectNotEmpty(Oilbird.mcpConfigPath, "the config file is not named anywhere")
            Harness.expectTrue(
                Oilbird.mcpConfigPath.hasPrefix("~/"),
                "the config path is not written the way a person reads one")
        }

        Harness.test("every tool the CLI needs an agent to have is really callable") {
            for tool in [
                "oilbird_status", "oilbird_summary", "oilbird_log", "oilbird_projects",
                "oilbird_doctor",
            ] {
                let request = """
                    {"jsonrpc":"2.0","id":1,"method":"tools/call",\
                    "params":{"name":"\(tool)","arguments":{}}}
                    """
                let result = run(mcp(from: binary), [], stdin: request)
                Harness.expectTrue(
                    !result.output.contains("There is no tool called"),
                    "\(tool) is declared but not implemented")
            }
        }

        // ⚠ A count in prose is one forgotten edit from lying. It comes from
        // `Oilbird.mcpToolNames` instead, which makes that list the thing that
        // can go stale, so it is asked of the running SERVER.
        Harness.test("the tool list the window counts is the list the server publishes") {
            let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#
            let result = run(mcp(from: binary), [], stdin: request)
            guard
                let line = result.output.split(separator: "\n").first(where: {
                    $0.contains("\"tools\"")
                }),
                let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                let tools = ((parsed as? [String: Any])?["result"] as? [String: Any])?["tools"]
                    as? [[String: Any]]
            else {
                Harness.expectTrue(false, "tools/list did not answer with a tool list")
                return
            }
            Harness.expectEqual(
                tools.compactMap { $0["name"] as? String }, Oilbird.mcpToolNames,
                "Oilbird.mcpToolNames is no longer what oilbird-mcp publishes, so the "
                    + "Agents pane is counting the wrong number")
        }
    }
}

private func oilbirdBinary() -> URL? {
    let sibling = URL(filePath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "oilbird")
    return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
}

private func mcp(from oilbird: URL) -> URL {
    oilbird.deletingLastPathComponent().appending(path: "oilbird-mcp")
}

private func run(
    _ binary: URL, _ argv: [String], stdin: String? = nil
) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = binary
    process.arguments = argv
    if let stdin {
        let input = Pipe()
        process.standardInput = input
        input.fileHandleForWriting.write(Data((stdin + "\n").utf8))
        try? input.fileHandleForWriting.close()
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
