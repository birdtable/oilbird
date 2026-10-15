import Foundation
import OilbirdModel

/// When the engine should stop, and who is keeping it alive.
///
/// Oilbird has two lifetimes and this domain governs the second:
///
/// - **The app** — the window, the MCP server, a CLI command. A few MB. It
///   lives as long as the user wants it, and MCP is reachable throughout.
/// - **The engine** — four JVMs and postgres, ~1.6 GB measured. Started on
///   demand, stopped when nothing has needed it for the chosen interval.
///
/// Zero idle cost is about the 1.6 GB and always was: the figure that motivated it
/// was a running SonarQube. Pausing the engine is not closing the app, and
/// the app says so rather than looking broken.
public enum Idle {
    // MARK: - Attachment

    /// Who is using the engine right now.
    ///
    /// One file and a shared lock, not a directory of `<pid>.attached` files.
    /// A PID-keyed scheme has to ask "is that process still alive?", which
    /// `Owner` already shows is harder than it looks — its own docstring
    /// warns that PIDs are recycled, and then compares by PID anyway. `flock`
    /// carries no PID: the kernel releases the lock when the last descriptor
    /// closes, including when the holder is `SIGKILL`ed, so there is no
    /// staleness to detect and nothing to get wrong.
    ///
    /// It also conflicts correctly *within* one process, which is the failure
    /// that forced `Owner` to carry two mechanisms. `flock` needs one.
    /// A class rather than a `~Copyable` struct: the attachment has to be
    /// held across `await`s and captured by escaping closures, which
    /// non-copyable types cannot be. Its lifetime is the holder's, released
    /// by ARC — hold it in a local and keep it alive to the end of the scope
    /// with `withExtendedLifetime`, since a `let` alone may be released at
    /// its last use rather than at the closing brace.
    public final class Attachment: @unchecked Sendable {
        private let descriptor: Int32

        /// Takes a shared lock and holds it until this value is destroyed.
        public init?(reason: String) {
            try? FileManager.default.createDirectory(
                at: Paths.State.run, withIntermediateDirectories: true)
            // ⚠ O_CLOEXEC is not optional: `flock` lives on the open-file
            // description, so a descriptor a child inherits holds the same
            // lock, and the engine would attach itself and never stop.
            let fd = open(Idle.attachmentPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard fd >= 0, flock(fd, LOCK_SH) == 0 else {
                if fd >= 0 { close(fd) }
                return nil
            }
            descriptor = fd
            Idle.countTaken()
            Log.debug("attached to the engine: \(reason)")
        }

        deinit {
            // `close`, never `LOCK_UN`: unlocking releases the lock on the
            // description, which any inherited copy shares. Closing releases
            // only this reference.
            close(descriptor)
            Idle.countReleased()
        }
    }

    /// How many attachments **this process** has ever taken, and how many
    /// it holds now.
    ///
    /// ⚠ In-process only, and the name of the type says so because the
    /// first caller forgot. `oilbird down` printed "in use by 0 task(s) —
    /// not stopped", which is two facts that contradict each other: the
    /// refusal came from the cross-process `flock`, the count came from
    /// this counter, and the scan holding the lock was in a different
    /// process. Use `Idle.attached()` to ask whether anything anywhere is
    /// using the engine; use this only to describe what this process is
    /// doing.
    ///
    /// Diagnostics, and the only deterministic way to assert "that operation
    /// held the engine open": the lock is released so quickly on a failing
    /// call that sampling it from another task is a race, and a flaky test
    /// for a safety property is worse than none. It also answers the
    /// question `status` needs to answer for a person — *what is keeping
    /// this alive?* — which diagnosability and no dead ends both want.
    public struct AttachmentStats: Sendable, Equatable {
        public let everTaken: Int
        public let heldNow: Int
    }

    nonisolated(unsafe) private static var everTaken = 0
    nonisolated(unsafe) private static var heldNow = 0
    private static let counters = NSLock()

    public static func attachmentStats() -> AttachmentStats {
        counters.lock()
        defer { counters.unlock() }
        return AttachmentStats(everTaken: everTaken, heldNow: heldNow)
    }

    fileprivate static func countTaken() {
        counters.lock()
        defer { counters.unlock() }
        everTaken += 1
        heldNow += 1
    }

    fileprivate static func countReleased() {
        counters.lock()
        defer { counters.unlock() }
        heldNow -= 1
    }

