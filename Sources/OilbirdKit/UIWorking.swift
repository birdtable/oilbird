import Darwin
import Foundation
import OilbirdCore
import OilbirdModel

/// What a command shows while it is working and printing nothing.
///
/// ⚠ This file exists because the rule it appears to break is narrower than
/// it looks. Oilbird's design rules forbid the spinner-as-decoration, and
/// still keep one, for one reason: it is for the slow steps that print
/// nothing while they work, and a tool that looks hung gets killed.
///
/// So the rule is about WHERE, not whether:
///
/// · A spinner is for a step that prints nothing while it works. Where there
///   is output — a scan streaming, a download reporting bytes, `doctor`'s
///   rows arriving — the output IS the progress and a spinner on top is
///   noise.
/// · It is INDETERMINATE. Charm took `MiniDot`'s frames specifically over
///   `Meter`, because `▰▰▱` implies a bar filling and this cannot measure
///   anything. Do not imply progress you do not have.
/// · It is silent unless the stream is a terminal with colour. In CI a
///   carriage-returned animation arrives as thousands of lines.
/// · The stop function is then a no-op and is safe to call either way, so
///   every call site assigns a stop unconditionally and no call site needs a
///   nil check.
///
/// Where it is used in Oilbird: the search index during `up` (about 25
/// seconds in which SonarQube says nothing useful), each dependency's check
/// during `doctor` (7.45 seconds of total silence, measured), stopping the
/// engine, and the compute engine's turn after a scan has uploaded — by which
/// point the scanner has stopped printing. Nowhere else.
extension UI {
    /// Start an animation for a step that prints nothing, and return the
    /// function that stops it.
    ///
    /// Never nil, and a no-op when nothing was started.
    public func working(_ label: String) -> @Sendable () -> Void {
        guard rich else { return Working.noStop }
        let animation = Working(label: label, measure: measure)
        animation.start()
        return { animation.stop() }
    }

    /// One animation slot: starting a second stops the first.
    ///
    /// ⚠ It exists because the natural shape — a `var stop` reassigned from
    /// inside a callback — is not expressible under strict concurrency: the
    /// callback is `@Sendable` and cannot capture a mutable local. A lock and
    /// a class is the honest version of what that `var` was pretending to be,
    /// and it also makes "stop whatever is running" callable from the signal
    /// path without a second copy of the reasoning.
    public final class Slot: @unchecked Sendable {
        private let ui: UI
        private let lock = NSLock()
        private var stopCurrent: (@Sendable () -> Void)?

        public init(_ ui: UI) {
            self.ui = ui
        }

        /// Animate a step that prints nothing, replacing anything already
        /// animating.
        public func working(_ label: String) {
            clear()
            let stop = ui.working(label)
            lock.lock()
            stopCurrent = stop
            lock.unlock()
        }

        /// Stop and wipe. Safe to call any number of times, including when
        /// nothing ever started — which is what lets a call site clear the
        /// slot before every row without asking whether there is a row.
        public func clear() {
            lock.lock()
            let stop = stopCurrent
            stopCurrent = nil
            lock.unlock()
            stop?()
        }
    }

    /// The animation itself.
    ///
    /// A class with a lock rather than an actor: `stop()` has to BLOCK until
    /// the line has been wiped, and it is called from ordinary synchronous
    /// code between two `print`s. The obvious alternative — close a channel
    /// and sleep 150ms hoping the writer has got there — is a race with a
    /// magic number in it, and on a slow machine the next line of output
    /// lands in a half-erased frame.
    public final class Working: @unchecked Sendable {
        /// Charm's `MiniDot`, the smallest spinner `bubbles` ships. One cell,
        /// one glyph, no colour cycle, and nothing about it suggests a
        /// proportion.
        static let frames = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]

        /// Slower than an animation meant to be watched. This one is meant to
        /// be believed and then ignored, and a fast spinner beside static
        /// text pulls the eye back every time.
        static let interval = Duration.milliseconds(100)

        /// The stop for "nothing was animated".
        ///
        /// Named rather than written out at five call sites, which is also
        /// what keeps those call sites free of a nil check.
        public static let noStop: @Sendable () -> Void = {}

        private let label: String
        private let measure: Int
        private let lock = NSLock()
        private var stopped = false
        private var frame = 0
        private var timer: DispatchSourceTimer?
        private var signals: [DispatchSourceSignal] = []
        private var previousDispositions: [(Int32, sig_t?)] = []
        private let wiped = DispatchSemaphore(value: 0)
        private let queue = DispatchQueue(label: "com.birdtable.oilbird.ui.working")

        init(label: String, measure: Int) {
            self.label = label
            self.measure = measure
        }

        func start() {
            // Hidden before the first frame and restored by `stop` and by the
            // signal handler both. A cursor left hidden is the "left my
            // terminal in a state" failure this whole file exists to avoid.
            write("\u{1B}[?25l")
            arm(SIGINT)
            arm(SIGTERM)
            let ticker = DispatchSource.makeTimerSource(queue: queue)
            ticker.schedule(deadline: .now(), repeating: .milliseconds(100))
            ticker.setEventHandler { [weak self] in self?.paint() }
            timer = ticker
            ticker.resume()
        }

        /// Wipe the line, restore the cursor, and return only once that has
        /// actually happened. Idempotent.
        func stop() {
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            stopped = true
            let ticker = timer
            timer = nil
            lock.unlock()

            ticker?.cancel()
            // ⚠ `\r` alone leaves the tail of a longer frame on screen. The
            // pair is the erase: return to column zero, then clear the line.
            write("\r\u{1B}[2K\u{1B}[?25h")
            disarm()
            wiped.signal()
        }

