import Foundation
import OilbirdModel

/// A loopback HTTP server the SonarAPI suites can answer as.
///
/// `SonarAPI` takes a base URL and a token and reaches nothing else, which is
/// exactly what makes this possible — and the migration path is the first
/// thing that genuinely needs it. A migration is a *conversation*: a POST,
/// then a sequence of polls whose answers change, and a verdict. None of that
/// can be asserted on a URL the way the issue search is, and none of it can be
/// asserted against a real SonarQube in a suite that must run on a machine
/// with nothing installed.
///
/// Deliberately tiny and deliberately not a dependency: one connection at a
/// time, one request per connection, `Connection: close`. It records what it
/// was asked, because half of what these tests check is that a call was
/// *made* — the migration defect was an endpoint nothing ever hit.
final class FixtureServer: @unchecked Sendable {
    struct Request: Sendable, Equatable {
        let method: String
        let path: String
    }

    struct Reply: Sendable {
        let status: Int
        let body: String

        static func ok(_ body: String) -> Reply { Reply(status: 200, body: body) }
        static let notFound = Reply(status: 404, body: "{}")
    }

    let port: UInt16
    private let listener: Int32
    private let answer: @Sendable (Request) -> Reply
    private let gate = NSLock()
    private var received: [Request] = []

    /// `nil` when the socket could not be taken, so a suite reports "no
    /// fixture server" rather than failing an assertion about SonarQube.
    init?(answer: @escaping @Sendable (Request) -> Reply) {
        // Every socket call works on a local, not on `self.listener`: a
        // `withUnsafePointer` closure that reaches a stored property captures
        // `self` before the initializer has finished, which does not compile.
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        // Port 0: the OS assigns one, the same way everything else in Oilbird
        // takes a port.
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

        self.answer = answer
        self.listener = handle
        self.port = UInt16(bigEndian: assigned.sin_port)

        let thread = Thread { [self] in serve() }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    var base: URL { Loopback.url(port: port) }

    var requests: [Request] {
        gate.lock()
        defer { gate.unlock() }
        return received
    }

    func stop() {
        // Closing the listener is what unblocks `accept`; there is no other
        // way to wake a thread parked in it.
        close(listener)
    }

    private func serve() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            // The guard `FaultServer.silenceSIGPIPE` documents, for the same
            // reason. Bodies here are small enough that no peer has closed
            // first yet, which makes it latent rather than unnecessary.
            FaultServer.silenceSIGPIPE(on: client)
            respond(on: client)
            close(client)
        }
    }

    private func respond(on client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let read = recv(client, &buffer, buffer.count, 0)
        guard read > 0,
            let text = String(bytes: buffer[0..<read], encoding: .utf8),
            let head = text.split(separator: "\r\n").first
        else { return }
        let parts = head.split(separator: " ")
        guard parts.count >= 2 else { return }
        let request = Request(method: String(parts[0]), path: String(parts[1]))
        gate.lock()
        received.append(request)
        gate.unlock()

        let reply = answer(request)
        let phrase = reply.status == 200 ? "OK" : "Error"
        let response = """
            HTTP/1.1 \(reply.status) \(phrase)\r
            Content-Type: application/json\r
            Content-Length: \(reply.body.utf8.count)\r
            Connection: close\r
            \r
            \(reply.body)
            """
        var bytes = Array(response.utf8)
        _ = send(client, &bytes, bytes.count, 0)
    }
}
