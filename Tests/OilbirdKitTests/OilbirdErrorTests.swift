import Foundation
import OilbirdKit
import OilbirdModel

/// No failure may be a dead end. The compiler holds most of it:
/// `recovery` has no default, so an error without one does not build. What is
/// left to test is that the recovery is *usable* — a required field holding an
/// empty label would satisfy the compiler and fail the user.
func oilbirdErrorTests() {
    Harness.suite("OilbirdError — no dead end is structural") {
        Harness.test("every recovery offers a non-empty action label") {
            let recoveries: [OilbirdError.Recovery] = [
                .retry("Retry"),
                .chooseAlternative("Point at a JDK…"),
                .freeSpace(needed: 3_200_000_000, available: 1_100_000_000),
                .reinstall(.postgres),
                .waitForHolder(pid: 4321, since: Date()),
                .reportIssue("Report an issue"),
            ]
            for recovery in recoveries {
                Harness.expectNotEmpty(recovery.actionLabel, "for \(recovery)")
            }
        }

        Harness.test("every cause can be constructed with a recovery and a sentence") {
            for cause in OilbirdError.Cause.allCases {
                let error = OilbirdError(cause, "Something went wrong.", recovery: .retry("Retry"))
                Harness.expectEqual(error.cause, cause)
                Harness.expectNotEmpty(error.detail, "for \(cause)")
                Harness.expectNotEmpty(error.recovery.actionLabel, "for \(cause)")
            }
        }

        Harness.test("underlying detail stays out of the user-facing sentence") {
            let error = OilbirdError(
                .quarantined,
                "macOS blocked a downloaded program.",
                recovery: .retry("Retry"),
                underlying: "exit 137 (SIGKILL) — com.apple.quarantine present on bin/postgres"
            )
            Harness.expectTrue(!error.detail.contains("137"), "exit code leaked into the sentence")
            Harness.expectTrue(error.underlying?.contains("137") == true, "underlying lost the exit code")
        }

        Harness.test("an error with no underlying detail is fine") {
            let error = OilbirdError(.offline, "No connection.", recovery: .retry("Retry"))
            Harness.expectNil(error.underlying)
        }
    }
}
