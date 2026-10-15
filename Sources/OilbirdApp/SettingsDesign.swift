import AppKit
import OilbirdKit

/// The pieces the settings window is built from.
///
/// The shape is a searchable sidebar of panes, grouped cards, and a row
/// that is a label with its explanation under it and its control hard
/// against the trailing edge. It draws on Oilbird's ground, which follows
/// the system into dark.
///
/// The old panel was 211 lines of one flat stack with a hand-drawn title in
/// it, and it had three separate defects in that one screen:
/// literal markdown backticks shown to a user, the word "Settings" drawn
/// twice, and an explanation written as though a disabled field were live.
/// None of them is possible in this shape — a row's label and its
/// explanation come from one call, the pane's name is the window's heading
/// and is written once, and the `settings` check fails the build on a
/// backtick in a user-visible string.
enum SettingsDesign {
    /// A grouped card.
    ///
    /// Separators are inset from the leading edge the way AppKit's own lists
    /// inset them, so the group reads as a single object rather than as a
    /// stack of unrelated strips.
    static func card(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            if index > 0 { stack.addArrangedSubview(separator()) }
            stack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let container = Theme.Ground(
            radius: SettingsLayout.cardRadius,
            fill: { Theme.Colour.material },
            border: { Theme.Colour.rule })
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private static func separator() -> NSView {
        let line = Theme.Ground(fill: { Theme.Colour.ruleSoft })
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// One row: a label, an optional explanation under it, an optional
    /// path under that, and a control hard against the trailing edge.
    ///
    /// The explanation lives under its own label rather than floating
    /// between rows, so the alignment cannot break — and the row stamps its
    /// own searchable text, which is why no separate search index can ever
    /// drift from what is displayed.
    ///
    /// ⚠ **A path is a `path:`, never a sentence with a path in it.** Four
    /// panes each showed one their own way — wrapped whole in prose, in the
    /// value column truncated to `/Users/alex…/oilbird-mcp`, and inside
    /// the snippet — and on a long home directory the prose one wrapped
    /// across the row and ran at the button beside it. One parameter, one
    /// treatment: `Oilbird.displayPath` for the `~`, the monospaced face so
    /// it is unmistakably a path, whole rather than truncated (an elided
    /// path cannot be checked, typed or pasted, which is the entire use for
    /// showing one), and its own line under the label so there is nothing
    /// for it to collide with.
    static func row(
        _ title: String, detail: String? = nil, path: String? = nil, control: NSView? = nil
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = Theme.Font.body
        label.textColor = Theme.Colour.primaryText

        var lines: [NSView] = [label]
        var wrapping: [NSTextField] = []
        if let detail {
            let sub = NSTextField(wrappingLabelWithString: detail)
            sub.font = Theme.Font.meta
            sub.textColor = Theme.Colour.secondaryText
            wrapping.append(sub)
            lines.append(sub)
        }
        let shownPath = path.map { Oilbird.displayPath($0) }
        if let shownPath {
            let sub = NSTextField(wrappingLabelWithString: shownPath)
            sub.font = Theme.Font.mono
            sub.textColor = Theme.Colour.secondaryText
            // The first thing anyone does with a path is copy part of it.
            sub.isSelectable = true
            wrapping.append(sub)
            lines.append(sub)
        }
        for sub in wrapping {
            // A starting guess only; the real width comes from the row's own
            // geometry in `layout()`. A fixed reserve wraps the sentence at
            // 208pt with 180pt of the card empty beside a 36pt switch.
            sub.preferredMaxLayoutWidth = SettingsLayout.detailWrapGuess
            // ⚠ So the SOLVER squeezes the sentence while `layout()` has no
            // width to measure. Otherwise the label wins on compression and
            // AppKit breaks the "keep clear" constraint instead.
            sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let text: NSView
        if lines.count == 1 {
            text = label
        } else {
            let stack = NSStackView(views: lines)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = SettingsLayout.labelDetailGap
            text = stack
        }

        let container = SettingsRow()
        container.control = control
        container.wrappingText = wrapping
        container.searchText =
            [title, detail, shownPath].compactMap { $0 }.joined(separator: " ").lowercased()
        text.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(text)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(
                greaterThanOrEqualToConstant:
                    wrapping.isEmpty ? SettingsLayout.rowHeight : SettingsLayout.tallRowHeight),
            text.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: SettingsLayout.rowInset),
            text.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            text.topAnchor.constraint(
                greaterThanOrEqualTo: container.topAnchor,
                constant: SettingsLayout.rowPadding),
            text.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor,
                constant: -SettingsLayout.rowPadding),
        ])

        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            // What the control is FOR, from the row that names it: without it
            // VoiceOver gets "switch" and an unrelated label, neither of which
            // says "Show the menu bar icon, off".
            if control.accessibilityLabel() == nil { control.setAccessibilityLabel(title) }
            container.addSubview(control)
            NSLayoutConstraint.activate([
                control.trailingAnchor.constraint(
                    equalTo: container.trailingAnchor,
                    constant: -SettingsLayout.rowInset),
                control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                control.leadingAnchor.constraint(
                    greaterThanOrEqualTo: text.trailingAnchor,
                    constant: SettingsLayout.rowGap),
            ])
        } else {
            text.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -SettingsLayout.rowInset
            ).isActive = true
        }
        return container
    }

    /// A row whose whole width is one block of monospaced text — the MCP
    /// snippet, the exclusion list as the scanner receives it.
    ///
    /// Selectable, because the first thing anyone does with a path or a
    /// JSON blob is copy part of it, and a label that cannot be selected is
    /// a screenshot.
    ///
    /// ⚠ **Wrapped with a hanging indent, not scrolled sideways.** A path
    /// long enough to overrun the card took the `"command"` line with it
    /// and resumed at column zero, so the braces no longer lined up and
    /// four lines of JSON read as six lines of nothing. Both fixes were
    /// available and this is the one chosen: a horizontal scroller inside
    /// a card inside the pane's own scroll view gives a trackpad two
    /// things to do in the same square inch, and it hides the end of the
    /// one string in this window a person has to check character by
    /// character. Indented, every continuation sits deeper than any real
    /// line of the block, which is how a soft-wrapping editor shows the
    /// same file.
    ///
    /// It is a paragraph style and nothing else: no character is added,
    /// removed or moved. Copy takes `Oilbird.mcpClientSnippet()` itself,
    /// so what lands in the client is the JSON regardless of how many
    /// lines it was drawn over.
    static func blockRow(_ title: String, text body: String, control: NSView? = nil) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = Theme.Font.body
        heading.textColor = Theme.Colour.primaryText

        let hanging = NSMutableParagraphStyle()
        hanging.headIndent = SettingsLayout.blockHangingIndent
        let block = NSTextField(wrappingLabelWithString: body)
        // Through the attributed string, because `NSTextField` has no
        // paragraph style of its own. The colour stays dynamic and resolves
        // when drawn, so it still follows the appearance.
        block.attributedStringValue = NSAttributedString(
            string: body,
            attributes: [
                .font: Theme.Font.mono,
                .foregroundColor: Theme.Colour.secondaryText,
                .paragraphStyle: hanging,
            ])
        block.isSelectable = true
        block.preferredMaxLayoutWidth =
            SettingsLayout.windowWidth - SettingsLayout.margin * 2
            - SettingsLayout.rowInset * 2

        let top: NSView
        var header: NSStackView?
        if let control {
            let spacer = NSView()
            let line = NSStackView(views: [heading, spacer, control])
            line.orientation = .horizontal
            line.spacing = SettingsLayout.rowGap
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            header = line
            top = line
        } else {
            top = heading
        }

        let stack = NSStackView(views: [top, block])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsLayout.blockGap
        stack.edgeInsets = NSEdgeInsets(
            top: SettingsLayout.blockPadding, left: SettingsLayout.rowInset,
            bottom: SettingsLayout.blockPadding, right: SettingsLayout.rowInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = SettingsRow()
        container.searchText = (title + " " + body).lowercased()
        container.addSubview(stack)
        // ⚠ The header line must be TOLD the width: a `.leading` stack gives
        // each subview its fitting width, and a spacer hugging at priority 1
        // grows this line past the inset everything below respects.
        if let header {
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(
                    equalTo: container.leadingAnchor, constant: SettingsLayout.rowInset),
                header.trailingAnchor.constraint(
                    equalTo: container.trailingAnchor, constant: -SettingsLayout.rowInset),
            ])
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        if control != nil { top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return container
    }

    /// A read-only value: a label, and the answer in the monospaced face on
    /// the trailing edge.
    ///
    /// Half these panes are read-only and that is the point: "is it
    /// actually up?" must be answerable without
    /// the CLI, and a settings window is where a person looks when they
    /// want to know what an app is doing.
    ///
    /// ⚠ Not for a path. The column is a fixed reserve and the value is
    /// truncated down the middle to fit it, which is right for a port, a
    /// version or a byte count and useless for a path — `/Users/alex…/
    /// oilbird-mcp` names no file anybody can open. Paths go through
    /// `row(_:path:)`, which shows them whole.
    static func reading(_ title: String, _ value: String, detail: String? = nil) -> NSView {
        let field = NSTextField(labelWithString: value)
        field.font = Theme.Font.mono
        field.textColor = Theme.Colour.secondaryText
        field.alignment = .right
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(
            lessThanOrEqualToConstant: SettingsLayout.readingWidth
        ).isActive = true
        let made = row(title, detail: detail, control: field)
        (made as? SettingsRow)?.searchText += " " + value.lowercased()
        return made
    }

    static func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.Colour.secondaryText
        return label
    }

    /// A footnote under a card, for what needs a sentence rather than a
    /// control.
    static func footnote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.Font.meta
        label.textColor = Theme.Colour.tertiaryText
        label.preferredMaxLayoutWidth = SettingsLayout.windowWidth - SettingsLayout.margin * 2
        return label
    }

    /// A footnote that has something to say: a refused action, and why.
    ///
    /// `conflict` rather than the accent — the accent is what this window
    /// uses for things you can press, and this is not one of them.
    /// A warning that lives INSIDE a card, as its own row.
    ///
    /// `warning(_:)` is a footnote under a card and reads as commentary;
    /// this is a row above the thing it is about, because the MCP snippet
    /// was copied before anyone got as far as the prose underneath it.
    static func noticeRow(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.Font.meta
        label.textColor = Theme.Colour.conflict
        label.preferredMaxLayoutWidth =
            SettingsLayout.windowWidth - SettingsLayout.margin * 2
            - SettingsLayout.rowInset * 2
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = SettingsRow()
        container.searchText = text.lowercased()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(
                equalTo: container.topAnchor, constant: SettingsLayout.blockPadding),
            label.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -SettingsLayout.blockPadding),
            label.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: SettingsLayout.rowInset),
            label.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -SettingsLayout.rowInset),
        ])
        return container
    }

    static func warning(_ text: String) -> NSTextField {
        let label = footnote(text)
        label.textColor = Theme.Colour.conflict
        return label
    }

    /// A document view whose origin is the top-left, so a long pane opens
    /// at its first section rather than its last.
    final class FlippedHost: NSView {
        override var isFlipped: Bool { true }
    }
}

