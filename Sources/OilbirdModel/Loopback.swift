import Foundation

/// Where the engine listens, given a port.
///
/// ⚠ One home for what was six copies of
/// `URL(string: "http://127.0.0.1:\(port)")!`, in `Supervise`, `Scan`, the
/// barrel, the window, the menu bar and the fixture server. Six copies of one
/// force unwrap is six places to be wrong about the same thing, and a seventh
/// was one paste away.
public enum Loopback {
    /// `http://127.0.0.1:<port>`.
    ///
    /// ⚠ The address and never the name. `localhost` goes through the
    /// resolver, can answer `::1` first, and blocks on a machine with a
    /// captive or slow DNS. The engine binds 127.0.0.1.
    public static func url(port: UInt16) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        // ⚠ Traps, and no construction does not: Foundation has no
        // non-failable `URL`. A fallback would mean talking to somewhere
        // other than the engine while looking like it worked.
        guard let url = components.url else {
            preconditionFailure("loopback: http://127.0.0.1:\(port) did not compose into a URL")
        }
        return url
    }
}
