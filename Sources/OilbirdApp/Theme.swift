import AppKit
import OilbirdKit

/// The design tokens, in one place.
///
/// A "paper" theme: warm paper, terracotta, ink.
///
/// ⚠ **Every colour was an absolute sRGB value and the app pinned itself to
/// `.aqua` so the controls would agree with them. That fixed one bug by
/// causing a worse one.** `window.appearance` applies to every view a window
/// owns — the `WKWebView` included — so pinning forced SonarQube's own
/// dashboard into its light theme and silently overrode the user's system
/// choice. In dark mode the product was a light SonarQube in a cream frame,
/// having thrown away a dark theme the server ships and follows by default.
/// Left unpinned, SonarQube turned dark and Oilbird's frame did not.
///
/// So the palette is dynamic instead. `NSColor(name:dynamicProvider:)`
/// re-resolves whenever anything reads it, which is what makes a toggle while
/// the app is open work — reading `effectiveAppearance` once at build time
/// gives a palette that is correct until the moment the user changes their
/// mind. Nothing pins an appearance anywhere any more.
///
/// ⚠ One thing this does NOT fix by itself: `NSColor.cgColor` resolves against
/// whatever appearance happens to be current when it is read, so a layer
/// background assigned once keeps that value forever. Every layer ground in
/// this app therefore goes through `Theme.Ground`, or through a `render()`
/// that `viewDidChangeEffectiveAppearance` calls again.
enum Theme {
    /// A colour that answers differently in each appearance.
    ///
    /// Named, because an unnamed dynamic colour cannot be told from another
    /// in a debugger and `NSColor` uses the name for equality.
    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func srgb(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// Runs a body with this view's appearance current, so any `cgColor`
    /// read inside it resolves to the right side of the palette.
    ///
    /// ⚠ `NSColor.cgColor` resolves against `NSAppearance.currentDrawing`,
    /// which AppKit sets for you inside `draw(_:)` and `updateLayer()` and
    /// **does not** set inside a `render()` called from a `didSet` or a
    /// state change. So a layer colour assigned from one of those took the
    /// app's default appearance whatever the window was wearing — which is
    /// the same class of fault as assigning it once in `init`, arriving by
    /// a different door.
    static func resolving(_ view: NSView, _ body: () -> Void) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance(body)
    }

