import AppKit
import OilbirdKit
import OilbirdModel

/// The first thing anyone sees, and the longest they will look at Oilbird's
/// own design rather than SonarQube's.
///
/// One list, not a staged wizard: there are no choices to make here, only work,
/// and the list shows the shape of the job before it starts.
final class FirstRunWindowController: NSWindowController {
    private var rows: [Oilbird.DependencyID: DependencyRowView] = [:]
    private let stack = NSStackView()
    private let start = NSButton(title: "", target: nil, action: nil)
    private let cancel = NSButton(title: "Not now", target: nil, action: nil)
    private let bird = BirdView()
    var onFinished: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Oilbird"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.Colour.surface
        // Nothing pins an appearance: the palette follows the system (`Theme`).
        window.center()
        self.init(window: window)
        build()
    }

    private func build() {
        // `Theme.Ground` and not a layer colour assigned once: a `cgColor`
        // read here keeps the appearance current at launch, so toggling dark
        // mode leaves cream under the new text colour.
        let root = Theme.Ground(fill: { Theme.Colour.surface })

        // The mark, here as everywhere else: without it the first screen a new
        // user sees is the one that does not look like the app, and the only
        // sign of life is a button relabelling itself.
        bird.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bird.widthAnchor.constraint(equalToConstant: 44),
            bird.heightAnchor.constraint(equalToConstant: 44),
        ])

        let title = NSTextField(labelWithString: "Setting up")
        title.font = Theme.Font.title
        title.textColor = Theme.Colour.primaryText

        let heading = NSStackView(views: [bird, title])
        heading.orientation = .horizontal
        heading.spacing = 10
        heading.alignment = .centerY

        // A 1.14 GB download with no explanation is asking for a lot of trust.
        let why = NSTextField(
            wrappingLabelWithString: """
                Oilbird runs SonarQube privately on this Mac — a real server, not a hosted \
                service. These are the things it needs. Each comes from its official source, \
                and none of your code leaves this machine.
                """)
        why.font = Theme.Font.body
        why.textColor = Theme.Colour.secondaryText

        // ⚠ Read from the MANIFEST. A size literal here means a version bump
        // changes what Oilbird downloads and not what it says it downloads,
        // and a version string may live in exactly one place.

        // ⚠ And decimal throughout: 1,220,217,353 bytes is 1.14 GiB and 1.22
        // GB, so computing in one unit and labelling with the other is 7%
        // short in the sentence that must come before the first byte.
        let bytes = (try? Oilbird.firstRunBytes()) ?? 0
        let total = NSTextField(
            labelWithString: bytes > 0
                ? "\(Oilbird.humanBytes(bytes)) · once · resumes if you quit"
                : "downloaded once · resumes if you quit")
        total.font = Theme.Font.mono
        total.textColor = Theme.Colour.accent

        stack.orientation = .vertical
        stack.spacing = 1
        stack.alignment = .leading
        stack.distribution = .fill

        // Each row says what it is FOR. A row that cannot say that probably
        // should not be downloaded. The size beside it is the manifest's;
        // only the sentence is written here.
        let purposes: [(Oilbird.DependencyID, String)] = [
            (.sonarqube, "the analysis server, and the dashboard you read"),
            (.jdk, "SonarQube is a Java program"),
            (.postgres, "where your results are kept between scans"),
            (.scanner, "reads your code and reports what it finds"),
        ]
        let pinned = ((try? Oilbird.pinned()) ?? []).reduce(into: [String: Int64]()) {
            $0[$1.id] = $1.bytes
        }
        for (id, purpose) in purposes {
            let row = DependencyRowView(title: label(for: id), bytes: pinned[id.rawValue] ?? 0)
            row.toolTip = purpose
            rows[id] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let footer = NSTextField(labelWithString: "⌘L  log")
        footer.font = Theme.Font.mono
        footer.textColor = Theme.Colour.tertiaryText

        // Nothing moves until this is pressed: the size disclosure must
        // PRECEDE the first byte, and starting on launch makes them
        // simultaneous, which is a notification.
        start.title = "Download and set up"
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        start.target = self
        start.action = #selector(beginPressed)

        // Sheet rule: escape leftmost, the answer rightmost.
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelPressed)

        let buttons = NSStackView(views: [cancel, start])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        for view in [heading, why, total, stack, footer, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            why.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 9),
            why.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            why.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            total.topAnchor.constraint(equalTo: why.bottomAnchor, constant: 11),
            total.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            stack.topAnchor.constraint(equalTo: total.bottomAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        window?.contentView = root
    }

    private func label(for id: Oilbird.DependencyID) -> String {
        switch id {
        case .sonarqube: "SonarQube"
        case .jdk: "Java runtime"
        case .postgres: "PostgreSQL"
        case .scanner: "Scanner"
        }
    }

    @objc private func cancelPressed() { window?.close() }

    @objc private func beginPressed() {
        start.isEnabled = false
        start.title = "Setting up…"
        // Something is downloading a gigabyte; the window should look alive
        // for the several minutes that takes.
        bird.isCalling = true
        begin()
    }

    /// Provisioning is Kit's; this only paints it.
    func begin() {
        Task { @MainActor in
            do {
                try await Oilbird.install { id, done, total in
                    Task { @MainActor in
                        self.rows[id]?.apply(
                            .downloading(done: done, total: total, rate: ""))
                    }
                }
                for row in rows.values { row.apply(.ready) }
                onFinished?()
            } catch let error as Oilbird.Error {
                showFailure(error)
            } catch {
                Oilbird.record(error)
                show(reason: "Something went wrong.", action: "Try again") {
                    [weak self] in self?.begin()
                }
            }
        }
    }

    // MARK: what a failed setup offers

    // ⚠ Every arm picks the WORDS and the ACT together, or a button reading
    // "Remove it yourself first" only re-downloads: a dead end.

    private func showFailure(_ error: Oilbird.Error) {
        // Written to the log here, as the main window does: `underlying` holds
        // the exit code and is never shown, so an unrecorded failure leaves
        // "Show log" pointing at a log that does not mention it.
        Oilbird.record(error)
        switch error.recovery {
        case .retry(let offered) where offered == MainWindowController.logLabel:
            // "Show log" is not "try again", and the situations that raise
            // it are the ones where trying again changes nothing.
            show(reason: error.detail, action: offered) { [weak self] in
                (NSApp.delegate as? AppDelegate)?.showLog()
                self?.show(
                    reason: "The log is selected in Finder.", action: "Try again"
                ) { [weak self] in self?.begin() }
            }

        case .retry(let offered), .chooseAlternative(let offered):
            show(reason: error.detail, action: offered) { [weak self] in self?.begin() }

        case .freeSpace(let needed, let available):
            // Oilbird does not tidy a disk it does not own, so the
            // numbers go in the words and the button is the honest half.
            show(
                reason: "\(error.detail) Needs \(Oilbird.humanBytes(needed)); "
                    + "\(Oilbird.humanBytes(available)) free.",
                action: "Try again"
            ) { [weak self] in self?.begin() }

        case .reinstall:
            // `install` fetches whatever is still missing, which is what
            // "Reinstall" means from a window that has never finished one.
            show(reason: error.detail, action: "Reinstall") { [weak self] in self?.begin() }

        case .waitForHolder(let pid, _):
            show(reason: "\(error.detail) Another Oilbird (\(pid)) has it open.", action: "Wait") {
                [weak self] in
                self?.show(reason: "Waiting for the other Oilbird.", action: "Try again") {
                    [weak self] in self?.begin()
                }
            }

        case .reportIssue(let instruction):
            // An instruction to the user is not a button. It is said in the
            // reason, and the button is the act that does exist.
            show(
                reason: instruction == MainWindowController.reportLabel
                    ? error.detail : "\(error.detail) \(instruction).",
                action: MainWindowController.reportLabel
            ) { (NSApp.delegate as? AppDelegate)?.reportIssue() }
        }
    }

    /// A failure is a row state, never a modal. The rest of the list stays
    /// visible and there is always something to press.
    private func show(reason: String, action: String, press: @escaping () -> Void) {
        start.isEnabled = true
        start.title = "Download and set up"
        bird.isCalling = false
        for row in rows.values {
            row.apply(.failed(reason: reason, action: action))
            row.onAction = press
        }
    }
}
