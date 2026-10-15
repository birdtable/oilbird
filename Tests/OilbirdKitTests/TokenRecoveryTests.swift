import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

// Oilbird's analysis token is listed on the user's own account page with a
// revoke button beside it. Revoked, every read, scan and agent tool breaks at
// once with an empty `HTTP 401` and no way back.

func tokenRecoveryTests() {
    Harness.suite("The analysis token — a credential Oilbird issued to itself") {
        // ⚠ `authentication/validate` is the only endpoint that tells "revoked"
        // from "unreachable" without a credential of its own: 200 for both,
        // with the verdict in the body.
        Harness.test("a revoked token is read as revoked, from the body and not the status") {
            guard
                let server = FixtureServer(answer: { request in
                    request.path.hasPrefix("/api/authentication/validate")
                        ? .ok(#"{"valid":false}"#) : .notFound
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) {
                await SonarAPI.accepts(base: base, token: "squ_dead")
            }
            guard case .success(let accepted) = outcome else {
                Harness.expectTrue(false, "the probe did not answer")
                return
            }
            Harness.expectTrue(!accepted, "a 200 {\"valid\":false} was read as acceptance")
        }

        Harness.test("a live token is read as live") {
            guard
                let server = FixtureServer(answer: { _ in .ok(#"{"valid":true}"#) })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) {
                await SonarAPI.accepts(base: base, token: "squ_live")
            }
            guard case .success(let accepted) = outcome else {
                Harness.expectTrue(false, "the probe did not answer")
                return
            }
            Harness.expectTrue(accepted, "a valid token was read as revoked")
        }

        // ⚠ A server that cannot be reached has revoked nothing: answering
        // "revoked" there mints a fresh token on every network blip and
        // reports a dead server as a credential problem.
        Harness.test("an unreachable server is not evidence of revocation") {
            // Port 1 is reserved and nothing listens on it.
            let closed = Loopback.url(port: 1)
            let outcome = runSync(within: 20) {
                await SonarAPI.accepts(base: closed, token: "squ_live")
            }
            guard case .success(let accepted) = outcome else {
                Harness.expectTrue(false, "the probe did not answer")
                return
            }
            Harness.expectTrue(accepted, "an unreachable server was read as a revocation")
        }

        // ⚠ The ORDERING is the fix: `user_tokens/generate` refuses an existing
        // name, so minting before revoking fails in the situation recovery is
        // for. Asserted on the call sequence.
        Harness.test("the old token is revoked before a new one is asked for") {
            guard
                let server = FixtureServer(answer: { request in
                    request.path.hasPrefix("/api/user_tokens/revoke")
                        ? reply204()
                        : .ok(#"{"token":"squ_fresh"}"#)
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) {
                try await Provisioning.mintToken(base: base, admin: "pw")
            }
            guard case .success(let token) = outcome else {
                Harness.expectTrue(false, "minting failed: \(outcome)")
                return
            }
            Harness.expectEqual(token, "squ_fresh", "the fresh token was not returned")
            let paths = server.requests.map(\.path).filter { $0.hasPrefix("/api/user_tokens/") }
            Harness.expectEqual(paths.count, 2, "the wrong number of token calls was made")
            Harness.expectTrue(
                paths.first?.hasPrefix("/api/user_tokens/revoke") == true,
                "generate was called before revoke, which a real server refuses")
            Harness.expectTrue(
                paths.last?.hasPrefix("/api/user_tokens/generate") == true,
                "no token was minted after the revoke")
        }

        // ⚠ The recovery can itself be locked out: Oilbird mints as `admin`
        // with a password it generated, and changing that from the dashboard
        // disables it. "Try again" cannot work, so it names the password.
        Harness.test("a changed admin password is named, not offered as a retry") {
            guard let server = FixtureServer(answer: { _ in reply401() }) else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) {
                try await Provisioning.mintToken(base: base, admin: "the-old-one")
            }
            guard case .failure(let error) = outcome, let failure = error as? OilbirdError else {
                Harness.expectTrue(false, "minting against a rejected password did not fail")
                return
            }
            Harness.expectEqual(
                failure.cause, .credentialRejected,
                "a rejected admin password was reported as \(failure.cause)")
            Harness.expectTrue(
                failure.detail.contains("password"),
                "the message does not say the password is the problem: \(failure.detail)")
            if case .retry = failure.recovery {
                Harness.expectTrue(false, "offered a retry that cannot work")
            }
        }

        // ⚠ An unrecognised gate verdict must not read as a pass:
        // `Gate(rawValue:) ?? .none` collapses a new status word to "never
        // analysed", which is not `.error`, so `gate && deploy` deploys.
        Harness.test("a gate verdict the server invented is not a pass") {
            guard
                let server = FixtureServer(answer: { _ in
                    .ok(#"{"projectStatus":{"status":"WARN_NEW","conditions":[]}}"#)
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) {
                try await SonarAPI.qualityGate(base: base, token: "t", projectKey: "k")
            }
            guard case .success(let result) = outcome else {
                Harness.expectTrue(false, "the gate call failed outright")
                return
            }
            Harness.expectEqual(
                result.gate.rawValue, "WARN_NEW",
                "the server's own word was discarded")
            Harness.expectTrue(
                !result.gate.isRecognised,
                "an invented verdict was reported as one Oilbird understands")
            Harness.expectTrue(
                result.gate != .ok && result.gate != .none,
                "an invented verdict collapsed onto a passing one")
        }

        // A 401 must not arrive as advice to check the arguments: no argument
        // the caller changes can mint a token.
        Harness.test("a rejected credential is named as one") {
            guard
                let server = FixtureServer(answer: { _ in reply401() })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) {
                try await SonarAPI.projects(base: base, token: "squ_dead")
            }
            guard case .failure(let error) = outcome, let failure = error as? OilbirdError else {
                Harness.expectTrue(false, "a 401 did not fail")
                return
            }
            Harness.expectEqual(
                failure.cause, .credentialRejected,
                "a revoked token was reported as \(failure.cause)")
        }
    }
}

/// The fixture speaks 200 and 404; these two are what token work needs.
private func reply204() -> FixtureServer.Reply { .init(status: 204, body: "") }
private func reply401() -> FixtureServer.Reply { .init(status: 401, body: "") }