    /// The appearance a preference asks Oilbird to wear, or nil for "leave
    /// it alone and follow the Mac".
    ///
    /// ⚠ **This is the same lever `pinToPaper` pulled, and the reason it is
    /// safe now is that the user is the one pulling it.** An appearance set
    /// on the application reaches every view of every window it owns — the
    /// `WKWebView` included — and the web view's `prefers-color-scheme`
    /// follows it, so SonarQube's own script stamps `data-echoes-theme` to
    /// match and `Tint`'s two blocks land on the right one. Chrome and
    /// dashboard move together from one control, with nothing injected.
    /// Pinning was a bug because it was ours and invisible; offered, it is
    /// the feature SonarQube itself ships as System / Dark / Light.
    ///
    /// nil rather than "whichever the Mac is now": pinning the current
    /// appearance would freeze it, and Auto has to keep following after the
    /// user changes their mind with Oilbird open.
    static func appearance(_ choice: Oilbird.Appearance) -> NSAppearance? {
        switch choice {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    enum Colour {
        /// The ground the whole app sits on.
        ///
        /// ⚠ The dark value is chosen against SonarQube's, not for its own
        /// sake. `MainWindowController` states the rule that the web
        /// content's own ground runs to the edges, and a cream frame
        /// around `#2a2f40` is exactly the iframe look that rule exists to
        /// prevent. Oilbird tints the dashboard to this value in both
        /// themes, and if that tint ever degrades to stock, `#262A36`
        /// against SonarQube's own dark ground is a seam nobody will see.
        /// the `chrome` check holds the two within tolerance of each
        /// other, from the palette `make tint-tokens` reads out of the
        /// pinned server.
        static let surface = dynamic(
            "surface",
            light: srgb(0.976, 0.969, 0.945),  // #F9F7F1
            dark: srgb(0.149, 0.165, 0.212))  // #262A36

        /// Raised above the ground: cards, and the dashboard's own panels.
        static let material = dynamic(
            "material",
            light: srgb(0.984, 0.976, 0.957),  // #FBF9F4
            dark: srgb(0.184, 0.204, 0.267))  // #2F3444

        /// Sunk below it: wells, the settings sidebar, the state pill.
        static let sunken = dynamic(
            "sunken",
            light: srgb(0.949, 0.937, 0.906),  // #F2EFE7
            dark: srgb(0.118, 0.129, 0.169))  // #1E212B

        static let rule = dynamic(
            "rule",
            light: srgb(0.863, 0.839, 0.784),  // #DCD6C8
            dark: srgb(0.290, 0.314, 0.376))  // #4A5060

        static let ruleSoft = dynamic(
            "ruleSoft",
            light: srgb(0.902, 0.882, 0.839),  // #E6E1D6
            dark: srgb(0.227, 0.247, 0.306))  // #3A3F4E

        /// The selection treatment: a filled block and its opposite for the
        /// text on it. It is what makes the one thing happening unmissable.
        ///
        /// It inverts rather than staying ink: ink on ink is not a
        /// selection. Cream filled with ink text reads the same way round
        /// as ink filled with cream text does on paper.
        static let selection = dynamic(
            "selection",
            light: srgb(0.133, 0.141, 0.165),  // #22242A
            dark: srgb(0.890, 0.882, 0.851))  // #E3E1D9
        static let onSelection = dynamic(
            "onSelection",
            light: srgb(0.976, 0.969, 0.945),
            dark: srgb(0.133, 0.141, 0.165))

        /// Warm off-white rather than SonarQube's blue-white `#e1e6f3`: the
        /// ground follows the dashboard so the seam disappears, but the
        /// type is the bird's own and there is nothing next to it to clash
        /// with.
        static let primaryText = dynamic(
            "primaryText",
            light: srgb(0.133, 0.141, 0.165),
            dark: srgb(0.906, 0.894, 0.855))  // #E7E4DA
        static let secondaryText = dynamic(
            "secondaryText",
            light: srgb(0.431, 0.420, 0.388),
            dark: srgb(0.659, 0.651, 0.616))  // #A8A69D
        static let tertiaryText = dynamic(
            "tertiaryText",
            light: srgb(0.569, 0.549, 0.510),
            dark: srgb(0.502, 0.494, 0.463))  // #807E76

        /// Terracotta, lifted on the dark ground. `#B4623A` at 3.0:1 against
        /// `#262A36` is under everything the platform asks of text.
        static let accent = dynamic(
            "accent",
            light: srgb(0.706, 0.384, 0.227),  // #B4623A
            dark: srgb(0.831, 0.475, 0.298))  // #D4794C
        /// The accent as it appears ON the selection fill, which is the
        /// opposite ground — so the two swap.
        static let onInkAccent = dynamic(
            "onInkAccent",
            light: srgb(0.831, 0.475, 0.298),
            dark: srgb(0.706, 0.384, 0.227))

        /// ⚠ **The status trio DOES vary by theme, and used not to.** It was
        /// invariant, on the grounds that a failure is the same red whatever
        /// the app is wearing, and that held while there was one ground.
        /// Measured on the second: `#B23A3A` against `#262A36` is **1.97:1**, which
        /// is not a red anybody can read, on the row whose whole job is
        /// saying something went wrong. The hues are unchanged; only the
        /// luminance moves, which is what a second ground requires.
        static let clean = dynamic(
            "clean",
            light: srgb(0.431, 0.608, 0.486),
            dark: srgb(0.498, 0.749, 0.584))  // #7FBF95
        static let changed = dynamic(
            "changed",
            light: srgb(0.753, 0.541, 0.243),
            dark: srgb(0.851, 0.627, 0.290))  // #D9A04A
        static let conflict = dynamic(
            "conflict",
            light: srgb(0.698, 0.227, 0.227),
            dark: srgb(0.886, 0.443, 0.420))  // #E2716B
    }

    /// How the settings sidebar marks the pane you are on.
    ///
    /// ⚠ **`Colour.selection` inverts, and inverting was reasoned for paper.**
    /// "Ink on ink is not a selection" is right, and on the cream ground the
    /// result is an ink capsule that reads like a printed tab. Turned over
    /// for the dark ground it becomes `#E3E1D9` — near-white — filling a
    /// capsule on `#1E212B`, which is not the same weight at all: on paper
    /// the selection is the darkest thing in the sidebar, and here it is by
    /// some distance the brightest thing in the window, which pulls the eye
    /// away from the content it is meant to label.
    ///
    /// The candidates are kept side by side so the choice is one line to
    /// change: it is a looking-at-it decision. Only this sidebar reads it;
    /// `Colour.selection` still dresses the switch, the segmented control
    /// and the dependency list.
    enum SidebarSelection {
        /// The palette's own inversion.
        case invert
        /// Raised. One step up from the sunken sidebar, the way macOS
        /// System Settings lifts its chosen row rather than reversing it.
        case raised
        /// The accent, quietly. Unmistakably Oilbird's hue without
        /// becoming the loudest thing in the window.
        case tint
        /// The accent, solid. The same terracotta as the Done button.
        case accent

        /// **The one line.** Change it and rebuild; nothing else moves.
        static let chosen: SidebarSelection = .tint

        /// How much accent a tint is. Low enough to stay behind the text,
        /// high enough to be a selection and not a hover.
        private static let tintAlpha: CGFloat = 0.18
        /// The icon's own well, on a ground that has inverted.
        private static let wellOnFill: CGFloat = 0.22
        /// And on one that has not — the same well an unchosen row wears,
        /// because a tile that stays put is what makes the capsule the
        /// thing that moved.
        private static let wellOnGround: CGFloat = 0.16

        /// The tile a row that is NOT chosen wears, here beside the chosen
        /// forms so the pair cannot drift apart in two files.
        static var unchosenIconWell: NSColor {
            Colour.accent.withAlphaComponent(wellOnGround)
        }

        var fill: NSColor {
            switch self {
            case .invert: Colour.selection
            case .raised: Colour.material
            case .tint: Colour.accent.withAlphaComponent(Self.tintAlpha)
            case .accent: Colour.accent
            }
        }

        var text: NSColor {
            switch self {
            case .invert, .accent: Colour.onSelection
            case .raised, .tint: Colour.primaryText
            }
        }

        var iconWell: NSColor {
            switch self {
            case .invert, .accent: Colour.onSelection.withAlphaComponent(Self.wellOnFill)
            case .raised, .tint: Colour.accent.withAlphaComponent(Self.wellOnGround)
            }
        }

        var icon: NSColor {
            switch self {
            case .invert, .accent: Colour.onSelection
            case .raised, .tint: Colour.accent
            }
        }

        /// ⚠ The keyboard's ring is drawn in the accent, and on `accent`
        /// that is a ring the same colour as what it rings — invisible,
        /// which loses the one mark that says where the keyboard is.
        var focusRing: NSColor {
            switch self {
            case .accent: Colour.onSelection
            case .invert, .raised, .tint: Colour.accent
            }
        }
    }

    enum Metric {
        static let rowHeight: CGFloat = 46
        static let rowRadius: CGFloat = 8
        static let content: CGFloat = 18
        static let rowPadding: CGFloat = 16
    }

    enum Font {
        static let title = NSFont.systemFont(ofSize: 26, weight: .semibold)
        static let rowName = NSFont.systemFont(ofSize: 14, weight: .medium)
        static let body = NSFont.systemFont(ofSize: 13)
        static let meta = NSFont.systemFont(ofSize: 11)
        /// Tabular, so a moving byte count does not make the row jitter.
        static let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    }

    /// A view whose layer colours re-resolve when the appearance changes.
    ///
    /// ⚠ `NSColor.cgColor` resolves against whatever appearance is current at
    /// the moment it is read, so a layer background assigned once in `init`
    /// keeps its light-mode value forever. That is how a dynamic palette
    /// still leaves cream cards under white text in dark mode: the text
    /// followed the appearance and the card did not.
    ///
    /// The fill is a closure rather than a colour so it is *re-read* on each
    /// pass — capturing an `NSColor` and reading `.cgColor` later would have
    /// exactly the same fault one level down.
    final class Ground: NSView {
        private let fill: () -> NSColor
        private let border: (() -> NSColor)?

        init(radius: CGFloat = 0, fill: @escaping () -> NSColor, border: (() -> NSColor)? = nil) {
            self.fill = fill
            self.border = border
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = radius
            layer?.masksToBounds = radius > 0
            if border != nil { layer?.borderWidth = 1 }
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.backgroundColor = fill().cgColor
            if let border { layer?.borderColor = border().cgColor }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}
