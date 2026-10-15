import Foundation
import OilbirdModel

/// A loopback HTTP server that serves BYTES, and serves them badly on purpose.
///
/// `FixtureServer` answers as SonarQube: JSON, a computed `Content-Length`, no
/// ranges. A download is the other half of the product and fails in ways JSON
/// cannot express — a body that stops early, a byte that flipped in transit, a
/// `Content-Length` the body does not honour. Those are three of the twelve
/// slugs in the fault matrix in `scripts/fault-injection.sh`.
///
/// ⚠ Ranges are real here, not stubbed. `Fetch` resumes by asking for
/// `bytes=N-` and appending only on a 206, so a fixture that answered 200 to
/// every request would make the resume path look tested while never running
/// it.
final class FaultServer: @unchecked Sendable {
    /// What this serves, named for the slug it injects.
    enum Fault: Sendable, Equatable {
        /// The body, whole and correct.
        case none
        /// `Content-Length` promises the whole body; the connection closes
        /// after this many bytes of it.
        ///
        /// ⚠ The bytes are sent, then the fixture WAITS before closing. Without
        /// the wait, whether the consumer sees them at all is a race between
        /// URLSession's delivery and its noticing the close: locally it yielded
        /// 163,195 bytes and on a CI runner it yielded none, so the same
        /// assertion passed on one machine and failed on the other. The wait
        /// makes "some bytes arrived" true everywhere, which is the only
        /// condition under which there is anything to resume from.
        case truncate(after: Int)
        /// The right length, with one byte of the body flipped.
        case corrupt(at: Int)
        /// `Content-Length` says this, and the body says otherwise.
        case wrongLength(claimed: Int)
        /// The headers, then this many bytes, then nothing at all — the
        /// connection stays open and idle until the fixture is stopped.
        ///
        /// ⚠ A stall is not a drop. The socket is alive, so nothing errors
        /// and nothing arrives: the caller waits, and whether the caller can
        /// STOP waiting is the whole of the rule: slow must be told from stuck.
        case stall(after: Int)
        /// The whole body, correct, delivered in pieces with a pause between
        /// them. The inverse assertion: slow must not be read as stalled.
        case slow(chunk: Int, pause: TimeInterval)
    }

    struct Request: Sendable, Equatable {
        let method: String
        let path: String
        /// The first byte a `Range: bytes=N-` asked for, or nil for a whole-body
        /// request. Recorded because "did it resume" is a question about the
        /// REQUEST, and asserting it on the result would pass for a client that
        /// simply downloaded the whole thing again.
        let rangeFrom: Int?
    }

    let port: UInt16

    private let body: Data
    private let listener: Int32
    private let gate = NSLock()
    private var fault: Fault
    private var received: [Request] = []
    /// Set by `stop()`, so a stalling connection lets go of its thread
    /// instead of sleeping out its full budget after the suite has moved on.
    private var stopped = false

