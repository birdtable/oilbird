import CryptoKit
import Foundation
import OilbirdCore
import OilbirdModel

/// Three of the twelve declared faults, injected.
///
/// The fault matrix in `scripts/fault-injection.sh` names twelve. Downloads
/// are verifiable and resumable: a download truncated mid-transfer resumes
/// and completes, and a corrupted byte fails the checksum closed, with the
/// artifact discarded rather than cached.
///
/// `truncate`      a truncated transfer; resume completes.
/// `corrupt`       corrupted bytes; the checksum fails CLOSED, and the
///                 artefact is discarded rather than cached.
/// `wrong-length`  `Content-Length` disagrees with the body; treated as
///                 corrupt, never as success.
///
/// ⚠ The body is larger than `Fetch`'s 1 MiB write buffer, and deliberately.
/// `transfer` accumulates into a buffer and writes a chunk at a time, so a
/// fixture small enough to fit in one buffer leaves NOTHING on disk when the
/// connection drops — the resume would have nothing to resume from and the
/// test would pass by testing a fresh download.
func fetchFaultTests() {
    let chunk = 1 << 20
    // Not zeroes: a digest over a constant body is the same digest at every
    // length, so a truncation would still verify.
    var scratch = Data(count: 0)
    scratch.reserveCapacity(chunk * 3)
    var seed: UInt32 = 0x9E37_79B9
    for _ in 0..<(chunk * 3) {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        scratch.append(UInt8(truncatingIfNeeded: seed >> 16))
    }
    let body = scratch
    let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    let size = Int64(body.count)

    /// The partials directory, emptied, so one fault's leftovers are not the
    /// next one's cache hit.
    func clearPartials() {
        try? FileManager.default.removeItem(at: Paths.Cache.partials)
    }

    /// The digest of a file, computed here rather than reached for.
    /// `Fetch.digest` is internal to OilbirdCore, and widening a product's API
    /// so a test can see it is how the API stops meaning anything.
    func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What `Fetch` left on disk for the resume to pick up.
    func partialBytes() -> Int64 {
        let at = Paths.Cache.partials.appending(path: sha)
        return (try? FileManager.default.attributesOfItem(atPath: at.path)[.size] as? Int64) ?? 0
    }

    Harness.suite("Fault injection — the three a download can carry") {
        Harness.test("the fault server serves a whole body, and a range as 206") {
            guard let server = FaultServer(serving: body) else {
                Harness.expectTrue(false, "no fault server")
                return
            }
            defer { server.stop() }
            clearPartials()
            let outcome = runSync(within: 60) {
                try await Fetch.artifact(url: server.url, expecting: sha, bytes: size)
            }
            guard case .success(let file) = outcome else {
                Harness.expectTrue(false, "a clean download failed: \(outcome)")
                return
            }
            Harness.expectEqual(digest(of: file), sha, "the clean body did not verify")
            Harness.expectEqual(server.requests.count, 1, "a clean download took more than one go")
            Harness.expectNil(server.requests.first?.rangeFrom, "a first download asked for a range")
        }

        // ⚠ Asserted on the REQUEST as well as the result. A client that threw
        // the partial away and downloaded the whole artefact again would end
        // with the same verified bytes, and the rule is that it resumes.
        Harness.test("truncate — the transfer stops early and the resume completes") {
            guard let server = FaultServer(serving: body, fault: .truncate(after: chunk + 4096))
            else {
                Harness.expectTrue(false, "no fault server")
                return
            }
            defer { server.stop() }
            clearPartials()

            let first = runSync(within: 60) {
                try await Fetch.artifact(url: server.url, expecting: sha, bytes: size)
            }
            guard case .failure = first else {
                Harness.expectTrue(false, "a truncated transfer reported success")
                return
            }
            let kept = partialBytes()
            Harness.expectTrue(
                kept > 0,
                "the truncation left nothing on disk, so there is nothing to resume from")

            server.set(.none)
            let second = runSync(within: 60) {
                try await Fetch.artifact(url: server.url, expecting: sha, bytes: size)
            }
            guard case .success(let file) = second else {
                Harness.expectTrue(false, "the resume did not complete: \(second)")
                return
            }
            Harness.expectEqual(digest(of: file), sha, "the resumed file did not verify")
            Harness.expectEqual(
                server.requests.last?.rangeFrom, Int(kept),
                "the second attempt did not ask to resume from what was kept")
        }

        // ⚠ Two assertions, and the second is the one that matters. A
        // mismatch that is merely reported leaves the bad bytes where a later
        // run finds them the right length and "resumes" forever.
        Harness.test("corrupt — the checksum fails closed and the bytes are discarded") {
            guard let server = FaultServer(serving: body, fault: .corrupt(at: 17)) else {
                Harness.expectTrue(false, "no fault server")
                return
            }
            defer { server.stop() }
            clearPartials()

            let outcome = runSync(within: 60) {
                try await Fetch.artifact(url: server.url, expecting: sha, bytes: size)
            }
            guard case .failure(let error) = outcome else {
                Harness.expectTrue(false, "a corrupted body verified")
                return
            }
            guard let oilbird = error as? OilbirdError else {
                Harness.expectTrue(false, "a corrupted body raised \(type(of: error)), not an OilbirdError")
                return
            }
            Harness.expectEqual(oilbird.cause, .checksumMismatch, "the wrong cause was reported")
            Harness.expectEqual(partialBytes(), 0, "the corrupt artefact was left in the cache")
        }

        Harness.test("wrong-length — a body that disagrees with its header is corrupt") {
            guard let server = FaultServer(serving: body, fault: .wrongLength(claimed: 64)) else {
                Harness.expectTrue(false, "no fault server")
                return
            }
            defer { server.stop() }
            clearPartials()

            let outcome = runSync(within: 60) {
                try await Fetch.artifact(url: server.url, expecting: sha, bytes: size)
            }
            guard case .failure(let error) = outcome else {
                Harness.expectTrue(false, "a body that disagreed with Content-Length was accepted")
                return
            }
            Harness.expectTrue(
                (error as? OilbirdError)?.cause == .checksumMismatch,
                "a short body was not treated as corrupt: \(error)")
            Harness.expectEqual(partialBytes(), 0, "the short artefact was left in the cache")
        }

        // The fixture's own proof. A range parser that silently returned nil
        // would make the resume assertion above pass against a client that
        // never resumed.
        Harness.test("the fixture reads a Range header, and only a Range header") {
            Harness.expectEqual(
                FaultServer.rangeStart(in: "GET /a HTTP/1.1\r\nRange: bytes=1048576-\r\n\r\n"),
                1_048_576)
            Harness.expectNil(
                FaultServer.rangeStart(in: "GET /a HTTP/1.1\r\nContent-Range: bytes 0-3/4\r\n\r\n"))
            Harness.expectNil(FaultServer.rangeStart(in: "GET /a HTTP/1.1\r\n\r\n"))
        }
    }
}
