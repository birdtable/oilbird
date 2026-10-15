import Foundation

/// The settings window's own layout numbers.
///
/// ⚠ **Beside `Theme`, not inside it.** A single `windowWidth` shared by
/// both windows comes to mean two different things a scroll apart.
/// Oilbird's main window is sized from SonarQube's own container width — a
/// number it does not choose — and settings is a fixed sheet with a
/// sidebar. They are not the same measurement and must not share a name.
///
/// the `settings` check holds the other half of that: no number here
/// may appear as a layout literal anywhere else in the app. A metric that is
/// also written out by hand two files away is not a single home for it, it is
/// a coincidence waiting to be edited.
enum SettingsLayout {
    /// The content column, beside the sidebar. Not `Theme.Metric`'s
    /// anything: the main window is 1344 wide because SonarQube is.
    static let windowWidth: CGFloat = 520
    static let windowHeight: CGFloat = 580
    /// The smallest it opens at, and therefore the size every pane has to
    /// be legible at.
    static let minimumHeight: CGFloat = 470
    static let sidebarWidth: CGFloat = 186
    static let margin: CGFloat = 22
    static let sectionSpacing: CGFloat = 21
    /// Between a small-caps heading and the card it introduces.
    static let titleGap: CGFloat = 7
    static let cardRadius: CGFloat = 10
    static let rowHeight: CGFloat = 42
    /// A row with an explanation under its label.
    static let tallRowHeight: CGFloat = 57
    static let rowInset: CGFloat = 13
    /// Above and below a row's text, so a two-line row breathes without the
    /// height constraint having to be exact.
    static let rowPadding: CGFloat = 9
    /// Between a label and the sentence under it.
    static let labelDetailGap: CGFloat = 2
    /// The starting guess for how wide an explanation may be. Replaced by
    /// the row's real geometry the first time it lays out — this only has
    /// to be sane before there is any geometry to ask.
    static let detailWrapGuess: CGFloat = 200
    /// Below this a sentence is a column of two words, so the row keeps the
    /// guess above and lets the text run to the height it needs rather than
    /// shredding it. Nothing in this window has a control wide enough to
    /// reach it; it is the floor that says so.
    static let narrowestSentence: CGFloat = 80
    /// A block of monospaced text inside a card: the MCP snippet, the
    /// exclusion list as the scanner receives it.
    static let blockGap: CGFloat = 6
    static let blockPadding: CGFloat = 11
    /// Where a wrapped line of that block resumes. Deeper than the deepest
    /// real indentation in it — the MCP snippet nests three levels, six
    /// monospaced spaces — so a continuation can never be mistaken for a
    /// line of its own.
    static let blockHangingIndent: CGFloat = 60
    /// Between a label and the control on the trailing edge, at the
    /// narrowest the row is allowed to get before the sentence wraps.
    static let rowGap: CGFloat = 15
    /// The hand-drawn switch, because `NSSwitch` paints in the system
    /// accent and takes no tint — a blue switch is the one thing in a paper
    /// window that is not the paper's colour.
    static let switchWidth: CGFloat = 36
    static let switchHeight: CGFloat = 21
    static let switchKnob: CGFloat = 17
    static let segmentRadius: CGFloat = 6
    static let segmentPaddingX: CGFloat = 11
    static let segmentPaddingY: CGFloat = 4
    /// The sidebar, shaped like System Settings: a capsule per row, a
    /// tinted well for the icon, and real air under the search field rather
    /// than the row gap.
    static let sidebarRowHeight: CGFloat = 29
    static let sidebarInset: CGFloat = 9
    static let sidebarSearchGap: CGFloat = 15
    static let sidebarIcon: CGFloat = 21
    static let sidebarIconRadius: CGFloat = 5
    /// From the capsule's leading edge to the icon well.
    static let sidebarIconInset: CGFloat = 7
    /// From the icon well to the name.
    static let sidebarLabelGap: CGFloat = 9
    /// The name's own breathing room before the capsule's trailing edge.
    static let sidebarLabelTrail: CGFloat = 8
    /// Between capsules.
    static let sidebarRowGap: CGFloat = 2
    /// Under the last capsule, so the list does not end flush with the
    /// window.
    static let sidebarBottom: CGFloat = 12
    /// The strip the traffic lights float in, once there is no title bar
    /// for them to sit in. The pane's heading is centred in it, so it is a
    /// little taller than the lights alone would need.
    static let titlebarClearance: CGFloat = 44
    /// Above the first card. Small, because the heading's own band already
    /// gives the content air.
    static let contentTopGap: CGFloat = 9
    /// The footer of real actions, and Done.
    static let footerTop: CGFloat = 11
    static let footerBottom: CGFloat = 13
    /// Between the footer's buttons.
    static let footerGap: CGFloat = 8
    /// The minutes field, wide enough for "1440".
    static let minutesWidth: CGFloat = 46
    /// Between the minutes field, its stepper and the unit after it.
    static let minutesGap: CGFloat = 5
    /// A value read rather than set — a port, a path, a version — set in
    /// the monospaced face and right-aligned so a column of them lines up.
    static let readingWidth: CGFloat = 168
    /// The text field a glob list or a port is typed into.
    static let entryWidth: CGFloat = 196
}
