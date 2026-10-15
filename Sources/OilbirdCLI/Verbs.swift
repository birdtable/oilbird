import Foundation
import OilbirdKit
import OilbirdModel

/// One row of `oilbird doctor --json`.
///
/// ⚠ A named type and not a `(String, String, String)`. All three were
/// strings, so a switch arm that returned them in the wrong order compiled
/// and printed a version where an action goes.
struct DoctorRow {
    let state: String
    var detail: String = ""
    var action: String = ""
}

/// One parsed command line, handed to the verb that answers it.
///
/// ⚠ The verbs were 22 arms of one 1,215-line function at complexity 191,
/// each reading a dozen locals out of the scope around it. That is how
/// `case "history"` came to be written twice without anyone seeing it. The
/// locals are fields now, so a verb takes what it needs and nothing reaches
/// past its own body.
struct Invocation {
    let arguments: [String]
    let verb: String
    let positional: [String]
    let json: Bool
    let severities: [String]
    let known: Set<String>
    /// The value a `--flag` consumed, so it is not read as a verb's argument.
    let valueAfter: (String) -> String?
}

extension Invocation {
    /// Every flag oilbird accepts, listed once.
    static let knownFlags: Set<String> = [
        "--json", "--force", "--severity", "--detach", "--stop", "--browse",
        "--name", "--tags", "--new-code", "--exclude", "--branch", "--call",
    ]

    /// Every flag that takes a value, so `positional` can exclude all of them.
    ///
    /// ⚠ Listed once, beside the flags themselves. A flag added there and
    /// forgotten here reads its own value as the verb's argument, which is how
    /// `oilbird configure --name "Storefront" storefront-9af0` configured a
    /// project called `Storefront` that does not exist.
    static let valueFlags = ["--name", "--tags", "--new-code", "--exclude", "--branch"]

    /// Every `--severity`, in either spelling, uppercased.
    ///
    /// ⚠ `--severity` was PRINTED AS ADVICE and then refused. When the issue
    /// list hit the server's ten-thousand ceiling the CLI said "Narrow with
    /// `--severity` to see the rest", and typing that exited 2. The capability
    /// existed the whole time — `Oilbird.issues(projectKey:severities:)` — and
    /// was wired on the MCP surface only, so an agent could filter and a shell
    /// script could not. The CLI is the full surface; MCP adds nothing to it.
    /// Repeatable: `--severity BLOCKER --severity CRITICAL`.
    static func severities(in arguments: [String]) -> [String] {
        var found: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            defer { index = arguments.index(after: index) }
            let argument = arguments[index]
            if argument.hasPrefix("--severity=") {
                found.append(String(argument.dropFirst("--severity=".count)))
            } else if argument == "--severity", arguments.index(after: index) < arguments.endIndex {
                found.append(arguments[arguments.index(after: index)])
            }
        }
        return found.map { $0.uppercased() }.filter { !$0.isEmpty }
    }

    /// One command line, or nil when it names no verb.
    static func parse(_ arguments: [String]) -> Invocation? {
        let severities = severities(in: arguments)

        /// The value a `--flag` consumed, so it is not read as a positional.
        func valueAfter(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, !arguments[next].hasPrefix("--") else { return nil }
            return arguments[next]
        }

        // The same reasoning for `--severity`'s values: `oilbird issues k
        // --severity BLOCKER` must not read `BLOCKER` as a second positional.
        let severityValues = Set(severities.map { $0.uppercased() })
        let flagValues = Set(valueFlags.compactMap(valueAfter))
        let positional = arguments.filter {
            !$0.hasPrefix("--") && !severityValues.contains($0.uppercased())
                && !flagValues.contains($0)
        }
        guard let verb = positional.first else { return nil }
        return Invocation(
            arguments: arguments, verb: verb, positional: positional,
            json: arguments.contains("--json"), severities: severities,
            known: knownFlags, valueAfter: valueAfter)
    }
}
