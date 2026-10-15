import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

/// "Nothing was read" must never read like "your code is clean".
///
/// ⚠ Five routes produced an identical green result: a directory whose name
/// begins with a dot (indexed, then skipped by every sensor), an empty
/// directory, a docs-only directory, a tests-only repository, and one whose
/// single file exceeded the scanner's 20 MB ceiling. Each printed `scanned
/// <key>`, `issues 0` and `gate OK`, exit 0 — while a byte-identical copy of
/// the dotted one, one directory up, reported a CRITICAL.
func analysedNothingTests() {
    Harness.suite("Analysed nothing — the difference between clean and unread") {
        // ⚠ SonarQube does not return `ncloc: 0` for a component with no
        // lines, it OMITS the measure. Reading "whatever ncloc says" sees
        // nothing, and nothing is not zero unless something says so.
        Harness.test("an absent ncloc measure is read as zero, not as unknown") {
            guard
                let server = FixtureServer(answer: { _ in
                    .ok(#"{"component":{"key":"empty","measures":[]}}"#)
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) {
                await SonarAPI.analysedSize(base: base, token: "t", projectKey: "empty")
            }
            let size = try? outcome.get()
            Harness.expectEqual(size?.lines, 0, "an omitted measure must read as zero lines")
            Harness.expectEqual(size?.files, 0, "an omitted measure must read as zero files")
        }

        Harness.test("a real ncloc measure is read as itself") {
            guard
                let server = FixtureServer(answer: { _ in
                    .ok(
                        #"{"component":{"key":"real","measures":"#
                            + #"[{"metric":"ncloc","value":"229"},"#
                            + #"{"metric":"files","value":"7"}]}}"#)
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) {
                await SonarAPI.analysedSize(base: base, token: "t", projectKey: "real")
            }
            Harness.expectEqual((try? outcome.get())?.lines, 229)
            Harness.expectEqual((try? outcome.get())?.files, 7)
        }

        // ⚠ `judgedNothing` keys off an empty condition list, true only of a
        // FIRST analysis: from the second scan on, SonarQube supplies
        // conditions, evaluates them against no code and passes them all.
        Harness.test("a gate with conditions, over no code, is still not a pass") {
            guard
                let server = FixtureServer(answer: { _ in
                    .ok(
                        #"{"projectStatus":{"status":"OK","conditions":"#
                            + #"[{"metricKey":"new_coverage","status":"OK","#
                            + #""comparator":"LT","errorThreshold":"80","#
                            + #""actualValue":"0"}]}}"#)
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
            guard var result = try? outcome.get() else {
                Harness.expectTrue(false, "the fixture gate did not decode")
                return
            }
            Harness.expectTrue(
                !result.judgedNothing,
                "a condition IS present, so judgedNothing is false — which is why it "
                    + "never caught this")
            result.linesAnalysed = 0
            Harness.expectTrue(
                result.readNothing,
                "a gate over zero lines must be caught by something, and judgedNothing is not it")
            result.linesAnalysed = 229
            Harness.expectTrue(!result.readNothing, "a project with code is not empty")
        }

        Harness.test("a scan result knows whether it read anything") {
            let read = Scan.Result(
                key: "k", dashboard: nil, toolchain: .node, degraded: false,
                degradedReason: nil, filesAnalysed: 7, linesAnalysed: 229)
            let unread = Scan.Result(
                key: "k", dashboard: nil, toolchain: .other, degraded: false,
                degradedReason: nil, filesAnalysed: 0, linesAnalysed: 0)
            Harness.expectTrue(!read.readNothing)
            Harness.expectTrue(unread.readNothing, "0 lines is the whole point of the field")
        }
    }
}

/// ⚠ Every non-404 refusal became "The server did not answer that request. →
/// Try again", and the server HAD answered — clearly, and with the fix in the
/// body. `oilbird gate ''` sent its user to debug a healthy engine; an
/// agent asking for severity "critical" instead of "CRITICAL" got a retry
/// label and retried for ever, while the discarded body named the five legal
/// values.
func refusalMessageTests() {
    Harness.suite("A refused request says what the server said") {
        Harness.test("a 400 carries SonarQube's own words, and does not offer a retry") {
            guard
                let server = FixtureServer(answer: { _ in
                    FixtureServer.Reply(
                        status: 400,
                        body: #"{"errors":[{"msg":"Value of parameter 'severities' "#
                            + #"(critical) must be one of: [INFO, MINOR, MAJOR, "#
                            + #"CRITICAL, BLOCKER]"}]}"#)
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
            guard case .failure(let raw) = outcome, let error = raw as? OilbirdError else {
                Harness.expectTrue(false, "a 400 was not reported as a failure")
                return
            }
            Harness.expectTrue(
                error.detail.contains("CRITICAL"),
                "the server's own message was discarded: \(error.detail)")
            // The label is the whole point: retrying a typo produces the
            // same typo, and an agent told to retry will.
            if case .retry = error.recovery {
                Harness.expectTrue(false, "a refused argument still offers Try again")
            } else {
                Harness.expectTrue(true, "the recovery is not a retry")
            }
        }

        // A 404 was already right and must stay right.
        Harness.test("a 404 keeps its own sentence") {
            guard let server = FixtureServer(answer: { _ in .notFound }) else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let base = server.base
            let outcome = runSync(within: 20) {
                try await SonarAPI.qualityGate(base: base, token: "t", projectKey: "k")
            }
            guard case .failure(let raw) = outcome, let error = raw as? OilbirdError else {
                Harness.expectTrue(false, "a 404 was not reported as a failure")
                return
            }
            Harness.expectTrue(
                error.detail.contains("nothing by that name"),
                "the 404 sentence changed: \(error.detail)")
        }

        // A body that is not the shape we expect must not become the message.
        Harness.test("an unparseable body falls back to a sentence, not to noise") {
            guard
                let server = FixtureServer(answer: { _ in
                    FixtureServer.Reply(status: 403, body: "<html>Forbidden</html>")
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
            guard case .failure(let raw) = outcome, let error = raw as? OilbirdError else {
                Harness.expectTrue(false, "a 403 was not reported as a failure")
                return
            }
            Harness.expectTrue(
                !error.detail.contains("<html>"), "raw markup reached the user")
            Harness.expectNotEmpty(error.detail, "a refusal with no sentence at all")
        }
    }
}
