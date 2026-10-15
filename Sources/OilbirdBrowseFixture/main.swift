import Foundation
import OilbirdKit

// The issue browser over fixed issues, for the journey test to drive.

// ⚠ A separate binary, because `oilbird issues --browse` needs an engine, a
// database, a scanned project and a fetch before its first cell: a journey
// through that tests SonarQube. This starts at the browser and is hermetic.

// ⚠ Not shipped: absent from the app, from `make app` and from the verb
// table, which copies `oilbird` and `oilbird-mcp` by name.
let issues = [
    IssueRow(
        id: "1", severity: "BLOCKER", file: "src/Main.swift", line: 12,
        rule: "swift:S101", message: "Rename this class"),
    IssueRow(
        id: "2", severity: "MINOR", file: "src/Util.swift", line: nil,
        rule: "swift:S1128", message: "Remove this unused import"),
    IssueRow(
        id: "3", severity: "MAJOR", file: "test/UtilTests.swift", line: 4,
        rule: "swift:S1172", message: "Remove this unused parameter"),
]

try await Frames.browse(
    project: "fixture-project", issues: issues,
    severities: ["BLOCKER", "MAJOR", "MINOR"])
