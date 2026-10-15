import CryptoKit
import Foundation
import OilbirdCore
import OilbirdModel

/// The rest of the twelve declared faults, injected.
///
/// The fault matrix in `scripts/fault-injection.sh` names twelve, and its
/// last column names the suite that injects each. `FetchFaultTests` takes
/// three and `PortsTests` takes `decoy-port`; these are the remaining eight.
///
/// `offline`           connection refused; actionable, and nothing left behind.
/// `stall`             a live socket that says nothing; the caller can stop.
/// `disk-full`         a volume that fills mid-extract; named, and cleaned up.
/// `quarantine`        Gatekeeper's kill, named rather than described.
/// `stale-pid`         a pidfile from a crash; not adopted, not deleted.
/// `recycled-pid`      a pidfile naming a live stranger; hard block.
/// `half-initialised`  a cluster missing a marker; corrupt, not "starting".
/// `never-healthy`     a server that never comes up; a timeout with the log.
///
/// ⚠ Three of the eight found real defects, which is the argument for
/// injecting the other nine rather than reasoning about them: `offline` left
/// as a raw `URLError`, the one branch naming a quarantine kill compared
/// against a number `Process` never returns, and a full disk was reported as
/// a bad download with "Download again" for a recovery.
func faultTests() {
    /// A body worth downloading: bigger than `Fetch`'s 1 MiB write buffer, and
    /// not compressible, so a truncation cannot pass a digest.
    func made(_ count: Int) -> Data {
        var data = Data()
        data.reserveCapacity(count)
        var seed: UInt32 = 0x51ED_270B
        for _ in 0..<count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            data.append(UInt8(truncatingIfNeeded: seed >> 16))
        }
        return data
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func clearPartials() {
        try? FileManager.default.removeItem(at: Paths.Cache.partials)
    }

    func partialBytes(_ sha: String) -> Int64 {
        let at = Paths.Cache.partials.appending(path: sha)
        return (try? FileManager.default.attributesOfItem(atPath: at.path)[.size] as? Int64) ?? 0
    }

    /// A directory of this suite's own, under the sandboxed container.
    func scratch(_ name: String) -> URL {
        let at = Paths.Cache.temp.appending(path: "faults-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        return at
    }

    Harness.suite("Fault injection — the download faults that are not the bytes") {
        // ⚠ A port taken and released, so nothing is listening on it. Naming a
        // port nobody has held risks a real service answering and the fault
        // becoming "something replied", which is not this test.
        Harness.test("offline — connection refused is actionable, and leaves nothing") {
            guard let dead = try? Ports.free() else {
                Harness.expectTrue(false, "could not find a port to leave empty")
                return
            }
            let body = made(4096)
            let sha = sha256(body)
            clearPartials()
            let outcome = runSync(within: 30) {
                try await Fetch.artifact(
                    url: Loopback.url(port: dead).appending(path: "artifact.bin"),
                    expecting: sha, bytes: Int64(body.count))
            }
            guard case .failure(let error) = outcome else {
                Harness.expectTrue(false, "a download from a dead port reported success")
                return
            }
            guard let oilbird = error as? OilbirdError else {
                Harness.expectTrue(
                    false,
                    "connection refused arrived as \(type(of: error)), which has no recovery: "
                        + "\(error)")
                return
            }
            Harness.expectEqual(oilbird.cause, .offline, "the wrong cause was reported")
            Harness.expectNotEmpty(oilbird.recovery.actionLabel, "an offline failure offered no way out")
            Harness.expectEqual(partialBytes(sha), 0, "a refused connection left bytes behind")
        }

        // ⚠ Asserted by the deadline, not by an error. A stall produces no
        // error at all — that is what makes it a stall — so what is being
        // tested is that the CALLER gets control back.
        Harness.test("stall — a silent live socket does not hold the caller") {
            let body = made(3 << 20)
            let sha = sha256(body)
            guard let server = FaultServer(serving: body, fault: .stall(after: 1 << 20)) else {
                Harness.expectTrue(false, "no fault server")
                return
            }
            defer { server.stop() }
            clearPartials()

            let began = Date()
            let outcome = runSync(within: 3) {
                try await Fetch.artifact(
                    url: server.url, expecting: sha, bytes: Int64(body.count))
            }
            let waited = Date().timeIntervalSince(began)
            guard case .failure(let error) = outcome else {
                Harness.expectTrue(false, "a stalled transfer reported success")
                return
            }
            Harness.expectTrue(
                error is TimedOut, "a stall ended some other way: \(error)")
            Harness.expectTrue(
                waited < 10,
                "cancelling a stalled download took \(Int(waited))s, so it did not cancel")
            Harness.expectTrue(
                partialBytes(sha) > 0,
                "the stall kept no bytes, so the resume has nothing to resume from")
        }

        // The inverse, and the half that makes the rule mean something: slow
        // must not be read as stalled. Sixteen pieces, 40 ms apart.
        Harness.test("stall — a slow transfer is not a stalled one, and completes") {
            let body = made(1 << 19)
            let sha = sha256(body)
            guard
                let server = FaultServer(
                    serving: body, fault: .slow(chunk: 1 << 15, pause: 0.04))
            else {
                Harness.expectTrue(false, "no fault server")
                return
            }
            defer { server.stop() }
            clearPartials()

            let outcome = runSync(within: 30) {
                try await Fetch.artifact(
                    url: server.url, expecting: sha, bytes: Int64(body.count))
            }
            guard case .success(let file) = outcome else {
                Harness.expectTrue(false, "a slow but complete transfer failed: \(outcome)")
                return
            }
            let landed = (try? Data(contentsOf: file)).map { sha256($0) }
            Harness.expectEqual(landed, sha, "a slow transfer did not arrive intact")
        }
    }

    Harness.suite("Fault injection — the install faults") {
        // ⚠ A real volume, because ENOSPC cannot be faked: a read-only or
        // missing directory raises EACCES or ENOENT, which are different
        // errno values with different advice attached.
        Harness.test("disk-full — a volume that fills mid-extract is named, not blamed") {
            let work = scratch("diskfull")
            defer { try? FileManager.default.removeItem(at: work) }
            let image = work.appending(path: "tiny.dmg")
            let volume = work.appending(path: "volume")
            let created = runSync(within: 60) {
                try await Child.run(
                    URL(filePath: "/usr/bin/hdiutil"),
                    [
                        "create", "-size", "2m", "-fs", "HFS+", "-volname", "OilbirdFault",
                        "-quiet", image.path,
                    ])
            }
            guard case .success(let create) = created, create.status == 0 else {
                Harness.expectTrue(false, "could not create a small volume: \(created)")
                return
            }
            let attached = runSync(within: 60) {
                try await Child.run(
                    URL(filePath: "/usr/bin/hdiutil"),
                    ["attach", image.path, "-nobrowse", "-quiet", "-mountpoint", volume.path])
            }
            guard case .success(let mount) = attached, mount.status == 0 else {
                Harness.expectTrue(false, "could not attach the small volume: \(attached)")
                return
            }
            defer {
                _ = runSync(within: 60) {
                    try await Child.run(
                        URL(filePath: "/usr/bin/hdiutil"), ["detach", "-force", volume.path])
                }
            }

            // Six mebibytes of incompressible bytes into a two-mebibyte
            // volume. The archive is built outside it, on the real disk.
            let payload = work.appending(path: "payload.bin")
            try? made(6 << 20).write(to: payload)
            let archive = work.appending(path: "payload.tar.gz")
            let packed = runSync(within: 60) {
                try await Child.run(
                    URL(filePath: "/usr/bin/tar"),
                    ["czf", archive.path, "-C", work.path, "payload.bin"])
            }
            guard case .success(let tar) = packed, tar.status == 0 else {
                Harness.expectTrue(false, "could not build the archive: \(packed)")
                return
            }

            let destination = volume.appending(path: "dependency")
            do {
                try Install.artifact(at: archive, archive: .tarGz, into: destination)
                Harness.expectTrue(false, "unpacking into a full volume reported success")
            } catch let error as OilbirdError {
                Harness.expectEqual(error.cause, .diskFull, "a full disk was reported as \(error.cause)")
                guard case .freeSpace = error.recovery else {
                    Harness.expectTrue(
                        false,
                        "a full disk offered \(error.recovery.actionLabel), which cannot help")
                    return
                }
                Harness.expectTrue(
                    !FileManager.default.fileExists(
                        atPath: destination.appendingPathExtension("incoming").path),
                    "the half-extracted staging directory was left on the full volume")
            } catch {
                Harness.expectTrue(false, "a full disk raised \(type(of: error)): \(error)")
            }
        }

        Harness.test("quarantine — the flag is found, and clearing it is checked") {
            let tree = scratch("quarantine")
            defer { try? FileManager.default.removeItem(at: tree) }
            let file = tree.appending(path: "postgres")
            try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            let marked = runSync(within: 30) {
                try await Child.run(
                    URL(filePath: "/usr/bin/xattr"),
                    ["-w", "com.apple.quarantine", "0081;00000000;Oilbird;", file.path])
            }
            guard case .success(let set) = marked, set.status == 0 else {
                Harness.expectTrue(false, "could not set the quarantine flag: \(marked)")
                return
            }
            Harness.expectTrue(
                !Install.quarantined(in: tree).isEmpty,
                "a quarantined file was not seen as quarantined")
            do {
                try Install.stripQuarantine(tree)
            } catch {
                Harness.expectTrue(false, "the strip failed on a tree it should clear: \(error)")
                return
            }
            Harness.expectTrue(
                Install.quarantined(in: tree).isEmpty, "the flag survived the strip")
        }

        // ⚠ The fault this one really injects is in the DETECTION. Gatekeeper
        // kills with `SIGKILL`, and the branch that named it compared against
        // 137 — a shell's spelling, and a value `terminationStatus` never has.
        Harness.test("quarantine — a killed child is known to be killed, not exited") {
            let outcome = runSync(within: 30) {
                try await Child.run(URL(filePath: "/bin/sh"), ["-c", "kill -9 $$"])
            }
            guard case .success(let result) = outcome else {
                Harness.expectTrue(false, "could not run a child that kills itself: \(outcome)")
                return
            }
            Harness.expectTrue(result.killedBySIGKILL, "a SIGKILLed child did not read as killed")
            Harness.expectEqual(result.signal, SIGKILL, "the signal was not carried")
            Harness.expectTrue(
                result.status != 137,
                "status was 137 after all, so the old comparison was reachable")
        }
    }

    Harness.suite("Fault injection — the cluster faults") {
        let data = Paths.State.clusterData

        /// PostgreSQL's own `postmaster.pid` layout, stable since 9.3: pid,
        /// data directory, start time, port, socket directory.
        func writePidfile(pid: Int32, port: UInt16, directory: URL = data) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let text = [
                "\(pid)", directory.path, "\(Int(Date().timeIntervalSince1970))", "\(port)",
                "/tmp",
            ].joined(separator: "\n")
            try? Data((text + "\n").utf8).write(to: directory.appending(path: "postmaster.pid"))
        }

        func clearCluster() {
            try? FileManager.default.removeItem(at: data)
        }

        // ⚠ Two assertions, and the second is the one with teeth. Not adopting
        // is easy; not DELETING a pidfile Oilbird did not write is the rule,
        // and PostgreSQL clears a stale one itself on the next start.
        Harness.test("stale-pid — a pidfile from a crash is not adopted, and is left alone") {
            clearCluster()
            defer { clearCluster() }
            let dead = runSync(within: 30) {
                try await Child.run(URL(filePath: "/bin/echo"), ["done"])
            }
            guard case .success = dead else {
                Harness.expectTrue(false, "could not produce a finished process")
                return
            }
            // A pid far above anything this machine has reached, so it is dead
            // by construction rather than by a race with pid reuse.
            writePidfile(pid: 99998, port: 65000)
            Harness.expectNil(
                Cluster.alreadyRunning(), "a stale pidfile was adopted as a running database")
            Harness.expectTrue(
                FileManager.default.fileExists(
                    atPath: data.appending(path: "postmaster.pid").path),
                "Oilbird deleted a pidfile it did not write")
        }

        // The recorded pid is THIS process: alive, ours, and not a postmaster.
        // A check that stopped at "the pid is alive" would adopt the test
        // runner as a database.
        Harness.test("recycled-pid — a live stranger in the pidfile is a hard block") {
            clearCluster()
            defer { clearCluster() }
            guard let quiet = try? Ports.free() else {
                Harness.expectTrue(false, "could not find a port nothing answers on")
                return
            }
            writePidfile(pid: getpid(), port: quiet)
            Harness.expectNil(
                Cluster.alreadyRunning(),
                "a live process that is not a postmaster was adopted as one")
            Harness.expectTrue(
                FileManager.default.fileExists(
                    atPath: data.appending(path: "postmaster.pid").path),
                "the pidfile was blindly deleted rather than validated")
        }

        // ⚠ All three markers, one at a time. A directory holding only
        // `PG_VERSION` starts and then dies on a missing `postgresql.conf`,
        // which reads as a crash rather than as a bad install.
        Harness.test("half-initialised — any missing marker is not an initialised cluster") {
            clearCluster()
            defer { clearCluster() }
            let manager = FileManager.default
            try? manager.createDirectory(at: data, withIntermediateDirectories: true)
            Harness.expectTrue(!Cluster.isInitialised(), "an empty directory read as initialised")

            try? Data("16\n".utf8).write(to: data.appending(path: "PG_VERSION"))
            Harness.expectTrue(
                !Cluster.isInitialised(), "PG_VERSION alone read as an initialised cluster")

            try? Data("".utf8).write(to: data.appending(path: "postgresql.conf"))
            Harness.expectTrue(
                !Cluster.isInitialised(), "a cluster with no `base` read as initialised")

            try? manager.createDirectory(
                at: data.appending(path: "base"), withIntermediateDirectories: true)
            Harness.expectTrue(
                Cluster.isInitialised(), "all three markers still did not read as initialised")
            Harness.expectEqual(
                Cluster.dataDirectoryMajor(), "16", "the major was not read back")
        }
    }

    Harness.suite("Fault injection — a server that never comes up") {
        // DOWN is terminal: it will not become UP on its own, so the poll must
        // stop rather than spend its whole budget learning nothing.
        Harness.test("never-healthy — a server answering DOWN stops the wait") {
            guard
                let server = FixtureServer(answer: { request in
                    request.path.hasPrefix("/api/system/status")
                        ? .ok("{\"id\":\"fault\",\"version\":\"26.9\",\"status\":\"DOWN\"}")
                        : .notFound
                })
            else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let began = Date()
            let outcome = runSync(within: 60) {
                try await Supervise.awaitReady(webPort: server.port, timeout: 30)
            }
            let waited = Date().timeIntervalSince(began)
            guard case .failure(let error) = outcome, let oilbird = error as? OilbirdError else {
                Harness.expectTrue(false, "a server stuck at DOWN did not fail: \(outcome)")
                return
            }
            Harness.expectEqual(oilbird.cause, .serverUnhealthy, "the wrong cause was reported")
            Harness.expectTrue(
                oilbird.recovery.actionLabel.lowercased().contains("log"),
                "the recovery was \(oilbird.recovery.actionLabel), which does not reach the log")
            Harness.expectTrue(
                waited < 25, "a terminal state was polled for \(Int(waited))s before stopping")
        }

        // ⚠ And the other shape: a server that answers nothing readable at
        // all. There is no terminal state to notice, so the only thing that
        // ends the wait is the budget — and it must end, with the log.
        Harness.test("never-healthy — a server that never answers times out with the log") {
            guard let server = FixtureServer(answer: { _ in serverError }) else {
                Harness.expectTrue(false, "no fixture server")
                return
            }
            defer { server.stop() }
            let outcome = runSync(within: 30) {
                try await Supervise.awaitReady(webPort: server.port, timeout: 1)
            }
            guard case .failure(let error) = outcome, let oilbird = error as? OilbirdError else {
                Harness.expectTrue(false, "an unreachable server did not fail: \(outcome)")
                return
            }
            Harness.expectEqual(oilbird.cause, .serverUnhealthy, "the wrong cause was reported")
            Harness.expectTrue(
                oilbird.underlying?.contains("no UP within") == true,
                "the timeout did not say what it waited for: \(oilbird.underlying ?? "nothing")")
        }
    }
}

/// A server error, which `systemStatus` reads as "no answer" rather than as a
/// state — the shape of a SonarQube still starting its web stack.
private let serverError = FixtureServer.Reply(status: 503, body: "{}")
