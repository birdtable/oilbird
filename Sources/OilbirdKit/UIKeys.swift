import Darwin
import Foundation

/// Keys, read one at a time, for the one screen that has a selection.
///
/// ⚠ This is the narrowest possible version of a thing that usually grows
/// into a framework. It reads keys; it does not own a screen, a run loop or a
/// widget tree. The menu repaints itself with the same `menuScreen` a dumb
/// terminal gets, and the only difference between the two is which row
/// carries the marker.
///
/// ⚠ Raw mode is a global property of the terminal, not of this process, so
/// every exit from it has to restore — including the ones nobody writes down.
/// `restore()` is idempotent and is called on the way out of `menu`, before
/// every child process (which needs the terminal it was born with), and from
/// the signal path. A CLI that leaves a terminal in cbreak mode has broken the
/// shell the user goes back to, which is a worse defect than anything on the
/// screen it was painting.
extension UI {
    public enum Key: Sendable, Equatable {
        case up, down, enter, quit, digit(Character), letter(Character), eof
        /// ⚠ Named, every one of them. They were all `.other`, and a menu
        /// that cycled a filter on Escape and a browser that cycled a
        /// severity on `/` were the result: a screen cannot respond to a key
        /// it cannot tell from three others. `.other` is what is left over.
        case tab, escape, backspace, slash, other
    }

    public final class Keyboard: @unchecked Sendable {
        private let lock = NSLock()
        private var saved = termios()
        private var raised = false
        private var signals: [DispatchSourceSignal] = []
        private var previousDispositions: [(Int32, (@convention(c) (Int32) -> Void)?)] = []
        private let queue = DispatchQueue(label: "com.birdtable.oilbird.ui.keys")

        /// Nil when stdin is not a terminal, which is also the condition
        /// under which no menu is offered at all.
        public init?() {
            guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &saved) == 0 else {
                return nil
            }
        }

        deinit { restore() }

        /// Take the terminal out of line mode. Safe to call twice.
        public func raise() {
            guard !raised else { return }
            var raw = saved
            // ⚠ ECHO and ICANON only. Everything else — ISIG above all — is left
            // alone: turning off ISIG is what makes a program that cannot be
            // interrupted with Ctrl-C.
            raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
            withUnsafeMutableBytes(of: &raw.c_cc) { slots in
                slots[Int(VMIN)] = 1
                slots[Int(VTIME)] = 0
            }
            raised = tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0
            if raised {
                arm(SIGINT)
                arm(SIGTERM)
            }
        }

        /// Put it back the way it was found.
        public func restore() {
            guard raised else { return }
            raised = false
            tcsetattr(STDIN_FILENO, TCSANOW, &saved)
            disarm()
        }

        /// ⚠ Ctrl-C arrives while this is BLOCKED in `read`, which is where
        /// it spends nearly all of its life, and the default action would
        /// then kill the process with the terminal still in cbreak mode —
        /// leaving the shell the user goes back to with no echo and no line
        /// editing. That is a worse defect than anything on the screen this
        /// was painting.
        ///
        /// The same shape the animation uses: ignore so the default action
        /// cannot land first, take delivery on a source, put the terminal
        /// back, restore the disposition and RE-RAISE — so the process dies
        /// of what it was sent, with the status a shell expects.
        private func arm(_ number: Int32) {
            previousDispositions.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.restore()
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

        /// One key. Blocks until there is one.
        public func next() -> Key { Self.classify(read: { Self.readByte() }, waiting: Self.pending) }

        /// The classification, separated from the reading so a test can drive
        /// it with bytes rather than with a terminal.
        ///
        /// ⚠ An arrow arrives as three bytes and a bare Escape as one, and
        /// the only thing telling them apart is whether more bytes are
        /// already waiting. Read blindly, a bare Escape swallows the next
        /// keystroke as its own tail.
        public static func classify(
            read: () -> UInt8?, waiting: () -> Bool
        ) -> Key {
            guard let first = read() else { return .eof }
            switch first {
            case 0x0A, 0x0D: return .enter
            case 0x09: return .tab
            case 0x7F, 0x08: return .backspace
            case UInt8(ascii: "/"): return .slash
            case 0x1B:
                // Nothing waiting means the key WAS Escape. Read blindly, a
                // bare Escape swallows the next keystroke as its own tail.
                guard waiting(), read() == 0x5B, let final = read() else { return .escape }
                switch final {
                case 0x41: return .up
                case 0x42: return .down
                default: return .other
                }
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03, 0x04: return .quit
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return .digit(Character(UnicodeScalar(first)))
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
                return .letter(Character(UnicodeScalar(first)).lowercased().first ?? "?")
            default: return .other
            }
        }

        private static func readByte() -> UInt8? {
            var byte: UInt8 = 0
            return Darwin.read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
        }

        /// Whether another byte is already there, which is what separates an
        /// arrow key from a bare Escape.
        private static func pending() -> Bool {
            var poll = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            return Darwin.poll(&poll, 1, 20) > 0
        }
    }

    /// Move the cursor back over a screen just painted, so the next paint
    /// replaces it rather than scrolling it away.
    ///
    /// Silent without a terminal, where there is nothing to move.
    public func rewind(_ lines: Int) {
        guard rich, lines > 0 else { return }
        FileHandle.standardError.write(Data("\u{1B}[\(lines)A\u{1B}[0J".utf8))
    }
}
