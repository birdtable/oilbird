import AppKit

/// The two controls settings could not draw in Oilbird's own colours.
///
/// `NSSwitch` and `NSSegmentedControl` paint themselves in the SYSTEM accent
/// and take no tint, so a paper window had a blue switch in it — and, in the
/// old panel, a blue-tinted checkbox beside terracotta buttons. Everything
/// else in this app is already drawn by hand, so these are the same idiom
/// rather than new machinery. On is `selection`, never the accent, which is
/// the rule the sidebar capsule follows too.
final class PaperSwitch: NSControl {
    var on: Bool = false {
        didSet { needsDisplay = true }
    }

    init(on: Bool, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.on = on
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SettingsLayout.switchWidth),
            heightAnchor.constraint(equalToConstant: SettingsLayout.switchHeight),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// ⚠ **A role on a view that is not an accessibility element does
    /// nothing.** `setAccessibilityRole(.checkBox)` was the whole of this,
    /// and the tree that came back from the settings window held eight
    /// `AXStaticText`s and not one control — so every switch in it was
    /// invisible to VoiceOver, and the keyboard support below was reachable
    /// only by someone who could already see where they were. Claiming the
    /// element is what publishes the rest.
    ///
    /// The label is not overridden: `SettingsDesign.row` sets it from the
    /// row's own title, so the switch is announced as the thing it governs
    /// rather than as "switch".
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }

    /// A switch you can only click is a switch half the people who use
    /// settings cannot reach. It announces itself to VoiceOver as a
    /// checkbox, so it has to be pressable the way one is.
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        // Space and Return, which is what every switch on this platform
        // takes.
        guard event.keyCode == 49 || event.keyCode == 36 else {
            return super.keyDown(with: event)
        }
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    override func accessibilityValue() -> Any? { on }

    private func toggle() {
        guard isEnabled else { return }
        on.toggle()
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (on ? Theme.Colour.selection : Theme.Colour.rule).setFill()
        track.fill()

        let inset = (bounds.height - SettingsLayout.switchKnob) / 2
        let x = on ? bounds.width - SettingsLayout.switchKnob - inset : inset
        let knob = NSRect(
            x: x, y: inset,
            width: SettingsLayout.switchKnob, height: SettingsLayout.switchKnob)
        (on ? Theme.Colour.onSelection : Theme.Colour.material).setFill()
        NSBezierPath(ovalIn: knob).fill()

        alphaValue = isEnabled ? 1 : 0.4

        // Focus is drawn, because the app draws its own chrome: the system
        // ring never appears on a hand-painted control, so a keyboard user
        // had no way to see where they were.
        guard window?.firstResponder === self else { return }
        Theme.Colour.accent.setStroke()
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: -2.5, dy: -2.5),
            xRadius: bounds.height / 2 + 2.5, yRadius: bounds.height / 2 + 2.5)
        ring.lineWidth = 2
        ring.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        toggle()
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One of several, the chosen one filled: a bordered strip with a hairline
/// between the segments.
final class PaperSegmented: NSControl {
    private(set) var selectedSegment: Int
    private var labels: [NSTextField] = []
    private var fills: [Theme.Ground] = []

    init(labels titles: [String], selected: Int, target: AnyObject?, action: Selector?) {
        selectedSegment = selected
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = SettingsLayout.segmentRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        var cells: [NSView] = []
        for (index, title) in titles.enumerated() {
            let label = NSTextField(labelWithString: title)
            label.font = Theme.Font.meta
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false

            let fill = Theme.Ground(fill: { [weak self] in
                self?.selectedSegment == index ? Theme.Colour.selection : .clear
            })
            fill.translatesAutoresizingMaskIntoConstraints = false
            fill.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: fill.centerYAnchor),
                label.leadingAnchor.constraint(
                    equalTo: fill.leadingAnchor, constant: SettingsLayout.segmentPaddingX),
                label.trailingAnchor.constraint(
                    equalTo: fill.trailingAnchor, constant: -SettingsLayout.segmentPaddingX),
                fill.heightAnchor.constraint(
                    equalToConstant: Theme.Font.meta.pointSize
                        + SettingsLayout.segmentPaddingY * 2 + 6),
            ])
            labels.append(label)
            fills.append(fill)
            // A hairline between segments, never before the first.
            if index > 0 {
                let rule = Theme.Ground(fill: { Theme.Colour.rule })
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
                cells.append(rule)
            }
            cells.append(fill)
        }

        let stack = NSStackView(views: cells)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        translatesAutoresizingMaskIntoConstraints = false
        render()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The same gap as `PaperSwitch`, and worse: this reached VoiceOver as
    /// an unnamed group of labels. ← and → move between segments, which is
    /// what the platform's own does.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
    override func accessibilityChildren() -> [Any]? { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool { render(); return true }
    override func resignFirstResponder() -> Bool { render(); return true }

    override func keyDown(with event: NSEvent) {
        let step: Int
        switch event.keyCode {
        case 123: step = -1  // ←
        case 124: step = 1  // →
        default: return super.keyDown(with: event)
        }
        let next = selectedSegment + step
        guard fills.indices.contains(next) else { return }
        select(next)
    }

    override func accessibilityValue() -> Any? {
        labels.indices.contains(selectedSegment) ? labels[selectedSegment].stringValue : nil
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = fills.firstIndex(where: { $0.frame.contains(point) }) else { return }
        select(index)
    }

    private func select(_ index: Int) {
        guard index != selectedSegment else { return }
        selectedSegment = index
        render()
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    private func render() {
        let focused = window?.firstResponder === self
        Theme.resolving(self) {
            layer?.borderColor = (focused ? Theme.Colour.accent : Theme.Colour.rule).cgColor
        }
        layer?.borderWidth = focused ? 2 : 1
        for (index, label) in labels.enumerated() {
            label.textColor =
                index == selectedSegment ? Theme.Colour.onSelection : Theme.Colour.secondaryText
        }
        for fill in fills { fill.needsDisplay = true }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidChangeEffectiveAppearance() { render() }
}
