import Foundation

/// What each engine state is called, and what may be done from it.
///
/// ⚠ Here rather than in the app, and not for tidiness. Four surfaces answer
/// these questions — the window's pill, the pill's menu, the menu bar item and
/// the Engine menu — and each wrote its own `switch`. They disagreed: the
/// Engine menu offered Resume while the engine was running and Pause while it
/// was paused, while the pill's menu got both right. Two answers to one
/// question is one answer too many.
///
/// The second reason is that an executable target cannot be `@testable
/// import`-ed (SwiftPM #7596), so a vocabulary written in `Sources/OilbirdApp`
/// is untestable by construction. The words and the rules live here where a
/// test can reach them; the colours stay in the app, where the palette is.
extension Oilbird {
    /// How a state should read — never which colour to paint it. Kit does not
    /// know the palette and must not: `Theme` is the app's.
    public enum Tone: Sendable, Equatable {
        /// Up and answering.
        case good
        /// Something is moving. Nothing to do but wait.
        case working
        /// At rest, or wedged. Neither is an alarm on its own.
        case quiet
    }
}

extension Oilbird.EngineState {
    /// The one word the pill shows.
    ///
    /// Lower case throughout, because it sits inside a pill and is read as a
    /// state rather than as a sentence.
    public var word: String {
        switch self {
        case .running: "running"
        case .paused: "paused"
        case .starting: "starting"
        case .notInstalled: "not set up"
        case .unresponsive: "not answering"
        }
    }

    /// The heading the menu bar item shows, where there is room for a
    /// sentence.
    ///
    /// ⚠ Paused says only that it is paused. It used to say "Paused —
    /// nothing has needed it", which is false for the commonest way of
    /// getting here: the user pressing Pause a second earlier. The lock the
    /// state is derived from carries no reason across processes, so no
    /// surface can honestly name one.
    public var heading: String {
        switch self {
        case .running: "Running"
        case .paused: "Paused"
        case .starting: "Starting…"
        case .notInstalled: "Not set up yet"
        case .unresponsive: "Not answering — restart it"
        }
    }

    /// The symbol that carries this state alongside the word.
    ///
    /// ⚠ Two channels for one fact, the same rule the terminal keeps by
    /// carrying severity in CASE as well as colour: a menu is scanned, not
    /// read, and a shape is what the eye finds before a word.
    ///
    /// ⚠ And every item in that menu has one, which is the other half of
    /// why this exists. macOS puts a gear on `Settings…` whether we ask or
    /// not, and one item with an icon indents its whole group — so a menu
    /// where only that item has one has three different left edges, which
    /// is what it had.
    public var symbol: String {
        switch self {
        case .running: "circle.fill"
        case .paused: "pause.circle.fill"
        case .starting: "arrow.triangle.2.circlepath"
        case .notInstalled: "arrow.down.circle"
        case .unresponsive: "exclamationmark.triangle.fill"
        }
    }

    /// The symbol for the one action that changes this state.
    public var resumeSymbol: String {
        switch self {
        case .running, .starting: "play.fill"
        case .paused: "play.fill"
        case .notInstalled: "arrow.down.circle"
        case .unresponsive: "arrow.clockwise"
        }
    }

    public var tone: Oilbird.Tone {
        switch self {
        case .running: .good
        case .starting: .working
        case .paused, .notInstalled, .unresponsive: .quiet
        }
    }

    /// Whether stopping the engine is a thing that can be done from here.
    ///
    /// Only from `.running`. A wedged engine is restarted rather than paused
    /// — pausing it would leave the same wedge behind under a calmer word.
    public var canPause: Bool {
        if case .running = self { return true }
        return false
    }

    /// Whether there is a way forward that ends with the engine up.
    ///
    /// True for every state that is not already running or already on its
    /// way: a paused engine resumes, a wedged one restarts, and a machine
    /// with nothing installed sets up. `resumeLabel` says which.
    public var canResume: Bool {
        switch self {
        case .running, .starting: false
        case .paused, .notInstalled, .unresponsive: true
        }
    }

    /// What that way forward is called, so the control does what it says.
    ///
    /// Nil when there is none, which is what `canResume` reports as false.
    public var resumeLabel: String? {
        switch self {
        case .running, .starting: nil
        case .paused: "Resume"
        case .notInstalled: "Set up Oilbird…"
        case .unresponsive: "Restart"
        }
    }
}
