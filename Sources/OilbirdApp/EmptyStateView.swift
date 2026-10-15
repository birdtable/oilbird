import AppKit

/// What the window shows when the web view has nothing to show.
///
/// Three of these are met routinely rather than exceptionally: the server
/// stops when unattended, so a returning user lands on "stopped" or "starting"
/// most mornings, and "nothing scanned yet" is every first run. A blank
/// rectangle for any of them is a dead end.
final class EmptyStateView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    /// Shown only while something is genuinely in progress.
    ///
    /// A twenty-five second wait behind one unchanging sentence is
    /// indistinguishable from a hang, and the slow part of a start is always
    /// the search index. A spinner is the difference between "working" and
    /// "stuck" when the words cannot change fast enough to say so.
    private let bird = BirdView()
    /// The last thing the work said about itself.
    ///
    /// A scan is minutes long and its only honest progress signal is the
    /// scanner's own commentary — "Sensor JavaScript", "Analysis report
    /// uploaded". Without it the window says "Scanning" for four minutes
    /// and is indistinguishable from a window that is doing nothing, which
    /// is exactly what it was mistaken for.
    private let progress = NSTextField(labelWithString: "")
    private var onPress: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Theme.Colour.primaryText
        title.alignment = .center
        detail.font = Theme.Font.body
        detail.textColor = Theme.Colour.secondaryText
        detail.alignment = .center
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(press)
        button.isHidden = true
        progress.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        progress.textColor = Theme.Colour.tertiaryText
        progress.alignment = .center
        progress.lineBreakMode = .byTruncatingMiddle
        progress.isHidden = true
        // ⚠ Below its content size in both directions. A scanner line can be
        // two hundred characters, and left to itself this label widened the
        // stack — the title and the bird jumped left on every line.
        progress.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bird.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bird.widthAnchor.constraint(equalToConstant: 96),
            bird.heightAnchor.constraint(equalToConstant: 96),
        ])

        let stack = NSStackView(views: [bird, title, detail, progress, button])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            progress.widthAnchor.constraint(equalToConstant: 420),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The ground, re-resolved on every draw.
    ///
    /// ⚠ It was `layer?.backgroundColor = …cgColor` in `init`. A `cgColor`
    /// is resolved against whatever appearance is current when it is read,
    /// so this panel stayed cream when the user turned dark mode on, under
    /// text that had correctly turned pale.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.Colour.surface.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func press() { onPress?() }

    func show(
        title: String, detail: String, action: String? = nil, working: Bool = false,
        press: (() -> Void)? = nil
    ) {
        isHidden = false
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.detail.isHidden = detail.isEmpty
        button.title = action ?? ""
        button.isHidden = action == nil
        onPress = press
        // Cleared here, not by the caller. A line left over from the last
        // scan under the words "Nothing scanned yet" is a lie with a
        // timestamp on it.
        progress.stringValue = ""
        progress.isHidden = true
        // The mark is always there; what changes is whether it is calling.
        // A system spinner appearing and vanishing made the panel jump; the
        // bird just starts pinging.
        bird.isCalling = working
    }

    /// Shows what the running work is doing right now.
    func report(_ line: String) {
        progress.stringValue = line
        progress.isHidden = line.isEmpty
    }
}
