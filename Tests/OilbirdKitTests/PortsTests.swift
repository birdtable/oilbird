import Foundation
import OilbirdCore

func portsTests() {
    Harness.suite("Ports — assigned by the OS, never chosen") {
        Harness.test("a free port is a real, usable port number") {
            guard let port = try? Ports.free() else {
                Harness.expectTrue(false, "could not get a port")
                return
            }
            Harness.expectTrue(port > 1024, "got a privileged port: \(port)")
        }

        // Two services handed the same port is the collision this exists to
        // prevent, so it must not merely be unlikely.
        Harness.test("several ports at once are distinct") {
            guard let ports = try? Ports.free(4) else {
                Harness.expectTrue(false, "could not get four ports")
                return
            }
            Harness.expectEqual(ports.count, 4)
            Harness.expectEqual(Set(ports).count, 4, "duplicates: \(ports)")
        }

        // The whole point: a listener on a port we used before must not affect
        // the next assignment. This is the decoy-port fault, inverted.
        Harness.test("an occupied port is simply never handed out again") {
            guard let taken = try? Ports.free() else { return }
            let decoy = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(decoy) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = taken.bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(decoy, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            listen(decoy, 1)
            var collided = false
            for _ in 0..<20 where (try? Ports.free()) == taken { collided = true }
            Harness.expectTrue(!collided, "the OS handed back an occupied port")
        }

        // ⚠ An OS-assigned port designs out "port in use" and means a
        // restart never lands where it was, while a running scanner has
        // `sonar.host.url` fixed in its command line.
        Harness.test("a remembered port is preferred when it is still free") {
            guard let first = try? Ports.free() else {
                Harness.expectTrue(false, "could not take a port at all")
                return
            }
            guard let again = try? Ports.preferring(first) else {
                Harness.expectTrue(false, "preferring threw")
                return
            }
            Harness.expectEqual(again, first, "a free remembered port was not reused")
        }

        // And the property `Ports` exists to guarantee is deferred to, never
        // weakened: an occupied port yields, it does not fail.
        Harness.test("an occupied port yields to a fresh one rather than failing") {
            guard let taken = try? Ports.free() else {
                Harness.expectTrue(false, "could not take a port")
                return
            }
            // Hold it for real, so the check is against the kernel.
            let holder = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(holder) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = taken.bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            Harness.expectEqual(bound, 0, "could not occupy the port for the test")
            Harness.expectTrue(!Ports.isFree(taken), "an occupied port reported free")
            guard let fresh = try? Ports.preferring(taken) else {
                Harness.expectTrue(false, "preferring an occupied port threw instead of yielding")
                return
            }
            Harness.expectTrue(fresh != taken, "it handed back a port something else holds")
        }

        Harness.test("no remembered port is simply a fresh one") {
            Harness.expectTrue(
                (try? Ports.preferring(nil)) != nil, "a first start could not take a port")
            Harness.expectTrue(
                (try? Ports.preferring(0)) != nil, "a zero remembered port was not ignored")
        }
    }
}
