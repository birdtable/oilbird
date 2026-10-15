import Foundation

/// Every failure Oilbird can surface.
///
/// No dead ends — enforced here rather than by review: `recovery`
/// has no default and is not optional, so `OilbirdError(.diskFull, "…")`
/// does not compile. A failure with nothing the user can do about it is not
/// representable.
public struct OilbirdError: Error, Sendable {
    /// Machine-readable. What the CLI maps to an exit code and MCP returns.
    public let cause: Cause
    /// One sentence, for a person. Never parsed — prose is for people.
    public let detail: String
    /// What the user can do. Required.
    public let recovery: Recovery
    /// Log only, never shown: exit codes, paths, the child's stderr.
    public let underlying: String?

    public init(_ cause: Cause, _ detail: String, recovery: Recovery, underlying: String? = nil) {
        self.cause = cause
        self.detail = detail
        self.recovery = recovery
        self.underlying = underlying
    }
}

extension OilbirdError {
    public enum Cause: String, CaseIterable, Sendable {
        case offline
        case checksumMismatch
        case diskFull
        case extractionFailed
        /// Gatekeeper killed a downloaded binary. Surfaces as SIGKILL/137 with
        /// no message, so it must be named rather than described.
        case quarantined
        case clusterCorrupt
        case clusterHeldByAnother
        case serverUnhealthy
        case verifyFailed
        /// The server rejected Oilbird's own credential.
        ///
        /// ⚠ Distinct from `verifyFailed` because the user can do nothing
        /// about it and Oilbird can do everything about it. A revoked token
        /// used to arrive as a bare `401` with an EMPTY body, which fell into
        /// the generic 4xx branch and read "The server refused that request.
        /// → Check the arguments" — advice that cannot work, since no
        /// argument the caller changes will mint a token. Oilbird holds the
        /// admin password, so the answer is to mint a new one, not to ask.
        case credentialRejected
        /// The check could not be **performed** — which is not a verdict about
        /// the dependency. The scanner cannot demonstrate that it works without
        /// a server to report to, and every other cause here says something is
        /// wrong with the artefact. Filing "not checked yet" under one of those
        /// told a user their scanner was corrupt when it was fine, and sent
        /// `install` to fetch 11 MiB that would change nothing.
        ///
        /// A caller distinguishes the two by this case and nothing else, so it
        /// belongs to the error and not to any one dependency.
        case notCheckable
        /// The scanned project's own toolchain is missing, so the scan ran
        /// without coverage. Reported, never silently substituted.
        case toolchainMissing
        case originMoved
    }

    /// What the user can do about it.
    ///
    /// There is deliberately no case meaning "nothing" — that state is what
    /// a dead end is. `reportIssue` is the floor, and it is still an action.
    public enum Recovery: Sendable, Equatable {
        case retry(String)
        case chooseAlternative(String)
        case freeSpace(needed: Int64, available: Int64)
        case reinstall(DependencyID)
        case waitForHolder(pid: Int32, since: Date)
        case reportIssue(String)

        /// The button. Never empty — a control with no label is a dead end
        /// wearing a button.
        public var actionLabel: String {
            switch self {
            case .retry(let label): label
            case .chooseAlternative(let label): label
            case .freeSpace: "Retry"
            case .reinstall: "Reinstall"
            case .waitForHolder: "Wait"
            case .reportIssue(let label): label
            }
        }
    }
}
