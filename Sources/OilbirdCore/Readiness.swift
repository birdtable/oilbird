import Foundation

/// Is a postmaster actually answering?
///
/// `pg_isready` does not exist in the artifact — it ships only `initdb`,
/// `pg_ctl` and `postgres` — so readiness is probed over the wire.
///
/// A bare TCP connect is not enough: it succeeds against anything listening on
/// the port. An `SSLRequest` is the cheapest message that proves a *postmaster*
/// is on the other end, and it needs no credentials.
public enum Readiness {
    /// The protocol's SSL negotiation request: length 8, then 80877103.
    /// A postmaster replies with a single byte, `S` or `N`.
    public static func postgresAnswering(port: UInt16, host: String = "127.0.0.1") -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return false }

        var request = Data()
        request.append(contentsOf: withUnsafeBytes(of: UInt32(8).bigEndian) { Array($0) })
        request.append(contentsOf: withUnsafeBytes(of: UInt32(80_877_103).bigEndian) { Array($0) })
        let sent = request.withUnsafeBytes { send(handle, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return false }

        var reply: UInt8 = 0
        guard recv(handle, &reply, 1, 0) == 1 else { return false }
        // Anything else means something is listening that is not PostgreSQL.
        return reply == UInt8(ascii: "S") || reply == UInt8(ascii: "N")
    }
}
