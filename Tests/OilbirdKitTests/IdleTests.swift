import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

/// Zero unattended cost: no Oilbird process runs with no client attached, no
/// scan in flight and the idle interval elapsed. The pure policy and the
/// attachment contract, both answerable in microseconds.
/// One row of the idle table.
///
/// ⚠ A named type and not a tuple. The tuple carried a comment above it
/// reading `// engineRunning, attached, limit, idleFor, expected`, which is a
/// type's job written out in prose: nothing checked that the comment and the
/// positions agreed, and reading row seven meant counting commas.
private struct Case {
    let running: Bool
    let attached: Bool
    let limit: Duration?
    let idle: Duration
    let then: Idle.Verdict

    init(running: Bool, attached: Bool, limit: Duration?, idle: Int, then: Idle.Verdict) {
        self.running = running
        self.attached = attached
        self.limit = limit
        self.idle = .seconds(idle)
        self.then = then
    }

    /// What to print when this row is the one that failed.
    var said: String {
        "running=\(running) attached=\(attached) "
            + "limit=\(limit.map { "\($0)" } ?? "never") idle=\(idle)"
    }
}

func idleTests() {
    Harness.suite("Idle — the engine stops, the app does not") {
        // Everything injected, so thirty minutes of waiting becomes a value.
        Harness.test("the engine stops only when it is idle for long enough") {
            let limit = Duration.seconds(1800)
            let cases: [Case] = [
                Case(running: false, attached: false, limit: limit, idle: 9999, then: .engineGone),
                Case(running: true, attached: true, limit: limit, idle: 9999, then: .inUse),
                Case(running: true, attached: false, limit: limit, idle: 0, then: .waiting),
                Case(running: true, attached: false, limit: limit, idle: 1799, then: .waiting),
                Case(running: true, attached: false, limit: limit, idle: 1800, then: .stop),
                Case(running: true, attached: false, limit: limit, idle: 1801, then: .stop),
                // "never" is honoured literally — the user's explicit choice
                // to keep the engine warm, not a long timeout.
                Case(running: true, attached: false, limit: nil, idle: 999_999, then: .waiting),
                // An attached client outranks everything except the engine
                // already being gone.
                Case(running: true, attached: true, limit: nil, idle: 999_999, then: .inUse),
            ]
            for row in cases {
                Harness.expectEqual(
                    Idle.verdict(
                        engineRunning: row.running, attached: row.attached, limit: row.limit,
                        idleFor: row.idle),
                    row.then, row.said)
            }
        }

        // The boundary, separately, because `>` instead of `>=` passes every
        // test above except this one.
        Harness.test("the threshold is inclusive") {
            Harness.expectEqual(
                Idle.verdict(
                    engineRunning: true, attached: false, limit: .seconds(60),
                    idleFor: .seconds(60)),
                .stop, "exactly at the limit did not stop")
        }

        // The attachment contract. No timers involved — it is a lock.
        Harness.test("an attachment is visible while it is held, and not after") {
            Harness.expectTrue(!Idle.attached(), "something was attached before the test began")
            do {
                let held = Idle.Attachment(reason: "test")
                Harness.expectTrue(held != nil, "the attachment could not be taken")
                Harness.expectTrue(Idle.attached(), "a held attachment was not visible")
            }
            Harness.expectTrue(!Idle.attached(), "an attachment outlived its holder")
        }

        // The race the whole design turns on: a stop must not run while a
        // client is attached, and the check and the stop must be one step.
        Harness.test("an attached client prevents the stop") {
            let held = Idle.Attachment(reason: "test")
            Harness.expectTrue(held != nil, "the attachment could not be taken")
            let stopped = runSync { await Idle.stopIfUnattached {} }
            guard case .success(let ran) = stopped else {
                Harness.expectTrue(false, "the guarded stop threw")
                return
            }
            Harness.expectTrue(!ran, "the engine was stopped while a client was using it")
            withExtendedLifetime(held) {}
        }

        Harness.test("with nothing attached the stop runs") {
            Harness.expectTrue(!Idle.attached(), "something was still attached")
            let box = Box(false)
            let stopped = runSync { await Idle.stopIfUnattached { box.set(true) } }
            guard case .success(let ran) = stopped else {
                Harness.expectTrue(false, "the guarded stop threw")
                return
            }
            Harness.expectTrue(ran, "the stop did not run with nothing attached")
            Harness.expectTrue(box.get(), "the stop was reported as run but did nothing")
        }

        // ⚠ A lock file naming a live PID looks, to a second attempt in the
        // SAME process, like a lock it already holds. `flock` does not, which
        // is what lets the attachment be one mechanism.
        Harness.test("two attachments in one process both count") {
            var first = Idle.Attachment(reason: "one")
            var second = Idle.Attachment(reason: "two")
            Harness.expectTrue(first != nil && second != nil, "a second attachment was refused")
            Harness.expectTrue(Idle.attached(), "two attachments read as none")
            withExtendedLifetime(first) {}
            first = nil
            Harness.expectTrue(Idle.attached(), "releasing one attachment released both")
            withExtendedLifetime(second) {}
            second = nil
            Harness.expectTrue(!Idle.attached(), "the last attachment did not release")
        }

        // The loop itself, against a fake clock — so a thirty-minute policy
        // is exercised in microseconds and the test never sleeps.
        Harness.test("the watch loop stops the engine once and then exits") {
            let running = Box(true)
            let stops = Box(0)
            // Short durations against the real clock: the policy is proven by
            // value above, so this exercises the LOOP re-reading the clock,
            // acting once and returning.
            let result = runSync(within: 5) {
                await Idle.watch(
                    limit: .milliseconds(20), poll: .milliseconds(1),
                    engineRunning: { running.get() },
                    stop: {
                        stops.set(stops.get() + 1)
                        running.set(false)
                    })
                return true
            }
            guard case .success = result else {
                Harness.expectTrue(false, "the watch loop never returned")
                return
            }
            Harness.expectEqual(stops.get(), 1, "the engine was stopped \(stops.get()) times")
        }

        // A supervisor with nothing to supervise is an unattended process.
        // ⚠ Bounded: unbounded, a faulted exit condition hangs the whole
        // suite, which is how a watchdog that never exits presents.
        Harness.test("a watchdog whose engine vanished exits on its own") {
            let result = runSync(within: 5) {
                await Idle.watch(
                    limit: .seconds(60), poll: .milliseconds(1),
                    engineRunning: { false },
                    stop: { Harness.expectTrue(false, "it stopped an engine that was gone") })
                return true
            }
            guard case .success = result else {
                Harness.expectTrue(false, "the watchdog did not exit when its engine vanished")
                return
            }
            Harness.expectTrue(true, "the watchdog exited")
        }

        // The real detached process, lock and loop, with `sleep` for the JVMs:
        // the seam that catches the binary resolving, the process surviving its
        // parent, and the lock excluding a second watchdog.
        Harness.test("a real watchdog stops a real process and exits") {
            guard let binary = watchdogBinaryForTests() else {
                Harness.expectTrue(false, "no oilbird binary to run as a watchdog")
                return
            }
            // A stand-in engine: something that stays alive until stopped.
            let sleeper = Process()
            sleeper.executableURL = URL(filePath: "/bin/sleep")
            sleeper.arguments = ["120"]
            try? sleeper.run()
            defer { if sleeper.isRunning { sleeper.terminate() } }
            // ⚠ The precondition, ASSERTED: `try?` swallowing a launch failure
            // leaves `isRunning` false from the start, the wait returns at
            // once, and the test passes having watched nothing.
            Harness.expectTrue(sleeper.isRunning, "the stand-in engine never started")

            try? FileManager.default.createDirectory(
                at: Paths.State.run, withIntermediateDirectories: true)
            try? Supervise.record(
                app: sleeper.processIdentifier,
                group: getpgid(sleeper.processIdentifier))
            try? Data(#"{"webPort":1,"databasePort":2}"#.utf8)
                .write(to: Paths.State.run.appending(path: "running.json"))

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

            // Also assert it is STILL running once the watchdog is up, so a
            // process that died on its own cannot be mistaken for a stop.
            Harness.expectTrue(
                sleeper.isRunning, "the stand-in engine died before the watchdog could act")
            let stopped = settle(within: 15) { !sleeper.isRunning }
            Harness.expectTrue(stopped, "the watchdog never stopped the idle engine")
            let exited = settle(within: 10) { !watchdog.isRunning }
            Harness.expectTrue(exited, "the watchdog did not exit after stopping the engine")
            Harness.expectTrue(
                !FileManager.default.fileExists(
                    atPath: Paths.State.run.appending(path: "running.json").path),
                "the engine was stopped but its record was left behind")
        }

        // ⚠ A large analysis outlasts the idle interval, so an operation that
        // does not attach has its services stopped underneath it. Asserted
        // through the FACADE, where the rule lives, so every client gets it.
        Harness.test("an engine operation holds the engine open while it runs") {
            let before = Idle.attachmentStats()
            Harness.expectEqual(before.heldNow, 0, "something was attached before the test began")
            // `projects()` fails here, but it must attach BEFORE discovering
            // that and release after. Counted, not sampled: the failing call
            // releases in microseconds and observing it is a race.
            _ = runSync(within: 5) { try? await Oilbird.projects() }
            let after = Idle.attachmentStats()
            Harness.expectTrue(
                after.everTaken > before.everTaken,
                "an engine operation ran without holding the engine open")
            Harness.expectEqual(
                after.heldNow, 0, "an engine operation left the engine attached after finishing")
        }

        // ⚠ Ignoring attachments lets any client that thinks the
        // engine is unhealthy stop it under a running scan, which cost six of
        // eight scans and nine stop/start cycles in twenty-four minutes.
        Harness.test("the engine is not stopped while something is using it") {
            Harness.expectTrue(!Idle.attached(), "something was attached already")
            let held = Idle.Attachment(reason: "a long scan")
            let refused = runSync(within: 10) { await Oilbird.down() }
            guard case .success(let stopped) = refused else {
                Harness.expectTrue(false, "down threw")
                return
            }
            Harness.expectTrue(!stopped, "the engine was stopped with a scan attached")
            withExtendedLifetime(held) {}
        }

        // And the override, because a user asking directly outranks a client's
        // guess, and because the watchdog holds the lock itself: an un-forced
        // stop would see its own lock and never fire.
        Harness.test("a forced stop goes through") {
            let held = Idle.Attachment(reason: "a long scan")
            let forced = runSync(within: 10) { await Oilbird.down(force: true) }
            guard case .success(let stopped) = forced else {
                Harness.expectTrue(false, "a forced down threw")
                return
            }
            Harness.expectTrue(stopped, "a forced stop was refused")
            withExtendedLifetime(held) {}
        }

        // One slow answer is not death. With no engine recorded at all
        // the verdict is immediate; the patience is for the case where a
        // record exists and the server is merely busy.
        Harness.test("no engine at all is gone without waiting") {
            let start = ContinuousClock().now
            let gone = runSync(within: 5) { await Oilbird.isGone() }
            guard case .success(true) = gone else {
                Harness.expectTrue(false, "an absent engine was not reported gone")
                return
            }
            Harness.expectTrue(
                start.duration(to: ContinuousClock().now) < .seconds(1),
                "an absent engine took the slow path")
        }
    }
}

/// The `oilbird` binary this test run should use as a watchdog.
///
/// The suite runs as `oilbird-tests`, so the sibling `oilbird` in the same
/// build directory is the one built from this source.
private func watchdogBinaryForTests() -> URL? {
    let sibling = URL(filePath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .appending(path: "oilbird")
    return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
}
