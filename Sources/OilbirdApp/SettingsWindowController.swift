import AppKit
import OilbirdKit

/// Settings.
///
/// ⚠ **It was 211 lines offering an idle interval and one button**, and that
/// was downstream of the real gap: `Preferences.Stored` held two fields, so
/// two things were all a settings window could show. Everything else Oilbird
/// decided, it decided silently — which ports it took, how much memory it
/// gave the server, what it refuses to analyse, where 3.4 GB went, which
/// versions are actually installed, and how an agent is meant to reach it at
/// all.
///
/// Six panes, in the sidebar-and-cards format. Half of them are read-only
/// and that is the decision, not an omission: this is where a person looks when they
/// want to know what the app is doing, and that question must be
/// answerable without the CLI.
///
/// Every switch here governs code that already exists. Nothing sets a
/// field nobody reads.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var paneViews: [NSScrollView] = []
    private var sidebarRows: [SettingsSidebarRow] = []
    /// Which pane is on screen, so `selectPane` can tell a real move from
    /// the many times it is called about the pane already showing.
    private var chosen: Int?
    private var paneSections: [[SettingsSection]] = []
    private let search = NSSearchField()
    private let paneHeading = NSTextField(labelWithString: "")

    /// The panes that show live facts rather than stored ones, rebuilt on a
    /// timer while they are on screen.
    ///
    /// ⚠ Rebuilt rather than left: "what is running right now" was the
    /// point of the Engine pane, and a pid and an uptime frozen at the
    /// moment the window opened would be the same defect the main window's
    /// pill had — a value written once and never read back.
    private var liveHosts: [Int: NSView] = [:]
    private var tick: Timer?

    /// What the last action said about itself, per pane, so a refusal is
    /// visible where the control that was refused is, and so an
    /// action that worked says so where it was pressed.
    ///
    /// ⚠ Both, not only the failures. Reclaim frees a gigabyte and the only
    /// visible effect is a table of numbers going down — easy to miss and
    /// impossible to be sure of. A button whose success is invisible is a
    /// button people press twice.
    private var problems: [Int: String] = [:]
    private var notices: [Int: String] = [:]

    private enum Pane: Int, CaseIterable {
        case general, engine, scanning, agents, storage, versions

        var title: String {
            switch self {
            case .general: "General"
            case .engine: "Engine"
            case .scanning: "Scanning"
            case .agents: "Agents"
            case .storage: "Storage"
            case .versions: "Versions"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .engine: "bolt"
            case .scanning: "folder"
            case .agents: "terminal"
            case .storage: "internaldrive"
            case .versions: "shippingbox"
            }
        }
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: SettingsLayout.windowWidth + SettingsLayout.sidebarWidth,
                height: SettingsLayout.windowHeight),
            // ⚠ NOT `.resizable`: pane content is pinned to
            // `SettingsLayout.windowWidth`, so dragging wider stretches the
            // frame and leaves the cards behind.
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // ⚠ Hidden: the pane's name is the heading, and a window title cannot
        // do that job because macOS centres it over the whole window, where it
        // straddles the sidebar divider. Still SET, for the Window menu.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.Colour.surface
        window.minSize = NSSize(
            width: SettingsLayout.windowWidth + SettingsLayout.sidebarWidth,
            height: SettingsLayout.minimumHeight)
        // ⚠ The key view loop is computed ONCE unless a window recomputes it,
        // and this one rebuilds its pane on every change: without this, every
        // switch and stepper is outside the loop and unreachable by keyboard.
        window.autorecalculatesKeyViewLoop = true
        window.center()
        self.init(window: window)
        window.delegate = self
        build()
    }

    func present() {
        rebuild()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Two seconds: the pid and the uptime are the point of the Engine
        // pane, and a number that is a minute old there is worse than no
        // number because it looks current.
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        tick?.invalidate()
        tick = nil
    }

    // MARK: the frame

    private func build() {
        guard let container = window?.contentView else { return }

        let ground = Theme.Ground(fill: { Theme.Colour.surface })
        let sidebarGround = Theme.Ground(fill: { Theme.Colour.sunken })
        let rule = Theme.Ground(fill: { Theme.Colour.rule })

        search.placeholderString = "Search"
        search.focusRingType = .none
        search.target = self
        search.action = #selector(searchSettings)
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(
            equalToConstant: SettingsLayout.sidebarWidth - SettingsLayout.sidebarInset * 2
        ).isActive = true

        var scrolls: [NSScrollView] = []
        for pane in Pane.allCases {
            let host = SettingsDesign.FlippedHost()
            host.translatesAutoresizingMaskIntoConstraints = false
            liveHosts[pane.rawValue] = host

            let scroll = NSScrollView()
            scroll.documentView = host
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.scrollerStyle = .overlay
            scroll.translatesAutoresizingMaskIntoConstraints = false
            host.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
            scrolls.append(scroll)

            let row = SettingsSidebarRow(
                title: pane.title, symbol: pane.symbol, index: pane.rawValue
            ) { [weak self] wanted in self?.selectPane(wanted) }
            sidebarRows.append(row)
            paneSections.append([])
        }
        paneViews = scrolls

        let sidebar = NSStackView(views: [search] + sidebarRows)
        sidebar.setCustomSpacing(SettingsLayout.sidebarSearchGap, after: search)
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = SettingsLayout.sidebarRowGap
        sidebar.edgeInsets = NSEdgeInsets(
            top: SettingsLayout.titlebarClearance, left: SettingsLayout.sidebarInset,
            bottom: SettingsLayout.sidebarBottom, right: SettingsLayout.sidebarInset)

        paneHeading.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        paneHeading.textColor = Theme.Colour.primaryText

        let footer = makeFooter()
        // The heading last, so nothing is drawn over it: the scroll views
        // start at `titlebarClearance` and do not overlap the band, but an
        // overlay scroller reaching up into it would.
        for view in [ground, sidebarGround, rule, sidebar, footer] + scrolls + [paneHeading] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: container.topAnchor),
            ground.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            sidebarGround.topAnchor.constraint(equalTo: container.topAnchor),
            sidebarGround.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebarGround.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebarGround.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),

            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SettingsLayout.sidebarWidth),

            rule.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            rule.topAnchor.constraint(equalTo: container.topAnchor),
            rule.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 1),

            paneHeading.leadingAnchor.constraint(
                equalTo: rule.trailingAnchor, constant: SettingsLayout.margin),
            paneHeading.centerYAnchor.constraint(
                equalTo: container.topAnchor,
                constant: SettingsLayout.titlebarClearance / 2),

            footer.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        for scroll in scrolls {
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
                scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scroll.topAnchor.constraint(
                    equalTo: container.topAnchor,
                    constant: SettingsLayout.titlebarClearance),
                scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            ])
        }
        rebuild()
        selectPane(0)
    }

    private func makeFooter() -> NSView {
        let log = NSButton(title: "Open the Log", target: self, action: #selector(openLog))
        log.bezelStyle = .rounded
        let reveal = NSButton(
            title: "Reveal Settings File", target: self, action: #selector(revealPreferences))
        reveal.bezelStyle = .rounded
        let spacer = NSView()
        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        // ⚠ The default button paints itself in the SYSTEM accent, which is
        // the last blue left in a window that draws everything else itself.
        done.bezelColor = Theme.Colour.accent

        let stack = NSStackView(views: [log, reveal, spacer, done])
        stack.orientation = .horizontal
        stack.spacing = SettingsLayout.footerGap
        stack.edgeInsets = NSEdgeInsets(
            top: SettingsLayout.footerTop, left: SettingsLayout.margin,
            bottom: SettingsLayout.footerBottom, right: SettingsLayout.margin)
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return stack
    }

    /// One titled group: a small-caps heading, a card, and an optional
    /// sentence under it.
    ///
    /// The whole group is what a search hides — hiding single rows leaves a
    /// heading over nothing.
    private func section(_ title: String, _ body: NSView, footnote: String? = nil) -> NSView {
        var views: [NSView] = [SettingsDesign.sectionTitle(title), body]
        if let footnote { views.append(SettingsDesign.footnote(footnote)) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsLayout.titleGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(
            equalToConstant: SettingsLayout.windowWidth - SettingsLayout.margin * 2
        ).isActive = true

        let section = SettingsSection()
        section.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: section.topAnchor),
            stack.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])
        section.searchText =
            ([title.lowercased(), footnote?.lowercased() ?? ""] + Self.rowTexts(in: body))
            .joined(separator: " ")
        return section
    }

    /// Every row label and explanation under a card, so the search index is
    /// literally what is on screen.
    private static func rowTexts(in view: NSView) -> [String] {
        if let row = view as? SettingsRow { return [row.searchText] }
        return view.subviews.flatMap { rowTexts(in: $0) }
    }

    // MARK: rebuilding

    /// Rebuilds every pane from the current state of the world.
    ///
    /// Whole panes rather than mutated controls. Half of what is here is
    /// read from disk or from the kernel — a pid, a byte count, a symlink's
    /// target — and keeping a control in step with each would be the nine
    /// write-sites-and-no-reads problem the main window's pill had. A pane
    /// is thirty views; rebuilding one is free and cannot go stale.
    private func rebuild() {
        let settings = Oilbird.settings()
        let built: [Pane: [NSView]] = [
            .general: generalPane(settings),
            .engine: enginePane(settings),
            .scanning: scanningPane(settings),
            .agents: agentsPane(),
            .storage: storagePane(),
            .versions: versionsPane(),
        ]
        for pane in Pane.allCases {
            let cards = built[pane] ?? []
            paneSections[pane.rawValue] = cards.compactMap { $0 as? SettingsSection }
            guard let host = liveHosts[pane.rawValue] else { continue }
            host.subviews.forEach { $0.removeFromSuperview() }

            let stack = NSStackView(views: cards)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = SettingsLayout.sectionSpacing
            stack.edgeInsets = NSEdgeInsets(
                top: SettingsLayout.contentTopGap, left: SettingsLayout.margin,
                bottom: SettingsLayout.margin, right: SettingsLayout.margin)
            stack.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: host.topAnchor),
                stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        searchSettings()
    }

    /// The Engine pane only, on the timer — rebuilding all six two times a
    /// second would fight the user for the scroll position of the one they
    /// are reading.
    private func refreshLive() {
        guard let window, window.isVisible,
            sidebarRows.indices.contains(Pane.engine.rawValue),
            sidebarRows[Pane.engine.rawValue].isChosen
        else { return }
        rebuild()
    }

    // MARK: actions

    private func apply(_ pane: Pane, _ change: (inout Oilbird.Settings) -> Void) {
        problems[pane.rawValue] = nil
        notices[pane.rawValue] = nil
        do {
            try Oilbird.updateSettings(change)
        } catch {
            Oilbird.record(error)
            problems[pane.rawValue] = "That could not be saved: \(error)"
        }
        rebuild()
    }

    @objc private func toggleMenuBarIcon(_ sender: PaperSwitch) {
        apply(.general) { $0.menuBarIcon = sender.on }
        (NSApp.delegate as? AppDelegate)?.settingsChanged()
    }

    /// ⚠ Applied through the delegate now, and it used to say there was
    /// nothing to apply. That was true while this switch decided only what
    /// closing the last window did, which is asked at the moment it
    /// happens. It now also decides what the menu bar item offers as an
    /// ending, and that menu is built rather than asked. (The app menu asks
    /// for itself when it opens — `AppDelegate.menuNeedsUpdate`.) `rebuild`
    /// still redraws the row's own explanation and the note under it.
    @objc private func toggleResident(_ sender: PaperSwitch) {
        apply(.general) { $0.stayResident = sender.on }
        (NSApp.delegate as? AppDelegate)?.settingsChanged()
    }

    /// ⚠ Applied through the delegate, like the menu bar icon: the
    /// appearance belongs to the application, not to this window, and
    /// setting it here would leave the main window and the dashboard in it
    /// wearing the old one until something else touched them.
    @objc private func changeAppearance(_ sender: PaperSegmented) {
        let choices = Oilbird.Appearance.choices
        guard choices.indices.contains(sender.selectedSegment) else { return }
        apply(.general) { $0.appearance = choices[sender.selectedSegment] }
        (NSApp.delegate as? AppDelegate)?.settingsChanged()
    }

    @objc private func toggleLogin(_ sender: PaperSwitch) {
        problems[Pane.general.rawValue] = nil
        do {
            try Oilbird.setLoginItem(sender.on)
        } catch let error as Oilbird.Error {
            problems[Pane.general.rawValue] = "\(error.detail) \(error.recovery.actionLabel)."
        } catch {
            Oilbird.record(error)
            problems[Pane.general.rawValue] = "That could not be changed: \(error)"
        }
        rebuild()
    }

    @objc private func toggleNever(_ sender: PaperSwitch) {
        saveIdle(sender.on ? .never : .after(minutes: 30))
    }

    @objc private func steppedMinutes(_ sender: NSStepper) {
        saveIdle(.after(minutes: sender.integerValue))
    }

    @objc private func editedMinutes(_ sender: NSTextField) {
        // Clamped rather than refused: a typed value below the floor is a
        // slip, not a request. The CLI refuses because there a value is a
        // command; here it is a control being dragged.
        saveIdle(
            .after(minutes: max(Oilbird.IdleTimeout.floorMinutes, sender.integerValue)))
    }

    private func saveIdle(_ choice: Oilbird.IdleTimeout) {
        problems[Pane.engine.rawValue] = nil
        do {
            try Oilbird.setIdleTimeout(choice)
        } catch {
            Oilbird.record(error)
            problems[Pane.engine.rawValue] = "That could not be saved: \(error)"
        }
        // Takes effect now, not at next launch: switching away from "never"
        // has to start watching something that is already running.
        Oilbird.ensureWatching()
        rebuild()
    }

    @objc private func changeMemory(_ sender: PaperSegmented) {
        let choices = Oilbird.WebMemory.choices
        guard choices.indices.contains(sender.selectedSegment) else { return }
        apply(.engine) { $0.webMemoryMegabytes = choices[sender.selectedSegment] }
    }

    @objc private func togglePinnedPort(_ sender: PaperSwitch) {
        // Pins whatever it is on now, which is the only port a person could
        // mean: the one their bookmark or their agent's URL already has.
        let current = Oilbird.engineDetail()?.webPort ?? Oilbird.settings().lastPorts?.web
        apply(.engine) { $0.pinnedWebPort = sender.on ? current : nil }
        if sender.on, current == nil {
            problems[Pane.engine.rawValue] =
                "There is no port to keep yet. Start the engine once, then turn this on."
            rebuild()
        }
    }

    @objc private func editedExclusions(_ sender: NSTextField) {
        apply(.scanning) { $0.neverAnalysed = Self.globs(sender.stringValue) }
    }

    @objc private func editedTests(_ sender: NSTextField) {
        apply(.scanning) { $0.treatedAsTests = Self.globs(sender.stringValue) }
    }

    /// A comma-separated list as a person types it, blanks dropped.
    static func globs(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// ⚠ **The whole of this used to be `try?`, on both branches.** On a
    /// stock Mac `/usr/local/bin` is `root:wheel`, so the symlink fails with
    /// EACCES and `CommandLineTool.install` raises a written sentence saying
    /// exactly that — which was discarded. Pressing Install did nothing at
    /// all: no sheet, no error, no link, no way to find out why.
    @objc private func toggleCLI() {
        problems[Pane.agents.rawValue] = nil
        do {
            switch Oilbird.cliState() {
            case .installed: try Oilbird.uninstallCLI()
            case .absent, .dangling: try Oilbird.installCLI()
            case .foreign: break
            }
        } catch let error as Oilbird.Error {
            report(error.detail, instruction: error.recovery.actionLabel)
        } catch {
            Oilbird.record(error)
            report("The command line tool could not be changed.", instruction: "\(error)")
        }
        rebuild()
    }

    /// Says what happened, and gives the user the one line that works.
    ///
    /// The recovery here is an instruction rather than a control — "It may
    /// need an administrator" is not something Oilbird can press on the
    /// user's behalf, and it must not: Oilbird may offer to put its own
    /// CLI on `PATH` when asked, not ask for root.
    private func report(_ what: String, instruction: String) {
        let command = Oilbird.manualCLIInstall
        problems[Pane.agents.rawValue] = "\(what) \(instruction)."
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = """
            \(instruction).

            You can make the link yourself from a terminal:

            \(command)
            """
        alert.addButton(withTitle: "Copy the command")
        alert.addButton(withTitle: "OK")
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { copy(command) }
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.copy(command)
        }
    }

    @objc private func copySnippet(_ sender: NSButton) {
        guard let snippet = Oilbird.mcpClientSnippet() else { return }
        copy(snippet)
        sender.title = "Copied"
    }

    @objc private func copyCommandLine(_ sender: NSButton) {
        guard let command = Oilbird.mcpCommandLine() else { return }
        copy(command)
        sender.title = "Copied"
    }

    @objc private func openDashboard() {
        guard let url = Oilbird.dashboardURL() else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealState() { reveal(Oilbird.diskReport().stateRoot) }
    @objc private func revealCache() { reveal(Oilbird.diskReport().cacheRoot) }
    @objc private func openLog() { reveal(Oilbird.logPath) }
    @objc private func revealPreferences() { reveal(Oilbird.settingsFilePath) }

    /// ⚠ Creates the directory first when it is one of Oilbird's own roots.
    /// Reveal on a path that does not exist yet opens nothing at all, with
    /// no error — a dead end on the commonest state of a fresh install.
    private func reveal(_ path: String) {
        let url = URL(filePath: path)
        if !FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func reclaimSpace() {
        problems[Pane.storage.rawValue] = nil
        notices[Pane.storage.rawValue] = nil
        do {
            let freed = try Oilbird.reclaim()
            notices[Pane.storage.rawValue] =
                freed > 0
                ? "Freed \(Oilbird.humanBytes(freed))."
                : "There was nothing left to reclaim."
        } catch let error as Oilbird.Error {
            problems[Pane.storage.rawValue] = "\(error.detail) \(error.recovery.actionLabel)."
        } catch {
            Oilbird.record(error)
            problems[Pane.storage.rawValue] = "Nothing could be reclaimed: \(error)"
        }
        rebuild()
    }

    private func warningCard(_ text: String) -> NSView { loose(SettingsDesign.warning(text)) }

    private func noticeCard(_ text: String) -> NSView { loose(SettingsDesign.footnote(text)) }

    /// A sentence on its own, in the column the cards occupy — a refusal, or
    /// the receipt for something that worked.
    private func loose(_ label: NSTextField) -> NSView {
        let section = SettingsSection()
        label.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: section.topAnchor),
            label.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            label.bottomAnchor.constraint(equalTo: section.bottomAnchor),
            label.widthAnchor.constraint(
                equalToConstant: SettingsLayout.windowWidth - SettingsLayout.margin * 2),
        ])
        section.searchText = label.stringValue.lowercased()
        return section
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func closeWindow() { window?.close() }
}