    static var attachmentPath: String {
        Paths.State.run.appending(path: "attached.lock").path
    }

    /// Is anything using the engine?
    ///
    /// Answered by trying to take the lock exclusively: if a shared holder
    /// exists the attempt fails, and it fails without blocking. The exclusive
    /// lock is released immediately — this only asks the question.
    /// `stoppingExclusively` is what asks it and acts on the answer atomically.
    public static func attached() -> Bool {
        let fd = open(attachmentPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    /// Runs `stop` only if nothing is attached, holding the attachment set
    /// locked throughout.
    ///
    /// This is the whole of the race. A client attaching between "nothing is
    /// attached" and "stop the engine" would otherwise find its services
    /// pulled out from under it mid-call; here it blocks on the shared lock
    /// until the stop completes, then correctly observes a stopped engine and
    /// starts a fresh one. Closed in the kernel rather than in our code.
    ///
    /// Returns whether the stop ran.
    public static func stopIfUnattached(_ stop: () async -> Void) async -> Bool {
        let fd = open(attachmentPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        await stop()
        return true
    }

    // MARK: - Policy

    /// The decision, with everything it depends on passed in.
    ///
    /// Pure and synchronous so the whole policy is testable in microseconds
    /// against a fake clock, rather than by waiting thirty minutes.
    public enum Verdict: Sendable, Equatable {
        /// Nothing to supervise — the engine is gone. The watchdog exits.
        case engineGone
        /// Something is using it. The idle mark resets.
        case inUse
        /// Idle, but not for long enough yet.
        case waiting
        /// Stop the engine.
        case stop
    }

    /// - Parameters:
    ///   - limit: `nil` means "never" — the user's explicit choice to keep
    ///     the engine warm. Honoured literally: nothing is ever stopped.
    ///   - idleFor: how long nothing has been attached. Continuous time, so
    ///     that sleep counts. A laptop used twenty minutes a day and asleep
    ///     the rest would otherwise never reach the threshold, and would pay
    ///     the full 1.6 GB on every wake — a worse citizen than the
    ///     terminal workflow it replaces.
    /// Watches until the engine stops, then returns.
    ///
    /// Everything it depends on is injected, so the whole loop runs against a
    /// fake clock in a test and against the real one in production without a
    /// second code path. It is a loop rather than a scheduled timer because
    /// timers do not fire while the machine sleeps and are coalesced on wake:
    /// **the poll is a prod, the clock is the truth**. Every tick recomputes
    /// elapsed time from the clock rather than accumulating, so a missed tick
    /// costs latency and never correctness.
    ///
    /// - Parameters:
    ///   - engineRunning: whether there is still anything to supervise. When
    ///     this goes false the watchdog exits — a supervisor with nothing to
    ///     supervise is itself the idle cost this exists to remove.
    ///   - stop: injected, because stopping the engine belongs to the barrel.
    ///     This domain deliberately cannot reach `Supervise` or `Cluster`.
    public static func watch<C: Clock>(
        limit: Duration?,
        poll: Duration,
        clock: C = ContinuousClock(),
        engineRunning: @Sendable () -> Bool,
        stop: @Sendable () async -> Void
    ) async where C.Duration == Duration {
        var idleSince = clock.now
        while true {
            let verdict = verdict(
                engineRunning: engineRunning(), attached: attached(), limit: limit,
                idleFor: idleSince.duration(to: clock.now))
            switch verdict {
            case .engineGone:
                Log.info("the engine is gone; the watchdog is done")
                return
            case .inUse:
                idleSince = clock.now
            case .waiting:
                break
            case .stop:
                Log.phase("stopping the idle engine")
                let ran = await stopIfUnattached(stop)
                // A client attached in the instant before the lock was taken.
                // Not a failure — the reason the check and the stop are one
                // step — so reset and carry on.
                if !ran { idleSince = clock.now }
            }
            try? await clock.sleep(for: poll)
            // Cancellation ends the watch: `try?` above swallows the error, so
            // without this the loop spins on a cancelled task and a bounded
            // test hangs rather than failing.
            if Task.isCancelled { return }
        }
    }

    public static func verdict(
        engineRunning: Bool, attached isAttached: Bool, limit: Duration?, idleFor: Duration
    ) -> Verdict {
        guard engineRunning else { return .engineGone }
        if isAttached { return .inUse }
        guard let limit else { return .waiting }
        return idleFor >= limit ? .stop : .waiting
    }
}