/// A settings row that knows what it is called, so a search can find it.
final class SettingsRow: NSView {
    var searchText = ""
    /// The lines under the label that wrap — the explanation, the path, or
    /// both — and whatever sits on the trailing edge. Both are needed to
    /// work out how wide those lines may be, which is a fact about *this*
    /// row and not about the window.
    var wrappingText: [NSTextField] = []
    var control: NSView?

    override func layout() {
        super.layout()
        guard !wrappingText.isEmpty, bounds.width > 0 else { return }
        // ⚠ The control's own FRAME once it has one, and `fittingSize` only
        // before that: a segmented control ends up wider than it asks for, and
        // the difference is reserved for nothing while the sentence wraps.
        let width = control.map { max($0.frame.width, $0.fittingSize.width) } ?? 0
        let taken = control == nil ? 0 : width + SettingsLayout.rowGap
        let available = bounds.width - SettingsLayout.rowInset * 2 - taken
        guard available > SettingsLayout.narrowestSentence else { return }
        var moved = false
        for line in wrappingText where abs(line.preferredMaxLayoutWidth - available) > 0.5 {
            line.preferredMaxLayoutWidth = available
            moved = true
        }
        // Only when it actually changed: assigning unconditionally asks for
        // another layout pass every pass.
        guard moved else { return }
        needsLayout = true
    }
}

