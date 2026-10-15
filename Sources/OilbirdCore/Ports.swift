import Foundation

/// Ports are assigned by the operating system, never chosen.
///
/// This designs "port already in use" out of existence rather than handling
/// it. A pinned port collides with whatever else the developer runs — and it
/// matters more for SonarQube than PostgreSQL, because 9000 is a popular port
/// that php-fpm, MinIO and others take.
///
/// PostgreSQL will not accept `port = 0` itself, so the assignment happens
/// here: bind a throwaway socket to 0, read back what the OS chose, close it.
public enum Ports {
    /// A free loopback port.
    ///
    /// There is a window between closing this socket and the service binding
    /// it. That is handled by retrying with a fresh port, not by a dialog —
    /// `SO_REUSEADDR` is deliberately NOT set, so a genuinely occupied port
    /// fails here rather than surprising the service later.
    public static func free() throws -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw PortError.couldNotOpenSocket(errno) }
        defer { close(handle) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // let the OS choose
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw PortError.couldNotBind(errno) }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else { throw PortError.couldNotBind(errno) }
        return UInt16(bigEndian: assigned.sin_port)
    }

    /// Is this specific port free right now?
    ///
    /// Same bind, without asking the OS to choose. `SO_REUSEADDR` stays
    /// unset here too, so "free" means genuinely free rather than
    /// re-bindable over somebody's `TIME_WAIT`.
    public static func isFree(_ port: UInt16) -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    /// The port this service used last time, if it is still free.
    ///
    /// ⚠ Ports being assigned by the OS designs out "port in
    /// use", which is worth keeping — but it also means a restart never
    /// lands on the old port, and a scanner already running has
    /// `sonar.host.url` fixed in its command line. So a legitimate restart
    /// killed whatever was mid-scan, with
    /// `java.net.ConnectException: Failed to connect to /127.0.0.1:49241`
    /// after eighty-two seconds of analysis.
    ///
    /// Preferring the last port keeps a restart transparent in the common
    /// case. When something else has taken it, this falls back to a fresh
    /// one — which is exactly the old behaviour, so the property `Ports`
    /// exists to guarantee is never weakened, only deferred to.
    public static func preferring(_ remembered: UInt16?) throws -> UInt16 {
        if let remembered, remembered > 0, isFree(remembered) { return remembered }
        if remembered != nil { Log.info("the remembered port is taken; taking a fresh one") }
        return try free()
    }

    /// Several distinct free ports at once, so two services cannot be handed
    /// the same one.
    public static func free(_ count: Int) throws -> [UInt16] {
        var chosen: Set<UInt16> = []
        var attempts = 0
        while chosen.count < count {
            attempts += 1
            guard attempts < count * 20 else { throw PortError.exhausted }
            chosen.insert(try free())
        }
        return Array(chosen)
    }

    public enum PortError: Error, Sendable {
        case couldNotOpenSocket(Int32)
        case couldNotBind(Int32)
        case exhausted
    }
}
