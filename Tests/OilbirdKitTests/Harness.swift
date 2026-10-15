import Foundation

/// A hand-rolled test harness.
///
/// `swift test` cannot run on a Mac with only the Command Line Tools — neither
/// `XCTest` nor `Testing` is importable there, and they are the whole
/// toolchain. The suites are an executable target
/// instead. Names mirror XCTest's so the suites port almost mechanically if
/// this is ever built somewhere with Xcode.
///
/// Single-threaded by construction: `main.swift` calls each suite in turn, so
/// the counters below are externally synchronised and need no lock.
enum Harness {
    nonisolated(unsafe) private static var assertions = 0
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var context = "(no suite)"

    static func suite(_ name: String, _ body: () -> Void) {
        print("\n\(name)")
        body()
    }

    /// A test that asserts nothing fails.
    ///
    /// Without this a body whose assertions all sit inside a loop over an
    /// empty collection prints a tick having checked nothing — which is worse
    /// than no test, because it reports coverage that does not exist.
    static func test(_ claim: String, _ body: () -> Void) {
        context = claim
        let before = assertions
        body()
        if assertions == before {
            fail("asserted nothing")
            print("  ✗ \(claim) — asserted nothing")
        } else {
            print("  ✓ \(claim)")
        }
    }

    static func expectTrue(_ value: Bool, _ what: String = "") {
        assertions += 1
        if !value { fail("expected true \(what)") }
    }

    static func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ what: String = "") {
        assertions += 1
        if lhs != rhs { fail("expected \(rhs), got \(lhs) \(what)") }
    }

    static func expectNotEmpty(_ value: String, _ what: String = "") {
        assertions += 1
        if value.isEmpty { fail("expected a non-empty string \(what)") }
    }

    static func expectNil<T>(_ value: T?, _ what: String = "") {
        assertions += 1
        if value != nil { fail("expected nil \(what)") }
    }

    private static func fail(_ message: String) {
        failures.append("\(context): \(message)")
    }

    /// Exits non-zero on any failure, and always reports the count — a run
    /// that failed nothing because it asserted nothing is not a pass.
    static func finish() -> Never {
        print("\n\(assertions) assertions, \(failures.count) failed")
        for failure in failures { print("  ✗ \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Deliberately break the harness, to prove it can fail (`E5`).
    static func selfTest() {
        let before = failures.count
        context = "harness self-test"
        expectEqual(1, 2, "(deliberate)")
        guard failures.count == before + 1 else {
            print("HARNESS SELF-TEST FAILED: a wrong assertion did not register")
            exit(2)
        }
        failures.removeLast()
        assertions -= 1
        print("harness — proven able to fail")
    }
}

/// Waits for a condition, up to a deadline. Returns whether it came true.
///
/// The idle tests are the first that genuinely need it, because they wait on
/// another process rather than on a value.
///
/// It returns a Bool rather than asserting, so the caller says what the
/// failure means — "the watchdog never stopped the engine" is a finding,
/// "settle timed out" is not. And it polls rather than sleeping a fixed
/// interval, so a fast machine does not pay the worst case.
func settle(within seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(50_000)
    }
    return condition()
}