/// One titled group of rows.
///
/// The whole group is what a search hides or shows: hiding individual rows
/// leaves a card with a heading over nothing.
final class SettingsSection: NSView {
    var searchText = ""
}

/// One name in the settings sidebar.
///
/// Shaped like System Settings — an icon in a tinted well, a filled capsule
/// when it is the pane you are on — in Oilbird's colours, and never the
/// system accent: the system accent is the one colour in this window that
/// is not the app's. What the capsule is filled with is
/// `Theme.SidebarSelection.chosen`, which is where that argument is had.
final class SettingsSidebarRow: NSView {
    let title: String
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let well = NSView()
    /// Where this row sits, and how the window is told to go somewhere.
    /// The row asks for a position rather than for itself, so ↑ and ↓ are
    /// the same call as a click and the bounds check lives in one place.
    private let index: Int
    private let choose: (Int) -> Void

    /// Dimmed when a search matches nothing in this pane, so the sidebar
    /// answers "is it in there?" without being clicked.
    var hasMatches = true { didSet { render() } }
    var isChosen = false { didSet { render() } }

    init(title: String, symbol: String, index: Int, choose: @escaping (Int) -> Void) {
        self.title = title
        self.index = index
        self.choose = choose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = SettingsLayout.sidebarRowHeight / 2

        label.stringValue = title
        label.font = Theme.Font.body
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        well.wantsLayer = true
        well.layer?.cornerRadius = SettingsLayout.sidebarIconRadius

        for view in [well, icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            // The row IS the button; its parts must not be separate stops
            // in the accessibility tree.
            view.setAccessibilityElement(false)
        }
        addSubview(well)
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: SettingsLayout.sidebarIconInset),
            well.centerYAnchor.constraint(equalTo: centerYAnchor),
            well.widthAnchor.constraint(equalToConstant: SettingsLayout.sidebarIcon),
            well.heightAnchor.constraint(equalToConstant: SettingsLayout.sidebarIcon),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            label.leadingAnchor.constraint(
                equalTo: well.trailingAnchor, constant: SettingsLayout.sidebarLabelGap),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -SettingsLayout.sidebarLabelTrail),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: SettingsLayout.sidebarRowHeight),
            widthAnchor.constraint(
                equalToConstant: SettingsLayout.sidebarWidth - SettingsLayout.sidebarInset * 2),
        ])
        render()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // ⚠ The whole row is ONE button. Setting a role on a view that is not
    // itself an accessibility element does nothing, leaving unnamed images and
    // loose text, so only a mouse reaches a pane.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityChildren() -> [Any]? { nil }
    override func accessibilityPerformPress() -> Bool {
        choose(index)
        return true
    }

    /// Tab reaches it, ↑ and ↓ move between panes, and the focus is drawn —
    /// the app paints its own chrome, so the system ring never appears.
    ///
    /// ⚠ **`canBecomeKeyView` is `isChosen`, and that is the fix for two
    /// indicators at once.** This sidebar wears two marks — the filled
    /// capsule for the pane you are on, the ring for where the keyboard is
    /// — and nothing kept them together, so a click moved the capsule while
    /// the ring stayed put. Scrolling the content and then clicking another
    /// pane left Scanning ringed and Versions filled at once. Making only the
    /// chosen row tabbable, moving the focus on a click
    /// (`SettingsWindowController.selectPane`), and moving the pane on an
    /// arrow key leaves the two unable to disagree: the ring is only ever
    /// absent (focus is elsewhere in the window) or on the capsule.
    ///
    /// It is a list, in other words, and this is what a list does. VoiceOver
    /// still reaches every row — it navigates the accessibility tree, not
    /// the key view loop — and presses them through `accessibilityPerformPress`.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { isChosen }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        // Space and Return: already here, so this is a no-op that keeps the
        // row behaving like the button it announces itself as.
        case 49, 36: choose(index)
        case 126: choose(index - 1)  // ↑
        case 125: choose(index + 1)  // ↓
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // ⚠ `isChosen` as well as the focus, so the two marks cannot land on
        // different rows: AppKit moves the first responder itself when the
        // view holding it is hidden, which is what changing pane does.
        guard isChosen, window?.firstResponder === self else { return }
        Theme.SidebarSelection.chosen.focusRing.setStroke()
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: SettingsLayout.sidebarRowHeight / 2,
            yRadius: SettingsLayout.sidebarRowHeight / 2)
        ring.lineWidth = 2
        ring.stroke()
    }

    private func render() {
        let mark = Theme.SidebarSelection.chosen
        Theme.resolving(self) {
            layer?.backgroundColor = (isChosen ? mark.fill : .clear).cgColor
            well.layer?.backgroundColor =
                (isChosen ? mark.iconWell : Theme.SidebarSelection.unchosenIconWell).cgColor
        }
        icon.contentTintColor = isChosen ? mark.icon : Theme.Colour.accent
        label.textColor =
            isChosen
            ? mark.text
            : (hasMatches ? Theme.Colour.primaryText : Theme.Colour.tertiaryText)
        alphaValue = hasMatches ? 1 : 0.55
        // The ring is painted in `draw`, which a layer colour assignment
        // does not re-run — and whether it is painted now depends on
        // `isChosen`.
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { choose(index) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    /// Every colour above goes through `cgColor`, which resolves once —
    /// so the capsule and the icon well both need painting again.
    override func viewDidChangeEffectiveAppearance() { render() }
}
