import CoreServices
import Foundation
import OilbirdCore

/// What is left of Oilbird when it is closed, who may end the process, and
/// how a person gets back in or out from there.
///
/// ⚠ **Two simpler models were considered and rejected. Read why before
/// changing this one.**
///
/// 1. Closing the last window quits outright. A fresh install then has no
///    menu bar item to go back to; closing should leave it in the menu bar,
///    from where it can be ended fully.
/// 2. ⌘Q rebound to "Close to Menu Bar", with Quit on ⌥⌘Q. That is the same
///    problem as a naming one — quit app versus close window — with a phrase
///    nobody reads on the ordinary act and the word Quit on a key that no
///    longer does it.
///
/// The model here: **closing is the ordinary act and it happens from
/// everywhere — ⌘Q, the Dock's Quit, the red button — and exactly one item
/// ends the process, with the word Completely in its name.** The menu bar
/// item reads Close Oilbird, a separator, then Quit Oilbird Completely.
///
/// What (2) gets wrong is never the interception; it is naming. Here the ⌘Q
/// item is labelled with what it actually does — `closeTitle` — and the item
/// that terminates says so in three words. A name is not allowed to disagree
/// with its key.
///
/// `stayResident` is the escape hatch and it is load-bearing. With it off
/// nothing is intercepted, ⌘Q and the Dock's Quit end the process, and the
/// "Completely" item is absent rather than a second way to say the same
/// thing. A person who does not want a menu bar app must not be trapped in
/// one.
///
/// ⚠ Here rather than in `AppDelegate`, because "no dead ends" turns on it
/// and an executable target cannot be `@testable import`-ed (SwiftPM #7596). The
/// question "can these two switches, together, leave somebody with no
/// window, no way back and no way out?" is exactly the sort that gets
/// answered confidently and wrongly by reading the code — and now that an
/// ordinary Quit can be refused, the second half of it is no longer free.
extension Oilbird {
    public struct Residency: Sendable, Equatable {
        /// Whether closing the last window ends the app.
        public let closingLastWindowQuits: Bool

        /// Whether the bird is in the menu bar while no window is open.
        public let menuBarIcon: Bool

        /// Whether the Dock tile is still there once the last window has
        /// closed.
        ///
        /// ⚠ **Derived, not `true` unconditionally:** an `.accessory`
        /// policy would make an unconditional answer quietly false, so the
        /// assertions that rest on it are derived rather than asserted.
        ///
        /// Closing to the menu bar means closing to the MENU BAR: an app
        /// that leaves a Dock tile behind has not gone anywhere, it has
        /// just lost its window. So the tile goes when there is a menu bar
        /// icon to go to — and stays when there is not, because then it is
        /// the only way back in and the only way out, and dropping it would
        /// strand somebody with a running app they cannot see or end.
        ///
        /// That is also what keeps `hasAWayBack` and `hasAWayOut` true by
        /// construction rather than by luck: exactly one of these two marks
        /// is always present.
        public var dockIcon: Bool { !menuBarIcon }

        /// Whether an ordinary Quit closes Oilbird instead of ending it.
        ///
        /// One flag for every surface that can ask: ⌘Q, the Dock's Quit and
        /// the red close button are the same intention arriving three ways,
        /// and the defect was two of them disagreeing.
        public var quitCloses: Bool { !closingLastWindowQuits }

        /// The title of whatever is on ⌘Q, which must say what ⌘Q does.
        public var closeTitle: String { quitCloses ? "Close Oilbird" : "Quit Oilbird" }

        /// The one item that ends the process — nil when ⌘Q already does,
        /// because two items with one meaning is exactly the fault of
        /// model (2) above.
        public var terminateTitle: String? { quitCloses ? "Quit Oilbird Completely" : nil }

        /// No dead ends: from a state with no window open there is always a
        /// way back in.
        public var hasAWayBack: Bool { closingLastWindowQuits || menuBarIcon || dockIcon }

        /// No dead ends, the direction that used to be free: there is always a
        /// way OUT, too.
        ///
        /// It was free while the Dock's Quit quit. It is not any more, so it
        /// is asserted rather than assumed. The menu bar item carries the
        /// ending; with that icon off, the Dock icon activates the app and
        /// the app's own menu carries the same one — which is why
        /// `terminateTitle` is non-nil for every configuration that can
        /// refuse a quit, and why this rests on `dockIcon` as `hasAWayBack`
        /// does.
        public var hasAWayOut: Bool {
            !quitCloses || menuBarIcon || dockIcon
        }

        /// Whether the Dock is the ONLY thing left when the window closes —
        /// true, and worth saying, but not obvious to somebody who has just
        /// turned the menu bar icon off.
        public var onlyTheDock: Bool { !closingLastWindowQuits && !menuBarIcon }

        /// What the General pane says under those two switches.
        ///
        /// ⚠ A sentence, not a refusal. The combination is legitimate —
        /// somebody may genuinely want neither mark — and it is not a dead
        /// end, because the Dock is still there. What is owed is a way
        /// forward, not for the app to argue.
        ///
        /// ⚠ It named only the way back, and that stopped being enough the
        /// moment the Dock's Quit began closing rather than quitting: in
        /// this one combination the Dock menu is both the only thing a
        /// person will look in and the one place the ending is not. So the
        /// note now says where the ending is.
        public var note: String? {
            guard onlyTheDock else { return nil }
            return "With no menu bar icon, Oilbird keeps its Dock tile when its last "
                + "window closes — it is the only way back — and the Dock's Quit closes "
                + "it rather than ending it. Quit Oilbird Completely, in the Oilbird "
                + "menu, is what ends it."
        }

