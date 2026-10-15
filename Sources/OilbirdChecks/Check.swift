import Foundation

/// One rule, its proof that it can fail, and what it found.
///
/// Ported from the twelve `scripts/check-*.py` the gates used to be. The
/// port is not a translation: `selfTest()` is separated from `run()` and
/// called FIRST, where in Python the self-test sat at the bottom of the file
/// and ran after the findings had been gathered. A proof that arrives after
/// the verdict proves nothing about the verdict.
protocol Check: Sendable {
    /// What it reports under, and what `oilbird-checks <name>` selects.
    var name: String { get }

    /// One line saying what this holds, for `oilbird-checks --list`.
    var holds: String { get }

    /// Makes the rule fail on purpose, and throws `SelfTest` if it will not.
    ///
    /// E5. A gate that cannot be made to fail reports the absence of a check
    /// and not the absence of a problem, and the two read identically at the
    /// exit code.
    func selfTest() throws

    /// Runs the rule over the working copy.
    func run() throws -> Report
}

/// What a gate read, and what it found in it.
struct Report {
    /// Printed whether or not anything was found: the subject, counted. A
    /// gate reporting clean over nothing is the failure mode these exist to
    /// avoid, and a count is what makes that visible in a log.
    var summary: String

    /// Each one a reason the build should stop. Non-empty means exit 1.
    var findings: [String] = []

    /// Said out loud above the findings. Where a gate legitimately checked
    /// nothing — no engine installed, nothing declared — it says so here and
    /// passes, rather than passing silently.
    var notes: [String] = []

    /// Set when a gate deliberately did not run its rule. It passes, and the
    /// summary line says "NOT CHECKED" rather than "clean".
    var skipped = false
}

/// The subject is not the shape the rule was written against.
///
/// Exit 2, distinct from a finding: there is nothing to fix in the code under
/// test until the gate itself is brought up to date, and reporting it as a
/// violation would send somebody looking in the wrong file.
struct Shape: Error {
    let said: String
    init(_ said: String) { self.said = said }
}

/// The rule could not be made to fail (E5).
struct SelfTest: Error {
    let said: String
    init(_ said: String) { self.said = said }
}