        private func paint() {
            lock.lock()
            let go = !stopped
            let index = frame
            frame += 1
            lock.unlock()
            guard go else { return }

            var line = Self.frames[index % Self.frames.count] + " " + label
            // ⚠ Truncated to the terminal. The erase clears one row, so a frame
            // that WRAPS leaves its first row on screen and every repaint leaves
            // another: an animation becomes a column of identical lines.
            if measure > 2, UI.width(line) > measure - 1 {
                line = truncate(line, to: measure - 1)
            }
            write("\r\u{1B}[2K\u{1B}[90m" + line + "\u{1B}[0m")
        }

        private func truncate(_ text: String, to cells: Int) -> String {
            var out = ""
            var used = 0
            for character in text {
                let next = UI.width(String(character))
                if used + next > cells - 1 { return out + "…" }
                out.append(character)
                used += next
            }
            return out
        }

        /// The frames go to STDERR, because that is where this CLI's human
        /// output goes — stdout belongs to `--json`. An animation on the other
        /// stream would erase a line it is not sharing.
        private func write(_ text: String) {
            FileHandle.standardError.write(Data(text.utf8))
        }

        /// ⚠ Ctrl-C must still kill the process, and must not leave a hidden
        /// cursor behind it.
        ///
        /// The signal is ignored so its default action cannot terminate us
        /// before the line is wiped, a dispatch source takes delivery, and
        /// then the disposition is put back and the signal RE-RAISED — so the
        /// process dies of what it was sent, with the status a shell expects,
        /// rather than exiting 0 from a handler that only tidied the cursor
        /// up.
        private func arm(_ number: Int32) {
            previousDispositions.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.stop()
                signal(number, SIG_DFL)
                kill(getpid(), number)
            }
            signals.append(source)
            source.resume()
        }

        private func disarm() {
            for source in signals { source.cancel() }
            signals = []
            for (number, previous) in previousDispositions {
                signal(number, previous ?? SIG_DFL)
            }
            previousDispositions = []
        }
    }
}

/// The phases of a start, and the rows they leave behind.
///
/// ⚠ In Kit and not beside its one call site, for the reason the `targets` check
/// states: an executable target cannot be `@testable import`-ed, so this was
/// untestable where it lived — and it carried a defect that only a test would
/// have caught, reporting `done … 0s` for a twenty-five second wait.
extension UI {
    /// The phases of a start, turned into one `done` row each as they close.
    ///
    /// ⚠ Phases arrive as "now starting X", so the row that can be printed is
    /// always for the phase BEFORE the one just announced. Keeping the elapsed
    /// figure is deliberate: a slow start is the thing people file bugs about and
    /// the numbers are the evidence.
    ///
    /// ⚠ `waitingForServer` repeats — SonarQube is polled while it comes up, and
    /// its status string changes — so an equality test alone would print a `done`
    /// row every poll. Two of them in a row close nothing.
    public final class Phases: @unchecked Sendable {
        private let ui: UI
        public init(_ ui: UI) { self.ui = ui }

        private let lock = NSLock()
        private var current: (phase: Oilbird.Phase, began: Date)?

        /// The row for the phase this one replaces, or nil when it replaces
        /// nothing.
        /// ⚠ **A twenty-five second wait printed `done … 0s`.** Both the row and
        /// the clock key off the LABEL rather than the case, because
        /// `waitingForServer` carries SonarQube's own status string: equality on
        /// the case was false every time that string changed, so the elapsed
        /// clock restarted mid-phase and the row reported the time since the
        /// last word SonarQube happened to say. The label is what the reader
        /// sees, and a phase is over exactly when that changes.
        public func advance(to phase: Oilbird.Phase) -> String? {
            lock.lock()
            defer {
                current =
                    (phase, current.map { $0.phase.label == phase.label ? $0.began : Date() } ?? Date())
                lock.unlock()
            }
            guard let previous = current, previous.phase.label != phase.label else { return nil }
            return ui.statusRow(
                "done", .good, previous.phase.label,
                Oilbird.humanDuration(Date().timeIntervalSince(previous.began)))
        }

        /// One `done` row per dependency as its download completes.
        ///
        /// ⚠ The progress callback fires per CHUNK — hundreds of times for 947 MB
        /// — and the old rendering printed a percentage line for every one of
        /// them. One line per dependency, at the moment it finishes, is what
        /// survives a pipe: a CI log gets four lines rather than four thousand.
        public final class Downloads: @unchecked Sendable {
            private let ui: UI
            public init(_ ui: UI) { self.ui = ui }

            private let lock = NSLock()
            private var done: Set<String> = []

            public func progress(_ id: DependencyID, done bytes: Int64, of total: Int64) -> String? {
                guard bytes >= total else { return nil }
                lock.lock()
                let first = done.insert(id.rawValue).inserted
                lock.unlock()
                guard first else { return nil }
                return ui.statusRow(
                    "done", .good, id.rawValue,
                    "\(Oilbird.humanBytes(total))   sha256 verified, unpacked")
            }
        }

        /// The row for the last phase, once the start has finished.
        public func close() -> String? {
            lock.lock()
            defer {
                current = nil
                lock.unlock()
            }
            guard let previous = current else { return nil }
            return ui.statusRow(
                "done", .good, previous.phase.label,
                Oilbird.humanDuration(Date().timeIntervalSince(previous.began)))
        }
    }
}
