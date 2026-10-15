import AppKit
import OilbirdKit

/// One dependency, in one of seven states.
///
/// The active row is filled ink with cream text — the one thing happening is
/// the only lit thing on the screen. Everything else is quiet.
final class DependencyRowView: NSView {
    enum State {
        case waiting
        case downloading(done: Int64, total: Int64, rate: String)
        case verifying
        case installing
        /// Slow and with nothing to show — verifying the runtime means booting
        /// the server on it. If this reads as frozen, people force-quit part
        /// way through provisioning, so it says so instead.
        case checking(note: String)
        case ready
        case failed(reason: String, action: String)
    }

    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let dot = NSView()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    var onAction: (() -> Void)?

    init(title: String, bytes: Int64) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Metric.rowRadius

        name.stringValue = title
        name.font = Theme.Font.rowName
        detail.font = Theme.Font.mono
        size.font = Theme.Font.mono
        size.alignment = .right
        size.stringValue = bytes > 0 ? Oilbird.humanBytes(bytes) : "—"

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.isHidden = true
        bar.controlSize = .small

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5

        actionButton.bezelStyle = .rounded
        actionButton.isHidden = true
        actionButton.target = self
        actionButton.action = #selector(act)

        for view in [name, detail, size, bar, dot, actionButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.rowHeight),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metric.rowPadding),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 14),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            bar.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            bar.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 5),
            bar.widthAnchor.constraint(equalToConstant: 260),
            actionButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Theme.Metric.rowPadding),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            size.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Theme.Metric.rowPadding),
            size.topAnchor.constraint(equalTo: topAnchor, constant: 11),
        ])
        apply(.waiting)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func act() { onAction?() }

    /// ⚠ Kept so the row can be painted again when the appearance changes.
    /// Every colour below is written through `cgColor`, which resolves once
    /// and never again — so a row that was drawn in light mode kept an ink
    /// fill under pale text the moment the user turned dark mode on.
    /// Re-running `apply` is the whole fix: it is already the one place
    /// that decides every colour in this view.
    private var shown: State = .waiting

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(shown)
    }

    func apply(_ state: State) {
        shown = state
        // Every layer colour below is a `cgColor`, and this is not inside a
        // draw pass — see `Theme.resolving`.
        Theme.resolving(self) { paint(state) }
    }

    private func paint(_ state: State) {
        let onInk: Bool
        switch state {
        case .downloading: onInk = true
        default: onInk = false
        }
        layer?.backgroundColor = onInk ? Theme.Colour.selection.cgColor : NSColor.clear.cgColor
        name.textColor = onInk ? Theme.Colour.onSelection : Theme.Colour.tertiaryText
        detail.textColor =
            onInk
            ? Theme.Colour.onSelection.withAlphaComponent(0.7)
            : Theme.Colour.tertiaryText
        size.textColor =
            onInk
            ? Theme.Colour.onSelection.withAlphaComponent(0.6)
            : Theme.Colour.tertiaryText
        bar.isHidden = true
        actionButton.isHidden = true

        switch state {
        case .waiting:
            dot.layer?.backgroundColor = Theme.Colour.rule.cgColor
            detail.stringValue = "waiting"
        case .downloading(let done, let total, let rate):
            dot.layer?.backgroundColor = Theme.Colour.onInkAccent.cgColor
            name.textColor = Theme.Colour.onSelection
            bar.isHidden = false
            bar.doubleValue = total > 0 ? Double(done) / Double(total) : 0
            detail.stringValue =
                "\(Oilbird.humanBytes(done)) of \(Oilbird.humanBytes(total)) · \(rate)"
        case .verifying:
            dot.layer?.backgroundColor = Theme.Colour.accent.cgColor
            detail.stringValue = "checking the download is intact"
        case .installing:
            dot.layer?.backgroundColor = Theme.Colour.accent.cgColor
            detail.stringValue = "unpacking"
        case .checking(let note):
            dot.layer?.backgroundColor = Theme.Colour.changed.cgColor
            detail.stringValue = note
            detail.textColor = Theme.Colour.changed
        case .ready:
            dot.layer?.backgroundColor = Theme.Colour.clean.cgColor
            detail.stringValue = ""
            name.textColor = Theme.Colour.secondaryText
        case .failed(let reason, let action):
            // A failure is a row state, not a dialog: the rest of the list
            // stays visible, and there is always something to press.
            dot.layer?.backgroundColor = Theme.Colour.conflict.cgColor
            layer?.backgroundColor = Theme.Colour.conflict.withAlphaComponent(0.07).cgColor
            name.textColor = Theme.Colour.primaryText
            detail.stringValue = reason
            detail.textColor = Theme.Colour.conflict
            actionButton.title = action
            actionButton.isHidden = false
        }
    }
}
