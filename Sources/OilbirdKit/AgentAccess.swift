import Foundation
import OilbirdCore

/// How something other than a person reaches Oilbird.
///
/// ⚠ **Agents drive Oilbird, and nothing anywhere told anyone how.** Ten
/// MCP tools ship in `Contents/Helpers/oilbird-mcp` and the only way to
/// discover the binary's existence was to read the `Makefile`; the only way
/// to discover the tools was to read `OilbirdMCP.swift`. A written
/// description was tried and every line of it went wrong — it named
/// `oilbird mcp` as a verb, which it is not, and five tools that do not
/// exist.
///
/// So the snippet is GENERATED from the running bundle rather than written
/// down. A path in prose goes stale the first time the app moves; this one
/// is read out of the process that is answering the question.
extension Oilbird {
    /// The MCP server binary, beside the CLI in the bundle.
    ///
    /// Resolved exactly as `cliBinary()` is, for the reason written there —
    /// three separate readings of "where did this process come from" have
    /// each got it wrong once.
    public static func mcpBinary() -> URL? {
        guard let cli = cliBinary() else { return nil }
        let sibling = cli.deletingLastPathComponent().appending(path: mcpExecutableName)
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    /// `oilbird-mcp`, named once.
    static var mcpExecutableName: String { cliExecutableName + "-mcp" }

    /// The name a client will show for this server. Lower case and no
    /// spaces, because most clients use the key as an identifier.
    public static let mcpServerName = "oilbird"

    /// Every tool `oilbird-mcp` publishes.
    ///
    /// ⚠ **The count the window shows comes from here, not from prose.** A
    /// "Ten tools" written by hand beside a generated list goes stale with
    /// the next tool, and a settings pane exists to say what the app does
    /// rather than what it once did. Two things hold this list level with
    /// the server:
    /// the `parity` check reads both files, and
    /// `CLIContractTests` asks the running binary for `tools/list` and
    /// compares. The gate catches a rename; the test catches a tool
    /// declared and never wired up.
    public static let mcpToolNames = [
        "oilbird_doctor", "oilbird_scan", "oilbird_scans", "oilbird_issues", "oilbird_configure",
        "oilbird_follow",
        "oilbird_quality_gate", "oilbird_status", "oilbird_summary", "oilbird_log",
        "oilbird_forget", "oilbird_history", "oilbird_projects", "oilbird_api",
        "oilbird_version",
    ]

    /// Where this copy of Oilbird is running from, judged by whether a
    /// path written down today will still be there tomorrow.
    ///
    /// ⚠ The MCP snippet names the running bundle, which is right in
    /// principle and was a trap in practice: run from `dist/Oilbird.app`
    /// during development and the pane cheerfully hands over a path that
    /// `make app` deletes at the start of its next run — `rm -rf "$(APP)"`
    /// is the first line of that target. Exactly that path has been pasted
    /// into a client. The same holds for a copy still inside a DMG, in
    /// Downloads, or anywhere a person has not yet decided to keep it.
    ///
    /// So the snippet is unchanged and the WARNING is new. Refusing to
    /// show the path would be worse: someone running a build deliberately
    /// still needs it, and knows what they are doing.
    public enum InstallLocation: Sendable, Equatable {
        /// `/Applications` or `~/Applications`. A path from here is worth
        /// writing into a configuration file.
        case stable
        /// Anywhere else. The path works right now and may not survive.
        case volatile(String)
    }

    public static func installLocation(
        of bundle: URL? = nil, home: String = NSHomeDirectory()
    ) -> InstallLocation {
        guard let bundle = bundle ?? appBundle() else { return .stable }
        let parent = bundle.deletingLastPathComponent().resolvingSymlinksInPath().path
        let stable = ["/Applications", "\(home)/Applications"]
            .map { URL(filePath: $0).resolvingSymlinksInPath().path }
        return stable.contains(parent) ? .stable : .volatile(parent)
    }

    /// The `.app` this process is running inside, or nil outside a bundle.
    static func appBundle() -> URL? {
        guard let cli = cliBinary() else { return nil }
        let bundle =
            cli
            .deletingLastPathComponent()  // Helpers
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // Oilbird.app
        return bundle.pathExtension == "app" ? bundle : nil
    }

    /// What to say above the snippet, or nil when there is nothing to say.
    ///
    /// Named for the reader rather than the condition: a person looking at
    /// this needs to know the path will break and what to do, not that an
    /// enum case matched.
    public static func mcpSnippetWarning() -> String? {
        guard case .volatile(let parent) = installLocation() else { return nil }
        return "This copy of Oilbird is running from \(displayPath(parent)), not from "
            + "Applications. The path below points inside it, so it will stop working if "
            + "that copy is moved, rebuilt or deleted. Move Oilbird to Applications and "
            + "open this pane again before pasting it anywhere."
    }

    /// The one-line command that registers the server with Claude Code.
    ///
    /// ⚠ **The pane offered JSON and nothing else, and Claude Code does not
    /// take JSON.** It is a developer tool, so its likeliest client is the
    /// one the pane gave the wrong instruction for: `claude mcp add` takes
    /// a path on a command line and writes its own config. A person who
    /// pasted the snippet at it got nothing, with no error to chase.
    ///
    /// `--scope user`, so it is there in every project rather than the one
    /// directory the terminal happened to be in.
    public static func mcpCommandLine() -> String? {
        guard let binary = mcpBinary() else { return nil }
        // Quoted: the bundle sits under a path with no spaces today, and an
        // account name or a renamed Applications folder is one space away
        // from breaking a line a person pastes without reading.
        return "claude mcp add --scope user \(mcpServerName) \"\(binary.path)\""
    }

    /// Where a client that reads JSON keeps it, named rather than implied.
    ///
    /// ⚠ "Paste this into your client" named no file and no client. The
    /// snippet is Claude Desktop's shape, and the path to its config is the
    /// one fact a person needs and cannot guess.
    public static let mcpConfigPath =
        "~/Library/Application Support/Claude/claude_desktop_config.json"

    /// The JSON to paste into an MCP client's configuration.
    ///
    /// The whole object, not a fragment, so it can be pasted into an empty
    /// file as well as merged into an existing one — a fragment beginning
    /// with a bare key is not valid JSON anywhere, and a person who pastes
    /// it into an empty config gets a parse error rather than a server.
    ///
    /// `nil` when the binary is not there: a snippet naming a path that
    /// does not exist is worse than no snippet, because the failure lands
    /// in the client's log rather than here.
    ///
    /// ⚠ **Absolute, and the one displayed path in Oilbird that is.**
    /// Everywhere else a home-relative path is shortened to `~` for the
    /// person reading it (`displayPath`); here the reader is an MCP client,
    /// which spawns `command` without a shell and will not expand a tilde.
    /// The whole point of this string is that it is pasteable and correct,
    /// so it stays as the kernel will receive it.
    public static func mcpClientSnippet() -> String? {
        guard let binary = mcpBinary() else { return nil }
        // Hand-built rather than `JSONSerialization`, because a person reads this
        // before a parser does: the serialiser neither sorts keys nor indents by
        // two, and escapes `/` as `\/`.
        let quoted = binary.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
            {
              "mcpServers": {
                "\(mcpServerName)": {
                  "command": "\(quoted)"
                }
              }
            }
            """
    }

    /// The dashboard, for when the window is not what is wanted.
    ///
    /// `nil` when the engine is not running, because there is nothing at
    /// any URL to open — offering a link to a refused connection is a
    /// dead end.
    public static func dashboardURL() -> URL? {
        status().map { base($0.webPort) }
    }
}
