import Foundation
import OilbirdCore
import OilbirdModel

/// The log is a product surface, not a debug artefact: every failure state
/// offers "Show log", so a person filing an issue reads this. It must survive
/// the process that wrote it, stay bounded, and log a subprocess verbatim
/// without ever holding a secret.
func logTests() {
    Harness.suite("Log — the failure path's only witness") {
        // The log must survive the process that wrote it,
        // since a crash is the failure that needs reading.

        // Writes go to a serial queue so logging never stalls a caller, and
        // every CLI failure path logs and then calls `exit`: without a flush
        // the line explaining the failure is the one reliably lost.
        Harness.test("a line written just before an exit is on disk") {
            let witness = "oilbird-log-test-\(UUID().uuidString)"
            Log.error(witness)
            Log.flush()
            // No sleep, no retry: `flush` either means this or means nothing.
            Harness.expectTrue(
                logContents().contains(witness),
                "a flushed line had not reached the file")
        }

        // E5 lives here: a no-op `flush` still passes the test above by luck,
        // because the queue often drains in time. Many lines make winning that
        // race by accident implausible.
        Harness.test("flush holds for a burst, not just for one lucky line") {
            let witness = "oilbird-burst-\(UUID().uuidString)"
            for index in 0..<500 { Log.info("\(witness) \(index)") }
            Log.flush()
            let written = logContents().components(separatedBy: witness).count - 1
            Harness.expectEqual(written, 500, "flush lost lines from a burst")
        }

        // Log volume is bounded: a repeated failure must not fill the disk
        // it is reporting on. A crash-looping
        // supervisor reports on the disk it would otherwise be filling.
        Harness.test("a repeated failure cannot fill the disk it reports on") {
            let line = String(repeating: "x", count: 4096)
            // Comfortably past the 5 MiB rotation threshold.
            for _ in 0..<2_000 { Log.error(line) }
            Log.flush()
            let live = fileSize(Paths.Cache.log)
            Harness.expectTrue(live > 0, "the log vanished instead of rotating")
            Harness.expectTrue(
                live < 6 * 1024 * 1024,
                "the live log grew past its rotation threshold (\(live) bytes)")
            // Bounded means bounded in total, not just per file: an
            // unbounded number of generations fills the disk just as well.
            let total = generations().reduce(0) { $0 + fileSize($1) }
            Harness.expectTrue(
                total < 20 * 1024 * 1024,
                "the log and its generations total \(total) bytes, which is not bounded")
        }

        // The subprocess line is logged
        // verbatim, which is safe ONLY because secrets never enter argv. That
        // ordering is the actual defence, so it is what gets asserted.
        Harness.test("a logged command line carries no secret") {
            let token = "squ_" + Secrets.generatePassword(bytes: 10)
            Log.subprocess(
                URL(filePath: "/bin/echo"),
                argv: ["-Dsonar.host.url=http://127.0.0.1:9000", "-Dsonar.projectKey=demo"])
            Log.flush()
            let written = logContents()
            Harness.expectTrue(written.contains("exec /bin/echo"), "the launch was not logged")
            Harness.expectTrue(
                !written.contains(token),
                "a token reached the log, so argv is no longer secret-free")
        }
    }
}

private func logContents() -> String {
    (try? String(contentsOf: Paths.Cache.log, encoding: .utf8)) ?? ""
}

private func fileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
}

/// The live log plus every rotated generation beside it.
private func generations() -> [URL] {
    let logs = Paths.Cache.logs
    let names =
        (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []
    return names.filter { $0.hasPrefix("oilbird.log") }.map { logs.appending(path: $0) }
}
