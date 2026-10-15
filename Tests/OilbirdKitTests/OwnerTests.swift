import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

func ownerTests() {
    Harness.suite("Owner — one process owns the cluster, held two ways") {
        Harness.test("the lock can be taken and released") {
            Owner.release()
            var took = true
            do { try Owner.acquire() } catch { took = false }
            Harness.expectTrue(took, "could not take a free lock")
            Owner.release()
        }

        // A file lock alone fails here: the second attempt finds a lock naming
        // its own live PID, concludes it is the holder, and opens. This is
        // exactly why there are two mechanisms.
        Harness.test("a second attempt inside one process is refused") {
            Owner.release()
            try? Owner.acquire()
            var refused = false
            do { try Owner.acquire() } catch { refused = true }
            Harness.expectTrue(refused, "the in-process owner let a second acquire through")
            Owner.release()
        }

        Harness.test("a released lock leaves no file behind") {
            Owner.release()
            try? Owner.acquire()
            Owner.release()
            Harness.expectTrue(
                !FileManager.default.fileExists(atPath: Paths.State.clusterLock.path))
        }

        // PIDs are recycled. A lock naming a live but unrelated process must
        // not be reclaimed, and one naming a dead process must be.
        Harness.test("a lock left by a dead process is reclaimed") {
            Owner.release()
            try? FileManager.default.createDirectory(
                at: Paths.State.run, withIntermediateDirectories: true)
            // pid 999999 is above the default pid_max and cannot be live.
            let stale = #"{"pid":999999,"host":"gone","started":"2020-01-01T00:00:00Z","argv":"x"}"#
            try? Data(stale.utf8).write(to: Paths.State.clusterLock)
            var took = true
            do { try Owner.acquire() } catch { took = false }
            Harness.expectTrue(took, "a dead holder's lock was not reclaimed")
            Owner.release()
        }

        Harness.test("an unreadable lock is refused rather than guessed at") {
            Owner.release()
            try? FileManager.default.createDirectory(
                at: Paths.State.run, withIntermediateDirectories: true)
            try? Data("not json".utf8).write(to: Paths.State.clusterLock)
            var refused = false
            do { try Owner.acquire() } catch { refused = true }
            Harness.expectTrue(refused, "an unreadable lock was deleted rather than refused")
            try? FileManager.default.removeItem(at: Paths.State.clusterLock)
        }

        // `up` leaking the cluster lock leaves every start naming an exited
        // process, so "reclaiming a lock left by dead pid" fires every time
        // and the once it matters is indistinguishable from the rest.

        // ⚠ Asserted at the CALL SITE, not the primitive: `acquire`/`release`
        // were never broken, and faulting `up` back to the leak leaves a test
        // of those green.

        // `up` throws here for want of a database, which is precisely the path
        // that must still release: a `defer` covers both exits where an
        // explicit release at the end leaks on every failure.
        Harness.test("a failed start does not leave the cluster locked") {
            try? FileManager.default.removeItem(at: Paths.State.clusterLock)
            let result = runSync { try await Oilbird.up() }
            guard case .failure = result else {
                Harness.expectTrue(false, "up unexpectedly succeeded in the sandbox")
                return
            }
            Harness.expectTrue(
                !FileManager.default.fileExists(atPath: Paths.State.clusterLock.path),
                "a start that failed left the cluster locked against every later attempt")
        }

        Harness.test("a completed transition leaves no lock behind") {
            try? FileManager.default.removeItem(at: Paths.State.clusterLock)
            do {
                try Owner.acquire()
                Owner.release()
            } catch {
                Harness.expectTrue(false, "the first acquire failed")
                return
            }
            Harness.expectTrue(
                !FileManager.default.fileExists(atPath: Paths.State.clusterLock.path),
                "a released lock left its file on disk")
            // And the next caller is not made to reclaim anything.
            do {
                try Owner.acquire()
                Owner.release()
                Harness.expectTrue(true, "a second transition proceeded cleanly")
            } catch {
                Harness.expectTrue(false, "the next start had to reclaim a stale lock")
            }
        }

        // ⚠ SonarQube refuses a concurrent analysis of one project and refuses
        // BOTH, so two scans collide and neither says they raced. Queued, not
        // refused: the second caller wanted a scan.
        Harness.test("work for one name is serialised, and other names are not") {
            let order = Box([Int]())
            let result = runSync(within: 20) {
                async let first: Void = Owner.serialised(named: "proj-a") {
                    order.set(order.get() + [1])
                    try? await Task.sleep(for: .milliseconds(300))
                    order.set(order.get() + [2])
                }
                try? await Task.sleep(for: .milliseconds(50))
                async let second: Void = Owner.serialised(named: "proj-a") {
                    order.set(order.get() + [3])
                }
                // A different name must not wait behind either.
                async let other: Void = Owner.serialised(named: "proj-b") {
                    order.set(order.get() + [9])
                }
                _ = try await (first, second, other)
                return true
            }
            guard case .success = result else {
                Harness.expectTrue(false, "the serialised work never finished")
                return
            }
            let seen = order.get()
            guard let start = seen.firstIndex(of: 1), let end = seen.firstIndex(of: 2),
                let queued = seen.firstIndex(of: 3)
            else {
                Harness.expectTrue(false, "not all the work ran: \(seen)")
                return
            }
            Harness.expectTrue(
                queued > end, "the second call ran inside the first: \(seen)")
            // ⚠ The assertion this test exists for. The lock being PER NAME
            // is the property; that `proj-a` serialises with itself is the
            // easy half.
            guard let elsewhere = seen.firstIndex(of: 9) else {
                Harness.expectTrue(false, "work under a different name was lost: \(seen)")
                return
            }
            Harness.expectTrue(
                elsewhere < end,
                "proj-b waited behind proj-a, so the lock is global and not per name: \(seen)")
            _ = start
        }

        // The record is removed before the new one is written, so a client
        // asking during a restart hears "not running". Whoever holds the
        // cluster lock is mid-transition by definition.
        Harness.test("a transition in progress is visible to another client") {
            try? FileManager.default.removeItem(at: Paths.State.clusterLock)
            Harness.expectTrue(
                !Owner.transitionInProgress(), "a transition was reported with no lock")
            try? Owner.acquire()
            Harness.expectTrue(
                Owner.transitionInProgress(), "a held lock did not read as a transition")
            Owner.release()
            Harness.expectTrue(
                !Owner.transitionInProgress(), "the transition outlived the lock")
        }
    }
}
