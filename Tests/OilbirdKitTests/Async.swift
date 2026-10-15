import Foundation

/// The suites are synchronous by design — the harness is a plain executable.
/// This pumps one async call to completion.
///
/// `@unchecked Sendable` is legitimate here and nowhere else: the value is
/// written once inside the task and read once after `group.wait()`, with an
/// `NSLock` covering the hand-off. It is not a blanket silencer on a type we
/// own, which is what that annotation must never be.
final class Box<T>: @unchecked Sendable {
    private let gate = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) {
        gate.lock()
        defer { gate.unlock() }
        value = newValue
    }
    func get() -> T {
        gate.lock()
        defer { gate.unlock() }
        return value
    }
}

struct NeverRan: Error {}

func runSync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = Box<Result<T, Error>>(.failure(NeverRan()))
    let group = DispatchGroup()
    group.enter()
    Task {
        do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
        group.leave()
    }
    group.wait()
    return box.get()
}

struct TimedOut: Error {}

/// `runSync` with a deadline.
///
/// A test that waits on something which never finishes should go red, not
/// hang: a hanging suite reports nothing at all, and on CI it reports it
/// slowly. Faulting the watchdog's exit condition is what found this — the
/// unbounded version stopped the whole run instead of failing one test.
///
/// The task is cancelled on timeout, so anything that respects cancellation
/// stops rather than being orphaned in the test process.
func runSync<T: Sendable>(
    within seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T
) -> Result<T, Error> {
    let box = Box<Result<T, Error>>(.failure(TimedOut()))
    let group = DispatchGroup()
    group.enter()
    let task = Task {
        do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
        group.leave()
    }
    if group.wait(timeout: .now() + seconds) == .timedOut {
        task.cancel()
        return .failure(TimedOut())
    }
    return box.get()
}
