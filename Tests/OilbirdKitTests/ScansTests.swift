import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

/// A scan you can leave, and come back to.
///
/// Everything here that can be asserted without a GUI and without four JVMs
/// is asserted: the log replaying from the beginning, two readers at once,
/// a finished scan answering rather than hanging, a pre-boot record reported
/// as interrupted, and — the one that matters most — the detached process
/// really holding the idle attachment, proved against a real watchdog with
/// its interval at the floor.
func scansTests() {
    Harness.suite("Scans — sending one off, and coming back to it") {
        // MARK: what is written down

        Harness.test("a scan is listed while it runs and after it ends") {
            let key = "fixture-running-01"
            let sink = Scans.begin(key: key, path: URL(filePath: "/tmp/fixture"))
            Harness.expectTrue(sink != nil, "the scan was not recorded")
            guard let entry = Scans.entry(key) else {
                Harness.expectTrue(false, "no entry for a scan that had just begun")
                return
            }
            Harness.expectEqual(entry.state, .running, "a live scan did not read as running")
            Harness.expectEqual(entry.pid, getpid(), "the record named another process")
            // Nothing in the log yet, so it has not reached the scanner.
            Harness.expectEqual(entry.phase, .starting, "phase before any output")
            sink?.write("INFO: Analyzing")
            Harness.expectEqual(
                Scans.entry(key)?.phase, .analysing,
                "a scan producing output still read as starting")
            sink?.close()
            Scans.finish(
                key: key,
                outcome: .completed(
                    .init(files: 1, lines: 229, degraded: false, gate: "OK", judgedNothing: false)))
            guard let done = Scans.entry(key) else {
                Harness.expectTrue(false, "a finished scan stopped being listed")
                return
            }
            // Finished scans stay listed, because "did that finish?" is
            // asked more often than "what is running?".
            Harness.expectEqual(done.state, .finished, "a finished scan did not read as finished")
            Harness.expectEqual(done.verdict, "OK", "the recorded gate was not the verdict")
            Harness.expectEqual(done.read, "1 file, 229 lines", "what it read")
            Harness.expectTrue(
                Oilbird.scans().contains { $0.key == key }, "the finished scan left the list")
        }

        Harness.test("a gate that judged nothing is not reported as a pass") {
            let key = "fixture-unjudged-01"
            Scans.begin(key: key, path: URL(filePath: "/tmp/fixture"))?.close()
            Scans.finish(
                key: key,
                outcome: .completed(
                    .init(files: 2, lines: 40, degraded: false, gate: "OK", judgedNothing: true)))
            // ⚠ SonarQube's default gate scores NEW code, so a first analysis
            // passes every condition by evaluating none of them. Printing OK
            // here is how `scan && deploy` deploys anything for ever.
            Harness.expectEqual(
                Scans.entry(key)?.verdict, "not judged", "a gate that checked nothing read as OK")
        }

        Harness.test("a failed gate and a scan that did not finish read differently") {
            let failed = "fixture-gate-failed"
            Scans.begin(key: failed, path: URL(filePath: "/tmp/fixture"))?.close()
            Scans.finish(
                key: failed,
                outcome: .completed(
                    .init(
                        files: 14, lines: 970, degraded: false, gate: "ERROR",
                        judgedNothing: false)))
            Harness.expectEqual(Scans.entry(failed)?.verdict, "FAILED", "a failed gate")

            let broken = "fixture-scan-failed"
            Scans.begin(key: broken, path: URL(filePath: "/tmp/fixture"))?.close()
            Scans.finish(key: broken, outcome: .failed("The scan did not finish."))
            // Both would otherwise read FAILED, and only one of them has a
            // codebase to fix.
            Harness.expectEqual(Scans.entry(broken)?.verdict, "did not finish", "a broken scan")
        }

        // MARK: the pid, and who it belongs to now

        // ⚠ A pid recorded before the last restart names somebody else's
        // process: a scan the machine was rebooted out from under reads as
        // running for ever, and `--stop` SIGTERMs a stranger.
        Harness.test("a scan recorded before the last boot is interrupted, never running") {
            guard let boot = Supervise.Kernel.bootTime() else {
                Harness.expectTrue(false, "the kernel would not say when it booted")
                return
            }
            // This process is unquestionably alive, so nothing but the boot
            // check can produce the answer.
            let mine = Supervise.Kernel.executablePath(of: getpid())
            let before = Scans.Record(
                key: "fixture-pre-boot", path: "/tmp/fixture", pid: getpid(), group: getpgrp(),
                started: boot.addingTimeInterval(-3600),
                booted: boot.addingTimeInterval(-3600), executable: mine, detached: true)
            try? Scans.recordForTesting(before)
            Harness.expectEqual(
                Scans.entry("fixture-pre-boot")?.state, .interrupted,
                "a record from before the last restart was reported as a running scan")

            // The control. Without it the assertion above passes for a
            // record that was simply unreadable.
            let now = Scans.Record(
                key: "fixture-this-boot", path: "/tmp/fixture", pid: getpid(), group: getpgrp(),
                started: Date(), booted: boot, executable: mine, detached: true)
            try? Scans.recordForTesting(now)
            Harness.expectEqual(
                Scans.entry("fixture-this-boot")?.state, .running,
                "a record from this boot naming a live process did not read as running")
        }

        Harness.test("a scan whose process is gone is interrupted") {
            let dead = Process()
            dead.executableURL = URL(filePath: "/usr/bin/true")
            try? dead.run()
            dead.waitUntilExit()
            let record = Scans.Record(
                key: "fixture-dead", path: "/tmp/fixture", pid: dead.processIdentifier,
                group: dead.processIdentifier, started: Date(),
                booted: Supervise.Kernel.bootTime(), executable: "/usr/bin/true", detached: true)
            try? Scans.recordForTesting(record)
            Harness.expectEqual(
                Scans.entry("fixture-dead")?.state, .interrupted,
                "a scan whose process had exited was reported as running")
        }

        // MARK: following

        // ⚠ The reason the log is a FILE: a finished scan has nothing to
        // attach to if the output went down a pipe. Bounded, since getting
        // this wrong is a command that never returns.
        Harness.test("following a finished scan prints the run and returns") {
            let key = "fixture-replay"
            let sink = Scans.begin(key: key, path: URL(filePath: "/tmp/fixture"))
            sink?.write("INFO: Scanner configuration")
            sink?.write("INFO: ANALYSIS SUCCESSFUL")
            sink?.close()
            Scans.finish(
                key: key,
                outcome: .completed(
                    .init(files: 3, lines: 91, degraded: false, gate: "OK", judgedNothing: false)))

            let seen = Box([String]())
            let result = runSync(within: 10) {
                try await Scans.follow(key: key, poll: .milliseconds(10)) { line in
                    seen.set(seen.get() + [line])
                }
            }
            guard case .success(let entry) = result else {
                Harness.expectTrue(false, "following a finished scan never returned")
                return
            }
            Harness.expectEqual(
                seen.get(), ["INFO: Scanner configuration", "INFO: ANALYSIS SUCCESSFUL"],
                "following late did not replay the run from the beginning")
            Harness.expectEqual(entry.verdict, "OK", "following returned no verdict to print")

            // And again, because "re-attachable any number of times" is the
            // half a single successful read does not prove.
            let twice = Box([String]())
            _ = runSync(within: 10) {
                try await Scans.follow(key: key, poll: .milliseconds(10)) { line in
                    twice.set(twice.get() + [line])
                }
            }
            Harness.expectEqual(twice.get(), seen.get(), "following a second time saw a different run")
        }

        // ⚠ Two readers, at once, on a scan that is still writing. A pipe
        // would split the stream between them and each would see half.
        Harness.test("two followers at once both see the whole run") {
            let key = "fixture-two-readers"
            guard let sink = Scans.begin(key: key, path: URL(filePath: "/tmp/fixture")) else {
                Harness.expectTrue(false, "the scan was not recorded")
                return
            }
            let writing = Thread {
                for number in 1...20 {
                    sink.write("line \(number)")
                    usleep(15_000)
                }
                sink.close()
                Scans.finish(
                    key: key,
                    outcome: .completed(
                        .init(
                            files: 1, lines: 1, degraded: false, gate: "OK", judgedNothing: false)))
            }
            writing.start()

            let first = Box([String]()), second = Box([String]())
            let result = runSync(within: 20) { () async throws -> Bool in
                async let one = Scans.follow(key: key, poll: .milliseconds(10)) { line in
                    first.set(first.get() + [line])
                }
                async let two = Scans.follow(key: key, poll: .milliseconds(10)) { line in
                    second.set(second.get() + [line])
                }
                _ = try await (one, two)
                return true
            }
            guard case .success = result else {
                Harness.expectTrue(false, "two followers did not both return")
                return
            }
            let expected = (1...20).map { "line \($0)" }
            Harness.expectEqual(first.get(), expected, "the first follower missed part of the run")
            Harness.expectEqual(second.get(), expected, "the second follower missed part of the run")
        }

        // ⚠ `follow` and `--stop` take their key from whoever typed it, and
        // this is where a key becomes a path.
        Harness.test("a key that is not a key cannot become a path") {
            let escaping = "../../../etc/passwd"
            guard let path = Scans.logPath(for: escaping) else {
                Harness.expectTrue(false, "a key with letters in it was refused outright")
                return
            }
            // The separators are what matter, not the dots: `..-..-etc` is a
            // silly directory name and it is one directory, here, under the
            // scans root.
            Harness.expectTrue(
                !URL(filePath: path).pathComponents.contains(".."),
                "a key produced a path component that walks upward: \(path)")
            Harness.expectTrue(
                path.hasPrefix(Paths.State.scans.path + "/"),
                "a scan log was placed outside the scans directory: \(path)")
            // A key with nothing in it that could name a project is refused
            // rather than resolved to the scans directory itself.
            Harness.expectNil(Scans.logPath(for: ".."), "`..` was accepted as a key")
            Harness.expectNil(Scans.logPath(for: ""), "an empty key was accepted")
        }

        // MARK: stopping

        Harness.test("stopping a scan ends its process and records that it was stopped") {
            let sleeper = Process()
            sleeper.executableURL = URL(filePath: "/bin/sleep")
            sleeper.arguments = ["60"]
            try? sleeper.run()
            Harness.expectTrue(sleeper.isRunning, "the stand-in scan never started")
            let key = "fixture-stoppable"
            try? Scans.recordForTesting(
                Scans.Record(
                    key: key, path: "/tmp/fixture", pid: sleeper.processIdentifier,
                    // Not its own group leader, so this exercises the safe
                    // branch: the pid alone is signalled, never the group
                    // the test runner is sitting in.
                    group: getpgrp(), started: Date(), booted: Supervise.Kernel.bootTime(),
                    executable: "/bin/sleep", detached: false))
            Harness.expectEqual(Scans.entry(key)?.state, .running, "the stand-in scan was not listed")

            guard let stopped = try? Scans.stop(key) else {
                Harness.expectTrue(false, "stopping threw")
                return
            }
            Harness.expectTrue(stopped.ended, "stop reported that it ended nothing")
            Harness.expectTrue(settle(within: 5) { !sleeper.isRunning }, "the scan kept running")
            Harness.expectEqual(Scans.entry(key)?.verdict, "stopped", "the stop was not recorded")

            // Stopping something that has already ended is an answer, not an
            // error — and it must not signal the pid a second time.
            guard let again = try? Scans.stop(key) else {
                Harness.expectTrue(false, "stopping a finished scan threw")
                return
            }
            Harness.expectTrue(!again.ended, "a finished scan was reported as freshly stopped")
        }

        Harness.test("stopping a scan nobody started says so") {
            let result = try? Scans.stop("no-such-scan-at-all")
            Harness.expectNil(result, "stopping an unknown key succeeded")
        }

        // MARK: the spawn primitive

        // ⚠ `Child.spawn` sends both streams to `/dev/null`, right for a
        // service and wrong for a scan read later. And `Process` cannot put a
        // child in its own session, which is what survives the terminal.
        Harness.test("a detached child writes to a file and leads its own session") {
            let output = Paths.Cache.scratch.appending(path: "detached-output.log")
            try? FileManager.default.createDirectory(
                at: Paths.Cache.scratch, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: output)
            guard
                let pid = try? Child.detach(
                    URL(filePath: "/bin/sh"),
                    ["-c", "echo to-stdout; echo to-stderr >&2; sleep 3"],
                    output: output)
            else {
                Harness.expectTrue(false, "the detached child never started")
                return
            }
            defer { kill(pid, SIGKILL) }
            let wrote = settle(within: 10) {
                let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                return text.contains("to-stdout") && text.contains("to-stderr")
            }
            Harness.expectTrue(wrote, "a detached child's output did not reach its file")
            // A session of its own is what a `SIGHUP` to the terminal cannot
            // reach. Being a session leader also makes it a process-group
            // leader, which is what lets `stop` signal the scanner's JVM.
            Harness.expectEqual(getsid(pid), pid, "the detached child stayed in our session")
        }

        // ⚠ The CLI's `follow` blocks until the scan ends, so a tool built on
        // it reports the state it read before waiting. A question an agent
        // asks repeatedly must ANSWER repeatedly.
        Harness.test("a scan's output can be read without waiting for the scan") {
            let key = "fixture-unwritten"
            Harness.expectEqual(
                Oilbird.scanOutput(key: key).count, 0,
                "a key nothing has scanned produced lines")

            let sink = Scans.begin(key: key, path: URL(filePath: "/tmp/fixture/unwritten"))
            defer {
                sink?.close()
                Scans.finish(key: key, outcome: .stopped)
            }
            sink?.write("INFO: one")
            sink?.write("INFO: two")
            // Read WHILE it is still running — the whole point — and it
            // returns rather than waiting for a scan nothing will finish.
            let said = Oilbird.scanOutput(key: key)
            Harness.expectTrue(
                said.contains("INFO: one") && said.contains("INFO: two"),
                "the log as it stands was not readable mid-flight: \(said)")
            Harness.expectTrue(
                !said.contains(""), "a blank line was carried into the output")
            Harness.expectEqual(
                Oilbird.scan(named: key)?.state, .running,
                "reading the output ended the scan")
        }

        // MARK: the real thing, through the real binary

        guard let binary = oilbirdForScanTests() else {
            Harness.expectTrue(false, "no oilbird binary beside the test runner")
            return
        }

        // ⚠ The only way to check this is to let go of the process: the
        // parent exits immediately, and everything asserted here was written
        // by a process that outlived it.
        Harness.test("a detached scan outlives the command that started it") {
            guard let folder = fixtureProject("left-behind") else {
                Harness.expectTrue(false, "could not make a fixture project")
                return
            }
            let started = runCLI(binary, ["scan", folder.path, "--detach", "--json"])
            Harness.expectEqual(started.status, 0, "detaching failed: \(started.output)")
            guard let handed = firstObject(in: started.output), let key = handed["key"] as? String
            else {
                Harness.expectTrue(false, "--detach printed no handle: \(started.output)")
                return
            }
            Harness.expectTrue(!key.isEmpty, "the handle was empty")
            // The parent has exited by now — `runCLI` waited for it. Anything
            // that appears from here on was written by the child.
            let ended = settle(within: 60) { Scans.entry(key)?.state == .finished }
            Harness.expectTrue(ended, "the detached scan recorded no verdict after its parent left")
            guard let entry = Scans.entry(key) else {
                Harness.expectTrue(false, "the scan stopped being listed")
                return
            }
            // There is no engine here, so the verdict is that it could not
            // finish — which is still a verdict, written by the child, after
            // the terminal that started it was gone.
            Harness.expectTrue(entry.finished != nil, "no end was recorded")
            Harness.expectTrue(
                entry.detached,
                "the detached scan did not lead its own session, so closing the terminal "
                    + "would have killed it")
        }

        // ⚠ `--json` has to be parseable WHILE a scan is in flight, not only
        // after it. A CI step polling this is the whole reason `--detach`
        // hands back a key.
        Harness.test("scans --json is parseable mid-flight, and carries the four keys") {
            let key = "fixture-midflight"
            let sink = Scans.begin(key: key, path: URL(filePath: "/tmp/fixture/midflight"))
            defer { sink?.close() }
            sink?.write("INFO: Analyzing")

            let listed = runCLI(binary, ["scans", "--json"])
            Harness.expectEqual(listed.status, 0, "scans --json failed: \(listed.output)")
            guard let parsed = firstObject(in: listed.output),
                let rows = parsed["scans"] as? [[String: Any]],
                let mine = rows.first(where: { $0["key"] as? String == key })
            else {
                Harness.expectTrue(false, "scans --json was not parseable: \(listed.output)")
                return
            }
            Harness.expectEqual(mine["state"] as? String, "running", "state mid-flight")
            Harness.expectEqual(mine["pid"] as? Int, Int(getpid()), "pid mid-flight")
            Harness.expectEqual(mine["phase"] as? String, "analysing", "phase mid-flight")
            Harness.expectNotEmpty(mine["started"] as? String ?? "", "started mid-flight")
            Scans.finish(key: key, outcome: .stopped)
        }

        // One project, one scan. A second detach of the same project
        // would be recorded under the same key and would truncate the log the
        // first is streaming into.
        Harness.test("a project already being scanned is not detached a second time") {
            guard let folder = fixtureProject("already-running") else {
                Harness.expectTrue(false, "could not make a fixture project")
                return
            }
            let key = Oilbird.projectNaming(for: folder).key
            let sink = Scans.begin(key: key, path: folder)
            defer { sink?.close() }
            let refused = runCLI(binary, ["scan", folder.path, "--detach"])
            Harness.expectTrue(refused.status != 0, "a second detached scan of one project started")
            Harness.expectTrue(
                refused.output.contains("already being scanned"),
                "the refusal did not say why: \(refused.output)")
            Scans.finish(key: key, outcome: .stopped)
        }

        // ⚠ The detached process should hold an attachment, but
        // "should" is not evidence, and without one the watchdog stops the
        // engine under a scan nobody is watching.

        // Everything here is real, and the attachment is asked of the KERNEL:
        // `Idle.attached()` fails to take the lock exclusively only because
        // another process holds it shared.
        Harness.test("the idle watchdog does not stop the engine under a detached scan") {
            Harness.expectTrue(!Idle.attached(), "something was attached before the test began")
            guard let folder = fixtureProject("held-open") else {
                Harness.expectTrue(false, "could not make a fixture project")
                return
            }
            // A server that says UP, so the detached scan gets past
            // `ensureRunning` without four JVMs.
            guard
                let server = FixtureServer(answer: { request in
                    request.path.hasPrefix("/api/system/status")
                        ? .ok(#"{"id":"fixture","version":"26.9","status":"UP"}"#)
                        : .ok("{}")
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            try? FileManager.default.createDirectory(
                at: Paths.State.run, withIntermediateDirectories: true)
            try? Secrets.save(
                Secrets.Stored(
                    databasePassword: "fixture", adminPassword: "fixture",
                    analysisToken: "fixture-token"))
            try? Data(#"{"webPort":\#(server.port),"databasePort":1}"#.utf8)
                .write(to: Paths.State.run.appending(path: "running.json"))

            // A stand-in engine: something alive for the watchdog to stop.
            let sleeper = Process()
            sleeper.executableURL = URL(filePath: "/bin/sleep")
            sleeper.arguments = ["120"]
            try? sleeper.run()
            defer { if sleeper.isRunning { sleeper.terminate() } }
            Harness.expectTrue(sleeper.isRunning, "the stand-in engine never started")
            try? Supervise.record(
                app: sleeper.processIdentifier, group: getpgid(sleeper.processIdentifier))

            // ⚠ The scan is PARKED on purpose: `Owner.serialised` makes a
            // second scan of one project wait, so holding that lock keeps the
            // detached scan inside `Oilbird.scan` with no product test hook.
            let key = Oilbird.projectNaming(for: folder).key
            let holding = Box(false), releasing = Box(false)
            defer { releasing.set(true) }
            Thread {
                _ = runSync {
                    try await Owner.serialised(named: key) {
                        holding.set(true)
                        while !releasing.get() { usleep(20_000) }
                    }
                }
            }.start()
            Harness.expectTrue(
                settle(within: 10) { holding.get() }, "the test never took the project lock")

            let detached = runCLI(binary, ["scan", folder.path, "--detach", "--json"])
            Harness.expectEqual(detached.status, 0, "detaching failed: \(detached.output)")
            let child = (firstObject(in: detached.output)?["pid"] as? Int).map { Int32($0) } ?? 0
            defer { if child > 0 { kill(child, SIGKILL) } }
            Harness.expectTrue(
                settle(within: 30) { Idle.attached() },
                "the detached process did not hold the engine open — the watchdog is free to "
                    + "stop the engine underneath it")

            // The watchdog, at the floor of the interval, with the poll as
            // fast as the hooks allow.
            let watchdog = Process()
            watchdog.executableURL = binary
            watchdog.arguments = ["watch"]
            var environment = ProcessInfo.processInfo.environment
            environment["OILBIRD_IDLE_SECONDS"] = "1"
            environment["OILBIRD_POLL_MS"] = "100"
            watchdog.environment = environment
            watchdog.standardOutput = FileHandle.nullDevice
            watchdog.standardError = FileHandle.nullDevice
            try? watchdog.run()
            defer { if watchdog.isRunning { watchdog.terminate() } }

            // Forty times the interval, and it must not have acted once.
            Harness.expectTrue(
                !settle(within: 4) { !sleeper.isRunning },
                "the idle watchdog stopped the engine while a detached scan was running")
            Harness.expectTrue(Idle.attached(), "the scan let go of the engine while it ran")

            // ⚠ The control, and not optional: "it did not stop" proves nothing
            // unless the same watchdog stops it the moment the scan lets go,
            // or a watchdog that died on launch passes too.
            releasing.set(true)
            Harness.expectTrue(
                settle(within: 60) { !Idle.attached() },
                "the detached scan never released the engine")
            Harness.expectTrue(
                settle(within: 30) { !sleeper.isRunning },
                "the watchdog never stopped the idle engine, so the assertion above proved "
                    + "nothing about the attachment")
            try? FileManager.default.removeItem(at: Paths.State.run.appending(path: "running.json"))
        }
    }
}

/// A throwaway project to scan, inside the container the suite already owns.
private func fixtureProject(_ name: String) -> URL? {
    let folder = Paths.Cache.scratch.appending(path: "scans-\(name)")
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "print('hello')\n".write(
            to: folder.appending(path: "main.py"), atomically: true, encoding: .utf8)
        return folder
    } catch {
        return nil
    }
}

/// The `oilbird` built from this source, beside the test runner.
private func oilbirdForScanTests() -> URL? {
    let sibling = URL(filePath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "oilbird")
    return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
}

/// The first JSON object in a run's output.
///
/// Human output goes to stderr and machine output to stdout, and `runCLI`
/// merges them — so this finds the object rather than assuming the whole
/// stream is one.
private func firstObject(in output: String) -> [String: Any]? {
    guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
        start < end
    else { return nil }
    let slice = output[start...end]
    return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any]
}

private func runCLI(_ binary: URL, _ argv: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = binary
    process.arguments = argv
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
