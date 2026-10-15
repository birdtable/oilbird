import Foundation
import OilbirdCore
import OilbirdModel

func childTests() {
    Harness.suite("Child — the only place a process is constructed") {
        Harness.test("a child runs and its output comes back") {
            let result = runSync { try await Child.run(URL(filePath: "/bin/echo"), ["oilbird"]) }
            Harness.expectEqual(try? result.get().status, 0)
            Harness.expectTrue((try? result.get().stdout.contains("oilbird")) == true)
        }

        Harness.test("a non-zero exit is reported, not swallowed") {
            let result = runSync {
                try await Child.run(URL(filePath: "/bin/sh"), ["-c", "exit 9"])
            }
            Harness.expectEqual(try? result.get().status, 9)
        }

        Harness.test("a missing executable fails with a recovery, not a crash") {
            let result = runSync { try await Child.run(URL(filePath: "/nope/absent"), []) }
            guard case .failure(let error) = result, let oilbird = error as? OilbirdError else {
                Harness.expectTrue(false, "a missing binary did not produce an OilbirdError")
                return
            }
            Harness.expectNotEmpty(oilbird.recovery.actionLabel)
        }

        // A child inheriting PGDATA opens the USER's cluster with OUR binary.
        // Absolute paths do not protect against that.
        Harness.test("the child sees no PG* variable, even when we have one") {
            setenv("PGDATA", "/opt/homebrew/var/postgresql@16", 1)
            defer { unsetenv("PGDATA") }
            let result = runSync {
                try await Child.run(URL(filePath: "/bin/sh"), ["-c", "echo [${PGDATA:-unset}]"])
            }
            Harness.expectTrue(
                (try? result.get().stdout.contains("[unset]")) == true, "PGDATA reached the child")
        }

        Harness.test("the child's PATH is the Finder minimum, not the login shell's") {
            let result = runSync {
                try await Child.run(URL(filePath: "/bin/sh"), ["-c", "echo $PATH"])
            }
            let path = (try? result.get().stdout) ?? ""
            Harness.expectTrue(!path.contains("homebrew"), "Homebrew reached the child")
        }
    }
}

/// ⚠ Output was not live, and two surfaces said it was.
///
/// `runBlocking` read each pipe with `readDataToEndOfFile()`, which returns
/// when the child exits, and `Scan.run` then replayed the whole buffer
/// through `onLine` in one tight loop. Measured on a one-file project:
/// 11.4 seconds of complete silence, then 125 lines in the same
/// millisecond. The window was worse — the bird pinged over a progress line
/// that stayed empty for the whole analysis and then flashed the entire log
/// past — because it looked like a considered design rather than a bug.
func streamingTests() {
    Harness.suite("Child — output arrives while the child is still running") {
        Harness.test("a line is delivered before the process exits") {
            let script = """
                #!/bin/sh
                echo first
                sleep 1
                echo second
                """
            let path = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-stream-\(UUID().uuidString).sh")
            try? Data(script.utf8).write(to: path)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path.path)
            defer { try? FileManager.default.removeItem(at: path) }

            let seen = Box(0)
            let firstAt = Box(0.0)
            let start = Date()
            let outcome = runSync(within: 20) {
                try await Child.run(URL(filePath: "/bin/sh"), [path.path]) { _ in
                    if seen.get() == 0 { firstAt.set(Date().timeIntervalSince(start)) }
                    seen.set(seen.get() + 1)
                }
            }
            let total = Date().timeIntervalSince(start)
            Harness.expectTrue((try? outcome.get()) != nil, "the child did not run")
            Harness.expectEqual(seen.get(), 2, "both lines should arrive")
            // The script sleeps a second between its two lines. If the first
            // only turns up once the child is gone, this is the old
            // behaviour wearing a callback.
            Harness.expectTrue(
                firstAt.get() < total - 0.5,
                "the first line arrived at \(firstAt.get())s of a \(total)s run — "
                    + "that is the whole buffer replayed after exit, not a stream")
        }

        // ⚠ Reading one pipe to the end and then the other deadlocks once the
        // unread one fills its 64 KB buffer. The old code survived only
        // because the scanner puts almost everything on stdout.
        Harness.test("a child that floods stderr does not hang") {
            let script = "#!/bin/sh\nyes stderr-noise | head -20000 >&2\necho done\n"
            let path = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-flood-\(UUID().uuidString).sh")
            try? Data(script.utf8).write(to: path)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path.path)
            defer { try? FileManager.default.removeItem(at: path) }

            let outcome = runSync(within: 25) {
                try await Child.run(URL(filePath: "/bin/sh"), [path.path])
            }
            guard let result = try? outcome.get() else {
                Harness.expectTrue(false, "flooding stderr hung the read")
                return
            }
            Harness.expectTrue(
                result.stderr.count > 100_000, "stderr was truncated: \(result.stderr.count)")
            Harness.expectTrue(result.stdout.contains("done"), "stdout was lost")
        }
    }
}