    /// `nil` when the socket could not be taken, so a suite reports "no fault
    /// server" rather than failing an assertion about the downloader.
    init?(serving body: Data, fault: Fault = .none) {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(handle, 8) == 0 else {
            close(handle)
            return nil
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }

        self.body = body
        self.fault = fault
        self.listener = handle
        self.port = UInt16(bigEndian: assigned.sin_port)

        let thread = Thread { [self] in serve() }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Where the artefact is, for `Fetch.artifact(url:)`.
    var url: URL { Loopback.url(port: port).appending(path: "artifact.bin") }

    var requests: [Request] {
        gate.lock()
        defer { gate.unlock() }
        return received
    }

    /// Changes what the NEXT request gets. A resume is two requests with
    /// different answers, which is the whole shape of the `truncate` rule.
    func set(_ next: Fault) {
        gate.lock()
        fault = next
        gate.unlock()
    }

    func stop() {
        gate.lock()
        stopped = true
        gate.unlock()
        close(listener)
    }

    private var isStopped: Bool {
        gate.lock()
        defer { gate.unlock() }
        return stopped
    }

    // MARK: -

    private func serve() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            Self.silenceSIGPIPE(on: client)
            respond(on: client)
            close(client)
        }
    }

    /// Stops `send` raising SIGPIPE on a socket whose peer has already closed.
    ///
    /// ⚠ There is no handler for it in the test binary, so the signal kills
    /// the whole process mid-suite. The summary CI parses is then never
    /// printed and CI reports the parse failure — "printed no 'N assertions, M
    /// failed'" — which names nothing useful. The truncate fault closes
    /// connections early by design, so this fixture provokes SIGPIPE on
    /// purpose and has to survive it; EPIPE from `send` is the same
    /// information without the process death.
    static func silenceSIGPIPE(on socket: Int32) {
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The first byte of a `Range: bytes=N-` header, if there is one.
    static func rangeStart(in head: String) -> Int? {
        for line in head.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("range:") else { continue }
            guard let equals = lower.range(of: "bytes=") else { return nil }
            let rest = lower[equals.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        return nil
    }

    private func respond(on client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let read = recv(client, &buffer, buffer.count, 0)
        guard read > 0, let text = String(bytes: buffer[0..<read], encoding: .utf8),
            let head = text.components(separatedBy: "\r\n").first
        else { return }
        let parts = head.split(separator: " ")
        guard parts.count >= 2 else { return }

        let from = Self.rangeStart(in: text)
        gate.lock()
        received.append(
            Request(method: String(parts[0]), path: String(parts[1]), rangeFrom: from))
        let injected = fault
        gate.unlock()

        // A range past the end is the one case a real server answers 416; it
        // cannot arise from `Fetch`, which only ranges when the partial is
        // shorter than the artefact, so it is refused rather than guessed at.
        guard from == nil || (from ?? 0) < body.count else {
            send(on: client, header: "HTTP/1.1 416 Range Not Satisfiable", extra: [], payload: Data())
            return
        }

        var slice = from.map { body.subdata(in: $0..<body.count) } ?? body
        let status = from == nil ? "HTTP/1.1 200 OK" : "HTTP/1.1 206 Partial Content"
        var extra: [String] = []
        if let from {
            extra.append("Content-Range: bytes \(from)-\(body.count - 1)/\(body.count)")
        }

        // ⚠ The header is written from the length the fault CLAIMS, and the
        // payload from what it sends. Deriving one from the other is what
        // makes `wrong-length` impossible to inject.
        var claimed = slice.count
        var payload = slice
        switch injected {
        case .none:
            break
        case .truncate(let after):
            payload = slice.prefix(after)
        case .corrupt(let at):
            if at < slice.count { slice[slice.startIndex + at] ^= 0xFF }
            payload = slice
        case .wrongLength(let promised):
            claimed = promised
        case .stall(let after):
            payload = slice.prefix(after)
        case .slow:
            break
        }
        if case .slow(let size, let pause) = injected {
            sendSlowly(
                on: client, header: status, extra: extra + ["Content-Length: \(claimed)"],
                payload: payload, at: Pacing(chunk: size, pause: pause))
            return
        }
        send(
            on: client, header: status, extra: extra + ["Content-Length: \(claimed)"],
            payload: payload)
        if case .truncate = injected { Thread.sleep(forTimeInterval: Self.deliveryPause) }
        // ⚠ Held open, not closed. Closing makes this a truncation, which a
        // client can SEE; a stall is silence on a live socket, the only shape
        // that reaches the caller's own timeout or cancellation.
        if case .stall = injected {
            var waited: TimeInterval = 0
            while waited < Self.stallBudget && !isStopped {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
        }
    }

    /// Long enough for a loopback delivery, short enough not to be felt.
    private static let deliveryPause: TimeInterval = 0.5

    /// The longest a stalled connection is held. Far past any deadline a
    /// test sets, and bounded so a leaked fixture cannot outlive the run.
    private static let stallBudget: TimeInterval = 30

    /// How slowly. A type rather than two parameters, because six of them
    /// is one more than the linter allows and these two are one idea.
    private struct Pacing {
        let chunk: Int
        let pause: TimeInterval
    }

    /// The body in pieces, with a pause between them, and the connection
    /// closed properly at the end. Slow, and finished.
    private func sendSlowly(
        on client: Int32, header: String, extra: [String], payload: Data, at pacing: Pacing
    ) {
        send(on: client, header: header, extra: extra, payload: Data())
        var offset = 0
        while offset < payload.count && !isStopped {
            let end = min(offset + pacing.chunk, payload.count)
            var piece = Array(payload[payload.startIndex + offset..<payload.startIndex + end])
            // `size` outside the closure, for the exclusivity reason `send`
            // records: reading `piece.count` inside a closure that already
            // holds exclusive access to `piece` does not compile.
            let size = piece.count
            var written = 0
            while written < size {
                let sent = piece.withUnsafeMutableBytes {
                    Darwin.send(client, $0.baseAddress?.advanced(by: written), size - written, 0)
                }
                guard sent > 0 else { return }
                written += sent
            }
            offset = end
            if offset < payload.count { Thread.sleep(forTimeInterval: pacing.pause) }
        }
    }

    private func send(on client: Int32, header: String, extra: [String], payload: Data) {
        var head = header + "\r\n"
        head += "Content-Type: application/octet-stream\r\n"
        head += "Accept-Ranges: bytes\r\n"
        for line in extra { head += line + "\r\n" }
        head += "Connection: close\r\n\r\n"
        var bytes = Array(head.utf8) + Array(payload)
        // `total` outside the closure: reading `bytes.count` inside one that
        // already has exclusive access to `bytes` is an exclusivity violation,
        // which `-warnings-as-errors` refuses outright.
        let total = bytes.count
        var offset = 0
        while offset < total {
            let sent = bytes.withUnsafeMutableBytes {
                Darwin.send(client, $0.baseAddress?.advanced(by: offset), total - offset, 0)
            }
            guard sent > 0 else { return }
            offset += sent
        }
    }
}
