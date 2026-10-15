import Foundation
import SwiftTUI
import SwiftTUIArguments
import SwiftTUICLI
import SwiftTUIRuntime

/// The issue browser as a session that owns the screen.
///
/// ⚠ `OilbirdCLI` is not itself an `App`, and does not need to be.
/// `TerminalRunner.run` takes an INSTANCE, and `SwiftTUIRuntime.App` asks only
/// for `nonisolated init()` and a body — so one verb can take the screen while
/// every other verb goes on rendering a string and exiting. The alternative
/// was rewriting 2,400 lines of dispatch before the first interactive screen
/// could be seen.
///
/// ⚠ Stored properties with defaults, rather than the shared mutable static
/// the framework's own example reaches for. `init()` exists because the
/// protocol demands one and is never the initialiser that runs; giving the
/// fields defaults satisfies it without a process-wide `var` that every
/// relaunch writes through and one branch of `body` reads as "not configured
/// yet".
/// ⚠ `SwiftTUIRuntime.App`, spelled out. `SwiftTUI` re-exports a second `App`
/// that is also a command-line command, and a bare `App` is ambiguous between
/// them. The runtime one is what this wants: a scene, with no argument parsing
/// of its own, because the CLI has already parsed the arguments.
public struct BrowserApp: SwiftTUIRuntime.App {
    var project: String = ""
    var issues: [IssueRow] = []
    var severities: [String] = []

    nonisolated public init() {}

    nonisolated public init(project: String, issues: [IssueRow], severities: [String]) {
        self.project = project
        self.issues = issues
        self.severities = severities
    }

    @MainActor public var body: some Scene {
        WindowGroup("oilbird") {
            IssuesBrowser(project: project, issues: issues, severities: severities)
        }
        // Ctrl-C is the framework's, and it restores the shell. `q` is the
        // app's, and means the same thing here because nothing is unsaved.
        .exitOnKeys([
            KeyPress(.character("c"), modifiers: .ctrl),
            KeyPress(.character("q")),
        ])
    }
}

extension Frames {
    /// Hands the screen to the browser until the reader leaves.
    ///
    /// ⚠ Returns nothing yet. Multi-select marks rows and the marks die with
    /// the session; carrying them out to a bulk transition is the next piece,
    /// and saying otherwise here would be a comment that is simply untrue.
    @MainActor public static func browse(
        project: String, issues: [IssueRow], severities: [String]
    ) async throws {
        try await TerminalRunner.run(
            BrowserApp(project: project, issues: issues, severities: severities),
            configuration: (try? SwiftTUIOptions.parse([]))?
                .runtimeConfiguration(
                    environment: ProcessInfo.processInfo.environment,
                    isStdoutTTY: RenderOnce.standardOutputIsTTY()) ?? .default)
    }
}