/// The panes, one method each, in the order the window shows them.
///
/// ⚠ An extension in the same file. It groups rather than shrinks: the file
/// is the same length, and the controller's `private` members stay reachable,
/// which they would not be across files. What it makes visible is that each
/// pane is a separable piece of this window, which the MARKs already said
/// and nothing enforced.
extension SettingsWindowController {
    // MARK: General

    private func generalPane(_ settings: Oilbird.Settings) -> [NSView] {
        let login = Oilbird.loginItemState()
        let loginSwitch = PaperSwitch(
            on: login.isOn, target: self, action: #selector(toggleLogin(_:)))
        loginSwitch.isEnabled = login != .unavailable

        let appearances = Oilbird.Appearance.choices
        let residency = Oilbird.residency(settings)
        var cards: [NSView] = [
            section(
                "Appearance",
                SettingsDesign.card([
                    SettingsDesign.row(
                        "Light or dark",
                        detail: "Auto follows the Mac. The dashboard changes with the "
                            + "rest of Oilbird — it is one choice, not two.",
                        control: PaperSegmented(
                            labels: appearances.map(\.label),
                            selected: appearances.firstIndex(of: settings.appearance) ?? 0,
                            target: self, action: #selector(changeAppearance(_:))))
                ])),
            section(
                "Oilbird",
                SettingsDesign.card([
                    SettingsDesign.row(
                        "Show the menu bar icon",
                        detail: "The bird sits beside the clock and says what the engine "
                            + "is doing without a window open.",
                        control: PaperSwitch(
                            on: settings.menuBarIcon, target: self,
                            action: #selector(toggleMenuBarIcon(_:)))),
                    SettingsDesign.row(
                        "Keep Oilbird running when you close it",
                        detail: residency.explanation,
                        control: PaperSwitch(
                            on: settings.stayResident, target: self,
                            action: #selector(toggleResident(_:)))),
                    SettingsDesign.row(
                        "Open Oilbird at login",
                        detail: loginDetail(login),
                        control: loginSwitch),
                ]),
                footnote: "Opening Oilbird does not start the analysis engine. Nothing "
                    + "downloads or runs until you ask for something that needs it."),
        ]
        // ⚠ A note, not a warning: the combination is legitimate.
        // `Oilbird.residency` decides both whether there is anything to say
        // and what, because "no dead end" over these two switches is asserted there.
        if let note = residency.note { cards.append(noticeCard(note)) }
        if let problem = problems[Pane.general.rawValue] {
            cards.append(warningCard(problem))
        }
        return cards
    }

    /// ⚠ Not "Nothing Oilbird installs starts at login." as a statement of
    /// fact: it is a choice, and what the row says depends on whether macOS
    /// will let it be made.
    private func loginDetail(_ state: Oilbird.LoginItemState) -> String {
        switch state {
        case .on, .off:
            return "The engine still waits until something needs it."
        case .refusedBySystem:
            return "Turned off in System Settings, General, Login Items. "
                + "It has to be turned back on there."
        case .unavailable:
            return "Only an installed Oilbird can be a login item; this one is "
                + "running from a build directory."
        }
    }

    // MARK: Engine

    private func enginePane(_ settings: Oilbird.Settings) -> [NSView] {
        var cards: [NSView] = []

        let never = Oilbird.idleTimeout() == .never
        let minutes: Int
        if case .after(let value) = Oilbird.idleTimeout() { minutes = value } else { minutes = 30 }

        cards.append(
            section(
                "Pausing",
                SettingsDesign.card([
                    SettingsDesign.row(
                        "Pause when unused",
                        detail: "The engine is four Java processes and a database, about "
                            + "1.6 GB. Oilbird itself stays open either way.",
                        control: minutesControl(minutes: minutes, enabled: !never)),
                    SettingsDesign.row(
                        "Never — leave it running",
                        control: PaperSwitch(
                            on: never, target: self, action: #selector(toggleNever(_:)))),
                ]),
                footnote: never
                    ? "The engine stays up until you pause it or restart your Mac."
                    : "Five minutes is the shortest Oilbird accepts. A warm start takes "
                        + "about fifteen seconds, so anything shorter stops the engine "
                        + "between your own clicks and you pay that wait again."))

        let chosen = settings.webMemoryMegabytes ?? Oilbird.WebMemory.defaultMegabytes
        let index = Oilbird.WebMemory.choices.firstIndex(of: chosen) ?? 0
        cards.append(
            section(
                "Memory",
                SettingsDesign.card([
                    SettingsDesign.row(
                        "Heap for the analysis server",
                        detail: "512 MB is SonarQube's own default, and it is where a "
                            + "large report has run out before.",
                        control: PaperSegmented(
                            labels: Oilbird.WebMemory.choices.map(memoryLabel),
                            selected: index, target: self, action: #selector(changeMemory(_:))))
                ]),
                footnote: "Takes effect the next time the engine starts."))

        var portRows: [NSView] = []
        if let detail = Oilbird.engineDetail() {
            portRows.append(
                SettingsDesign.reading("Dashboard", "127.0.0.1:\(detail.webPort)"))
            portRows.append(
                SettingsDesign.reading("Database", "127.0.0.1:\(detail.databasePort)"))
        } else if let remembered = settings.lastPorts {
            portRows.append(
                SettingsDesign.reading(
                    "Dashboard", "\(remembered.web)", detail: "The port it used last time."))
        } else {
            portRows.append(
                SettingsDesign.row(
                    "Dashboard", detail: "Chosen when the engine first starts.",
                    control: nil))
        }
        portRows.append(
            SettingsDesign.row(
                "Keep the same dashboard port",
                detail: "For anything that has the URL written down. If something else "
                    + "has taken it, Oilbird still starts, on another port.",
                control: PaperSwitch(
                    on: settings.pinnedWebPort != nil, target: self,
                    action: #selector(togglePinnedPort(_:)))))
        cards.append(
            section(
                "Ports", SettingsDesign.card(portRows),
                footnote: "Oilbird asks the operating system for a free port rather than "
                    + "claiming 9000, which php-fpm and MinIO also want."))

        cards.append(section("Right now", SettingsDesign.card(runningRows())))
        if let problem = problems[Pane.engine.rawValue] { cards.append(warningCard(problem)) }
        return cards
    }

    private func memoryLabel(_ megabytes: Int) -> String {
        megabytes >= 1024 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    private func runningRows() -> [NSView] {
        guard let detail = Oilbird.engineDetail() else {
            return [
                SettingsDesign.row(
                    "The engine is not running",
                    detail: "It starts when something needs it — a scan, the dashboard, "
                        + "or an agent asking a question.",
                    control: nil)
            ]
        }
        var rows: [NSView] = [
            SettingsDesign.reading("Process", "\(detail.pid)"),
            SettingsDesign.reading("Processes in the group", "\(detail.processes)"),
            SettingsDesign.reading("Up for", detail.uptimeLabel),
        ]
        if let resident = detail.residentBytes {
            rows.append(SettingsDesign.reading("Memory", Oilbird.humanBytes(resident)))
        }
        return rows
    }

    private func minutesControl(minutes: Int, enabled: Bool) -> NSView {
        let field = NSTextField()
        field.font = Theme.Font.mono
        field.alignment = .right
        field.integerValue = minutes
        field.isEnabled = enabled
        field.target = self
        field.action = #selector(editedMinutes(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(
            equalToConstant: SettingsLayout.minutesWidth
        ).isActive = true

        let stepper = NSStepper()
        stepper.minValue = Double(Oilbird.IdleTimeout.floorMinutes)
        stepper.maxValue = 1440
        stepper.increment = 5
        stepper.valueWraps = false
        stepper.integerValue = minutes
        stepper.isEnabled = enabled
        stepper.target = self
        stepper.action = #selector(steppedMinutes(_:))

        let unit = NSTextField(labelWithString: "min")
        unit.font = Theme.Font.meta
        unit.textColor = enabled ? Theme.Colour.secondaryText : Theme.Colour.tertiaryText

        let stack = NSStackView(views: [field, stepper, unit])
        stack.orientation = .horizontal
        stack.spacing = SettingsLayout.minutesGap
        stack.alignment = .centerY
        return stack
    }

    // MARK: Scanning

    private func scanningPane(_ settings: Oilbird.Settings) -> [NSView] {
        let naming = Oilbird.namingExample()
        var cards: [NSView] = [
            section(
                "Never analysed",
                SettingsDesign.card([
                    SettingsDesign.row(
                        "Skip these",
                        detail: "Comma-separated. Delete anything you disagree with.",
                        control: globField(
                            settings.neverAnalysed, example: "**/node_modules/**",
                            action: #selector(editedExclusions(_:)))),
                    SettingsDesign.row(
                        "Oilbird's suggestion",
                        detail: Oilbird.usingSuggestedScope
                            ? "This is what you have." : "Replaces what is above.",
                        control: restoreButton()),
                ]),
                footnote: "Oilbird suggests a list on a first run and then leaves it "
                    + "alone — it is yours, including empty. It is only a suggestion "
                    + "because it cannot be true everywhere: SonarQube skips vendor/ "
                    + "for Go, PHP and Ruby and for nothing else, because the word "
                    + "means something in those languages and nothing in Java. "
                    + "A repository with node_modules in it took twenty minutes and "
                    + "failed before anything was skipped, which is why the suggestion "
                    + "exists at all."),
            section(
                "Treated as tests",
                SettingsDesign.card([
                    SettingsDesign.row(
                        "Score these as test code",
                        detail: "Comma-separated. Delete anything you disagree with.",
                        control: globField(
                            settings.treatedAsTests, example: "**/*.spec.*",
                            action: #selector(editedTests(_:))))
                ]),
                footnote: "Test code is still analysed. It is scored against different "
                    + "rules, which is why an incomplete assertion in a spec file is not "
                    + "reported as a blocker in your product."),
            section(
                "How a folder becomes a project",
                SettingsDesign.card([
                    SettingsDesign.reading("A folder called", naming.folderName),
                    SettingsDesign.reading("is stored as", naming.key),
                    SettingsDesign.reading("and reads as", naming.name),
                ]),
                footnote: "The stored key carries a hash of the full path, so two "
                    + "checkouts of one repository keep separate histories, and it is "
                    + "reduced to plain ASCII because SonarQube will not accept anything "
                    + "else in a key. The name you see is the folder, untouched."),
        ]
        if let problem = problems[Pane.scanning.rawValue] { cards.append(warningCard(problem)) }
        return cards
    }

    /// - Parameter example: a pattern of the kind THIS field takes. Both
    ///   fields showed the same one until it became a parameter, and a
    ///   placeholder suggesting the wrong answer is worse than an empty box.
    /// Disabled when the lists already are the suggestion, so the button
    /// never offers to do nothing.
    private func restoreButton() -> NSButton {
        let button = NSButton(
            title: "Restore", target: self, action: #selector(restoreScope))
        button.bezelStyle = .rounded
        button.isEnabled = !Oilbird.usingSuggestedScope
        return button
    }

    @objc private func restoreScope() {
        apply(.scanning) {
            $0.neverAnalysed = Oilbird.suggestedNeverAnalysed
            $0.treatedAsTests = Oilbird.suggestedTreatedAsTests
        }
    }

    private func globField(_ patterns: [String], example: String, action: Selector) -> NSView {
        let field = NSTextField()
        field.font = Theme.Font.mono
        field.stringValue = patterns.joined(separator: ", ")
        field.placeholderString = example
        field.target = self
        field.action = action
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: SettingsLayout.entryWidth).isActive = true
        return field
    }

    // MARK: Agents

    private func agentsPane() -> [NSView] {
        let cli = Oilbird.cliState()
        let cliButton = NSButton(title: cliTitle(cli), target: self, action: #selector(toggleCLI))
        cliButton.bezelStyle = .rounded
        if case .foreign = cli { cliButton.isEnabled = false }

        var cards: [NSView] = [
            section(
                "The command line tool",
                SettingsDesign.card([
                    SettingsDesign.row(
                        "oilbird on your PATH",
                        detail: cliDetail(cli),
                        path: cliPath(cli),
                        control: cliButton)
                ]),
                footnote: "Everything the window does, the command line does too — scan, "
                    + "status, doctor, issues. It needs an administrator to write into "
                    + "/usr/local/bin, and Oilbird will say so rather than fail quietly.")
        ]

        if let snippet = Oilbird.mcpClientSnippet(), let binary = Oilbird.mcpBinary(),
            let command = Oilbird.mcpCommandLine()
        {
            let copyCommand = NSButton(
                title: "Copy", target: self, action: #selector(copyCommandLine(_:)))
            copyCommand.bezelStyle = .rounded
            let copy = NSButton(
                title: "Copy", target: self, action: #selector(copySnippet(_:)))
            copy.bezelStyle = .rounded
            cards.append(
                section(
                    "The MCP server",
                    SettingsDesign.card(
                        // ⚠ Above the snippet, not below it. The warning
                        // exists because the path was pasted before anyone
                        // read past it.
                        (Oilbird.mcpSnippetWarning().map {
                            [SettingsDesign.noticeRow($0)]
                        } ?? [])
                            + [
                                // ⚠ Claude Code first: it is the likeliest
                                // client of a developer tool and it does not
                                // take the JSON form at all.
                                SettingsDesign.blockRow(
                                    "In Claude Code, run this", text: command,
                                    control: copyCommand),
                                // ⚠ The other route names the FILE: "paste
                                // this into your client" names neither, and
                                // the file is what cannot be guessed.
                                SettingsDesign.blockRow(
                                    "In Claude Desktop, merge this into\n"
                                        + Oilbird.mcpConfigPath,
                                    text: snippet, control: copy),
                                // The same file the snippet names, in the form
                                // a person reads. `mcpClientSnippet` says why
                                // the two differ.
                                SettingsDesign.row("Server", path: binary.path),
                            ]),
                    footnote: "\(Oilbird.mcpToolNames.count) tools — scan a project, list "
                        + "issues, read the quality gate, ask what is running. Each starts "
                        + "the engine only if it needs it, so a connected editor does not "
                        + "hold 1.6 GB open all day.\n\nMERGE rather than replace: if that "
                        + "file already has servers in it, add this one beside them. "
                        + "Claude Desktop reads it once at launch, so quit and reopen it; "
                        + "Claude Code picks the server up straight away."))
        } else {
            cards.append(
                section(
                    "The MCP server",
                    SettingsDesign.card([
                        SettingsDesign.row(
                            "Not in this build",
                            detail: "The server ships inside the application bundle. This "
                                + "Oilbird is running from a build directory, so there is "
                                + "no path worth pasting anywhere.",
                            control: nil)
                    ])))
        }

        let open = NSButton(
            title: "Open in Browser", target: self, action: #selector(openDashboard))
        open.bezelStyle = .rounded
        open.isEnabled = Oilbird.dashboardURL() != nil
        cards.append(
            section(
                "The dashboard",
                SettingsDesign.card([
                    SettingsDesign.row(
                        "SonarQube in your own browser",
                        detail: Oilbird.dashboardURL().map { "Running at \($0.absoluteString)" }
                            ?? "There is nothing to open until the engine is running.",
                        control: open)
                ])))
        if let problem = problems[Pane.agents.rawValue] { cards.append(warningCard(problem)) }
        return cards
    }

    private func cliTitle(_ state: Oilbird.CLIState) -> String {
        switch state {
        case .installed: "Remove"
        case .dangling: "Repair"
        case .foreign: "In use"
        case .absent: "Install"
        }
    }

    /// Four states, not two: a link pointing at a moved app is offered for
    /// repair rather than reported as installed, and a name owned by
    /// something else is never silently replaced.
    ///
    /// ⚠ The sentence no longer carries the path. It read "Installed,
    /// pointing at /Users/<name>/Applications/Oilbird.app/Contents/Helpers/
    /// oilbird" — one hundred and six characters of wrapping prose in a
    /// row whose trailing edge belongs to the Remove button. The path is
    /// the row's `path:` now and this says what state the link is in.
    private func cliDetail(_ state: Oilbird.CLIState) -> String {
        switch state {
        case .installed: "Installed, pointing at:"
        case .dangling: "Installed, but the app has moved — nothing is here now:"
        case .foreign: "Something else already owns that name. Oilbird will not replace it."
        case .absent: "Not installed. Adds a link in /usr/local/bin."
        }
    }

    /// What the link points at, when there is one. The two states with no
    /// target have nothing to show and must not draw an empty line.
    private func cliPath(_ state: Oilbird.CLIState) -> String? {
        switch state {
        case .installed(let target), .dangling(let target): target
        case .foreign, .absent: nil
        }
    }

    // MARK: Storage

    private func storagePane() -> [NSView] {
        let report = Oilbird.diskReport()
        let stateReveal = NSButton(
            title: "Reveal", target: self, action: #selector(revealState))
        stateReveal.bezelStyle = .rounded
        let cacheReveal = NSButton(
            title: "Reveal", target: self, action: #selector(revealCache))
        cacheReveal.bezelStyle = .rounded

        var cards: [NSView] = [
            section(
                "Where it lives",
                SettingsDesign.card([
                    SettingsDesign.row(
                        "Results and settings",
                        path: report.stateRoot,
                        control: stateReveal),
                    SettingsDesign.row(
                        "Downloads and the server",
                        path: report.cacheRoot,
                        control: cacheReveal),
                ]),
                footnote: report.relocatedTo.map {
                    "OILBIRD_HOME is set to \(Oilbird.displayPath($0)), so everything "
                        + "above has moved with it."
                }
                    ?? "Setting OILBIRD_HOME in your environment moves all of it somewhere "
                    + "else, which is how the test suites keep off your real install.")
        ]

        var rows: [NSView] = []
        for entry in report.keep + report.cache where entry.bytes > 0 {
            rows.append(
                SettingsDesign.reading(
                    entry.label, Oilbird.humanBytes(entry.bytes), detail: entry.cost))
        }
        rows.append(SettingsDesign.reading("Total", Oilbird.humanBytes(report.total)))
        cards.append(section("What it costs", SettingsDesign.card(rows)))

        let reclaim = NSButton(
            title: "Reclaim", target: self, action: #selector(reclaimSpace))
        reclaim.bezelStyle = .rounded
        reclaim.isEnabled = report.reclaimable > 0
        cards.append(
            section(
                "Reclaim",
                SettingsDesign.card([
                    SettingsDesign.row(
                        report.reclaimable > 0
                            ? "Free \(Oilbird.humanBytes(report.reclaimable))"
                            : "Nothing to reclaim",
                        detail: "Installers Oilbird has already unpacked, and anything "
                            + "pinned by a version it no longer is. Nothing that holds a "
                            + "result.",
                        control: reclaim)
                ]),
                footnote: "Downloads are kept so an interrupted one can resume, and they "
                    + "were never cleared afterwards. The server's scratch space is left "
                    + "alone while the engine is running."))
        if let notice = notices[Pane.storage.rawValue] { cards.append(noticeCard(notice)) }
        if let problem = problems[Pane.storage.rawValue] { cards.append(warningCard(problem)) }
        return cards
    }

    // MARK: Versions

    private func versionsPane() -> [NSView] {
        var cards: [NSView] = []
        if let table = try? Oilbird.versionTable() {
            cards.append(
                section(
                    "What Oilbird runs",
                    SettingsDesign.card(
                        table.map { row in
                            SettingsDesign.reading(
                                row.id, row.pinned, detail: installedLine(row))
                        }),
                    footnote: "The version on the right is what this build pins. Under "
                        + "each name is what Oilbird recorded when it installed one, and "
                        + "the two differ after an update until the download finishes — "
                        + "which is the one thing this table exists to show. Oilbird will "
                        + "not call a dependency installed because a folder exists; "
                        + "Doctor is what answers that."))
        } else {
            cards.append(
                warningCard(
                    "Oilbird could not read its own manifest, which is the list of "
                        + "everything it pins. This build is damaged; reinstalling is the "
                        + "way out."))
        }

        let build = Oilbird.build
        cards.append(
            section(
                "Oilbird itself",
                SettingsDesign.card([
                    SettingsDesign.reading("Version", build.version),
                    SettingsDesign.reading(
                        "Build", build.commit ?? "not stamped",
                        detail: build.commit == nil
                            ? "Running from a build directory rather than an application."
                            : "The commit this application was built from."),
                ])))
        return cards
    }

    /// ⚠ **"Not installed" would be a lie.** The installed side is a record
    /// Oilbird writes as it places each artefact, and a container provisioned
    /// before that record existed has none — a running SonarQube with no
    /// `manifest.json` beside it would read "not installed" on every row.
    /// `versionChanges` already says this in as many words: absence of a
    /// record is not evidence of a change. The same rule holds from the
    /// other side — presence on disk is not presence — so this reports what
    /// it knows and names what would answer the rest.
    private func installedLine(_ row: Oilbird.VersionRow) -> String {
        guard let installed = row.installed else {
            // ⚠ What is on DISK, not the install record: the record is
            // written at install time, so an older install reads "no install
            // recorded" on a machine currently serving the page behind it.
            guard let found = row.detected else { return "Not installed · \(row.licence)" }
            return found == row.pinned
                ? "Found on disk, installed before Oilbird kept a record · \(row.licence)"
                : "Found \(found) on disk, this build wants \(row.pinned) · \(row.licence)"
        }
        return installed == row.pinned
            ? "Installed · \(row.licence)"
            : "Installed \(installed), this build wants \(row.pinned) · \(row.licence)"
    }

    // MARK: search

    /// Hides the groups that do not match, dims the panes that have none,
    /// and moves to the first pane that does — so typing answers "where is
    /// that setting" rather than only filtering wherever you happen to be.
    @objc private func searchSettings() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var firstMatch: Int?
        for (index, sections) in paneSections.enumerated() {
            var any = false
            for group in sections {
                let matches = query.isEmpty || group.searchText.contains(query)
                group.isHidden = !matches
                any = any || matches
            }
            sidebarRows[index].hasMatches = query.isEmpty || any
            if !query.isEmpty, any, firstMatch == nil { firstMatch = index }
        }
        if let firstMatch, !query.isEmpty { selectPane(firstMatch) }
    }

    /// Shows one pane, and takes everything that marks it along.
    ///
    /// The bounds check is here rather than at each caller because ↑ on the
    /// first row and ↓ on the last are the ordinary way to reach the ends of
    /// a list, and neither is an error worth a beep.
    private func selectPane(_ index: Int) {
        guard paneViews.indices.contains(index) else { return }
        let moved = chosen != index
        chosen = index
        for (position, view) in paneViews.enumerated() { view.isHidden = position != index }
        for (position, row) in sidebarRows.enumerated() { row.isChosen = position == index }
        paneHeading.stringValue = sidebarRows[index].title
        // Hidden, but the Window menu and the accessibility tree read it.
        window?.title = "Oilbird Settings — \(sidebarRows[index].title)"
        guard moved else { return }

        // ⚠ The focus ring follows the capsule, or the window shows two
        // selections. Only when the sidebar already had it, since
        // `searchSettings` calls this on every keystroke.
        if let responder = window?.firstResponder as? SettingsSidebarRow,
            responder !== sidebarRows[index]
        {
            window?.makeFirstResponder(sidebarRows[index])
        }

        // ⚠ A pane opens at its TOP. The name is drawn outside the scroll
        // view, so one restored mid-scroll puts an unlabelled card under a
        // heading whose first section is off screen.

        // Only on a REAL move: `searchSettings` re-selects on every keystroke
        // and `refreshLive` rebuilds twice a second, and neither may yank the
        // page out from under a reader.
        let scroll = paneViews[index]
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