        /// What the row's own explanation says, which depends on which way
        /// it is set: half a sentence that is wrong in one position is
        /// wrong exactly where somebody about to change it is reading.
        ///
        /// ⚠ It depends on the menu bar icon as well, and it has to. With
        /// that icon switched off, a fixed sentence would say Oilbird closes
        /// "to the menu bar" — to a menu bar it is not in — and the note
        /// below it would have to contradict it. Two rows of one group
        /// disagreeing about where the app goes is the same fault this whole
        /// file exists to stop, in a smaller place.
        public var explanation: String {
            guard !closingLastWindowQuits else {
                return "The red button closes the window and Command-Q quits, as in any "
                    + "other app."
            }
            let closing =
                menuBarIcon
                ? "close Oilbird to the menu bar, leaving the Dock"
                : "close Oilbird, leaving it in the Dock"
            return "The red button, Command-Q and the Dock's Quit all \(closing). "
                + "Quit Oilbird Completely ends it."
        }
    }

    /// Residency as the preferences have it.
    public static func residency(_ stored: Settings = settings()) -> Residency {
        Residency(
            closingLastWindowQuits: !stored.stayResident, menuBarIcon: stored.menuBarIcon)
    }

    /// Who asked Oilbird to quit.
    ///
    /// ⚠ **This is the whole reason refusing a quit is safe.** The obvious
    /// objection is that refusing to terminate would also refuse a log-out,
    /// a restart and a Software Update installer, as if they all asked the
    /// same way a ⌘Q does. They do not. A quit that comes from logging out, restarting
    /// or shutting down arrives as a `kAEQuitApplication` Apple event
    /// carrying a `kAEQuitReason` attribute saying which; a person pressing
    /// Quit sends no reason, and pressing ⌘Q sends no Apple event at all.
    ///
    /// Rebinding the key instead cannot cover the Dock's Quit — that sends
    /// `terminate:` and there is no item of ours to rebind. Reading the
    /// reason is the only route to a Dock menu whose Quit closes.
    ///
    /// Verified in a VM rather than argued, in one run of one process: a
    /// Dock-shaped quit logged `by the user` and was refused, the app still
    /// running; ten seconds later a restart logged `by the system: restart`
    /// and was allowed, and the machine came back up with a new
    /// `kern.boottime`.
    public enum QuitRequest: Sendable, Equatable {
        /// A person pressed something. No reason came with it.
        case user

        /// The system is going down, and named why. The string is for the
        /// log; the only thing any caller may do with this case is get out
        /// of the way.
        case system(String)

        /// Whether Oilbird may decline this one.
        ///
        /// ⚠ Only `.user`, and every unrecognised reason code is `.system`
        /// rather than `.user`. Getting this backwards means a machine that
        /// will not restart, and the failure is silent until somebody tries
        /// — so the unknown case fails towards letting go.
        public var mayBeRefused: Bool { self == .user }
    }

    /// Reads the reason off the Apple event in flight, if there is one.
    ///
    /// Call it with `NSAppleEventManager.shared().currentAppleEvent` from
    /// inside `applicationShouldTerminate`, which is when that event is the
    /// quit request being handled.
    ///
    /// The event class is deliberately NOT checked. The dangerous mistake is
    /// reading a system quit as a user one — that is the hung restart — and
    /// a class check can only ever add ways to make it. A reason attribute
    /// on an event that is somehow not a quit would at worst let a ⌘Q
    /// through, which is what any app without this interception does.
    ///
    /// ⚠ It writes a line, and that is not decoration for a reader either.
    /// Every other consequence of this function is the absence of something
    /// — a window that did not close, a machine that did not go down — so
    /// without a record there is nothing to look at afterwards but a
    /// symptom. The log is how a "my Mac would not restart" report is
    /// answered in one grep instead of a reproduction.
    public static func quitRequest(_ event: NSAppleEventDescriptor?) -> QuitRequest {
        let request = read(event)
        switch request {
        case .user: Log.info("quit asked for by the user")
        case .system(let reason): Log.info("quit asked for by the system: \(reason)")
        }
        // The process is usually gone a moment later; the writer is a queue.
        Log.flush()
        return request
    }

    private static func read(_ event: NSAppleEventDescriptor?) -> QuitRequest {
        guard let event,
            let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return .user }
        // Sent as `typeEnumerated`; read both accessors because a descriptor
        // of the other type answers 0 to the one that does not fit it, and 0
        // would read as "no reason" — which is the case that gets refused.
        let code = reason.enumCodeValue != 0 ? reason.enumCodeValue : reason.typeCodeValue
        return .system(quitReasonNames[code] ?? "reason \(fourCharacters(code))")
    }

    /// The reasons loginwindow sends, from `AERegistry.h`. Both spellings of
    /// each: the "show dialog" variants arrive when the user is being asked
    /// to confirm, and by then the app has already been told to go.
    private static let quitReasonNames: [OSType: String] = [
        OSType(kAELogOut): "log out",
        OSType(kAEReallyLogOut): "log out",
        OSType(kAEShowRestartDialog): "restart",
        OSType(kAERestart): "restart",
        OSType(kAEShowShutdownDialog): "shut down",
        OSType(kAEShutDown): "shut down",
        OSType(kAEQuitAll): "quit all",
    ]

    /// An `OSType` as the four characters it is, so an unrecognised reason
    /// reaches the log as `boot` rather than as 1651470196 — the code is a
    /// four-character literal in Apple's headers and that is what anybody
    /// reading the log will grep for.
    private static func fourCharacters(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "\(code)" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
