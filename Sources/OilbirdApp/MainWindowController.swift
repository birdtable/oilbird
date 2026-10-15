import AppKit
import OilbirdKit
import WebKit

/// The dashboard is SonarQube's own, in a real window.
///
/// Oilbird adds no chrome inside the web view and does not intercept
/// navigation — a wrapper that reinterpreted Sonar's UI would drift from it on
/// every upstream release.
///
/// The chrome is deliberately *unified*: there is no second header band. Warm
/// chrome wrapped around a cool web view reads as an iframe, and the fix is not
/// to recolour the frame but to remove it. The web content's own ground runs to
/// the edges and up behind the traffic lights, and Oilbird's controls float in
/// the title bar over it.
final class MainWindowController: NSWindowController {
    private let web = DashboardWebView()
    /// ⚠ A `Theme.Ground` reading `painted`, not a plain view painted with
    /// a `cgColor`. A `cgColor` resolves against the appearance current
    /// when it is assigned and never again, so the dot kept its light-mode
    /// ink through a dark-mode toggle — and `quiet` is `tertiaryText`,
    /// which is the tone that moves furthest between the two.
    private lazy var stateDot = Theme.Ground(
        radius: 3.5,
        fill: { [weak self] in Self.colour(for: self?.painted ?? .working) })
    private var painted: Oilbird.Tone = .working
    /// The state, as something you can press.
    private let statePill = NSView()
    private let stateLabel = NSTextField(labelWithString: "starting")
    /// Shown whenever the web view has nothing to show. Without it the window
    /// is a blank rectangle, which is what a stopped server looked like.
    private let empty = EmptyStateView()
    /// Which load the reveal poll belongs to.
    ///
    /// Two loads can overlap — Resume while a Reload is still booting — and
    /// the older poll must not uncover a page the newer one has replaced.
    private var loadGeneration = 0
    /// The load a reveal is already polling for, so a commit and the safety
    /// net below it do not both start one.
    private var revealing = 0

    /// Why the observation must not repaint, and what ends it.
    private enum Holding {
        /// Work this window started, or a message it is waiting for an
        /// answer to. Overwriting "scanning" with "running" would be a less
        /// useful truth, and replacing "Something is using the engine" ten
        /// seconds later would lose the answer to the question the user
        /// just asked. Ends when the window itself says so.
        case untilAnswered
        /// A failure. Its account of what went wrong is the only one there
        /// is, so it stays — but it ends the moment the engine is genuinely
        /// up, however that happened, so a start from a terminal is not
        /// ignored.
        case untilRunning
    }

    private var holding: Holding?
    /// Live for the window's lifetime; `url` is KVO-observable on WKWebView.
    private var routeWatch: NSKeyValueObservation?
    /// The route currently being answered, so the panel is shown once and
    /// taken down the moment the reader navigates away.
    private var answering: AnsweredRoute?
    /// The state the body was last built for.
    ///
    /// A ten-second observation that finds nothing changed must not rebuild
    /// the body — reloading the dashboard under someone reading it would
    /// make the fix worse than the defect.
    private var shown: Oilbird.EngineState?

    convenience init() {
        // ⚠ Sized from what the dashboard needs and CAPPED BY THE SCREEN.
        // Uncapped, a 1024×768 display opens this at its minimum with 320
        // points off the edge, where everything Oilbird owns lives.
        let wanted = Oilbird.minimumWindowWidth
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: wanted, height: 820)
        let minimum = min(wanted, screen.width)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: min(wanted + 80, screen.width), height: min(820, screen.height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Oilbird"
        window.titlebarAppearsTransparent = true
        // ⚠ Hidden, because this window draws its own bar: AppKit puts the
        // title in the same strip as the status dot and the two overlap into
        // "ru●Oilbird". Still SET, for the Window menu and Mission Control.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: minimum, height: min(640, screen.height))
        // Explicit, because the window is mostly OUR ground until the web view
        // loads. Left unset it takes the system default, which in dark mode is
        // near-black — and every piece of paper-coloured text on it vanishes.
        window.backgroundColor = Theme.Colour.surface
        // Nothing pins an appearance: the palette follows the system (`Theme`).
        window.center()
        self.init(window: window)
        build()
        connect()
    }

    private func build() {
        guard let window else { return }

        let toolbar = NSToolbar(identifier: "oilbird")
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar

        // ⚠ The state is a CONTROL, not a label: pausing on purpose should not
        // mean waiting out a thirty-minute timer. The same four items as the
        // menu bar item, so there is one thing to learn.
        stateLabel.font = NSFont.systemFont(ofSize: 12)
        stateLabel.textColor = Theme.Colour.primaryText

        let chevron = NSImageView(
            image: NSImage(
                systemSymbolName: "chevron.down", accessibilityDescription: nil)
                ?? NSImage())
        chevron.contentTintColor = Theme.Colour.tertiaryText
        chevron.symbolConfiguration = .init(pointSize: 8, weight: .bold)

        let pillContents = NSStackView(views: [stateDot, stateLabel, chevron])
        pillContents.orientation = .horizontal
        pillContents.spacing = 6
        pillContents.alignment = .centerY
        pillContents.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 9)
        pillContents.wantsLayer = true
        pillContents.layer?.cornerRadius = 11
        // The pill's well, through a view that re-resolves its own fill.
        // Assigned as a `cgColor` here it kept its launch-time appearance,
        // so in dark mode the pill stayed a pale slab under pale text.
        let pillWell = Theme.Ground(radius: 11, fill: { Theme.Colour.sunken })
        statePill.addSubview(pillWell)
        statePill.addSubview(pillContents)
        pillWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pillWell.topAnchor.constraint(equalTo: statePill.topAnchor),
            pillWell.bottomAnchor.constraint(equalTo: statePill.bottomAnchor),
            pillWell.leadingAnchor.constraint(equalTo: statePill.leadingAnchor),
            pillWell.trailingAnchor.constraint(equalTo: statePill.trailingAnchor),
        ])
        pillContents.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pillContents.topAnchor.constraint(equalTo: statePill.topAnchor),
            pillContents.bottomAnchor.constraint(equalTo: statePill.bottomAnchor),
            pillContents.leadingAnchor.constraint(equalTo: statePill.leadingAnchor),
            pillContents.trailingAnchor.constraint(equalTo: statePill.trailingAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(showEngineMenu))
        statePill.addGestureRecognizer(click)

        let scan = NSButton(title: "Scan Project…", target: self, action: #selector(chooseProject))
        scan.bezelStyle = .rounded
        scan.keyEquivalent = "o"
        scan.keyEquivalentModifierMask = [.command]

        // Traffic lights on the left with nothing beside them, as macOS
        // expects; the state travels to the right where the controls are,
        // because that is where you act on it.
        let bar = NSStackView(views: [NSView(), statePill, scan])
        bar.orientation = .horizontal
        bar.spacing = 8
        // 96pt of leading inset clears the traffic lights. fullSizeContentView
        // puts our content at y=0, so without this the first control sits
        // underneath them — which is what the title and the state were doing.
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 96, bottom: 0, right: 18)

        let body = NSView()
        for view in [web, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: body.topAnchor),
                view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            ])
        }
        web.isHidden = true
        // A failed load is Oilbird's to explain, and the reveal waits for
        // the navigation it belongs to. Both need this delegate; there was
        // none.
        web.navigationDelegate = self
        // ⚠ Observed, not intercepted: SonarQube changes its route with
        // `pushState`, so `decidePolicyFor` is never consulted and a
        // navigation policy cannot answer a page that never navigates.
        routeWatch = web.observe(\.url, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.answerRouteIfNeeded(view.url) }
        }

        let root = NSStackView(views: [bar, body])
        root.orientation = .vertical
        root.spacing = 0
        root.distribution = .fill

        for view in [stateDot, statePill, bar, root] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            stateDot.widthAnchor.constraint(equalToConstant: 7),
            stateDot.heightAnchor.constraint(equalToConstant: 7),
            bar.heightAnchor.constraint(equalToConstant: 46),
        ])

        // A folder dropped on the window is a scan — on Oilbird's own ground
        // here, and on the dashboard through `DashboardWebView`, because the
        // web view covers most of the window once a project has been scanned.
        let content = FolderDropView()
        content.onDrop = { [weak self] folder in self?.scan(folder) }
        // The window's own ground, behind the toolbar and the web view until
        // it loads. A `Theme.Ground` and not a layer colour, because it must
        // meet the dashboard's ground without a seam.
        let ground = Theme.Ground(fill: { Theme.Colour.surface })
        content.addSubview(ground)
        content.addSubview(root)
        ground.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: content.topAnchor),
            ground.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        web.onFolderDrop = { [weak self] folder in self?.scan(folder) }
        window.contentView = content
    }

    // MARK: what the pill says

    // ⚠ OBSERVED, never assigned at the sites that act, or it says "running"
    // over an engine the watchdog stopped. `AppDelegate` polls once for the
    // whole app and pushes the answer here and to the menu bar item.

    /// A state the app observed, rather than one this window caused.
    func observed(_ state: Oilbird.EngineState) {
        switch holding {
        case .untilAnswered: return
        case .untilRunning where !state.isRunning: return
        case .untilRunning, nil: break
        }
        holding = nil
        render(state: state)
    }

    /// The pill, the dot and the body, for one engine state.
    private func render(state: Oilbird.EngineState) {
        paint(state.word, state.tone)
        guard shown != state else { return }
        shown = state
        switch state {
        case .running(let running):
            show(running: running.webPort)
        case .paused:
            web.isHidden = true
            empty.show(
                title: "Paused",
                detail: "Oilbird stopped the analysis engine and gave back about 1.6 GB of "
                    + "memory. Your results are all still here.",
                action: "Resume", working: false
            ) { [weak self] in self?.connect() }
        case .starting:
            // Someone else is already bringing it up. Starting a second time
            // would queue behind them for no reason.
            web.isHidden = true
            empty.show(
                title: "Starting Oilbird",
                detail: "Another window or command is bringing the engine up.",
                working: true)
        case .notInstalled:
            web.isHidden = true
            empty.show(
                title: "Oilbird is not set up yet",
                detail: "The analysis server, a Java runtime, PostgreSQL and the scanner "
                    + "have to be downloaded once before anything can be scanned.",
                action: "Set up Oilbird…", working: false
            ) { (NSApp.delegate as? AppDelegate)?.open() }
        case .unresponsive:
            web.isHidden = true
            empty.show(
                title: "The engine is not answering",
                detail: "It is recorded as running and does not reply — a crash, a force "
                    + "quit, or a Mac that slept badly. Restarting it is the way out.",
                action: "Restart", working: false
            ) { [weak self] in self?.connect() }
        }
    }

    /// The only place the pill and the dot are written.
    private func paint(_ word: String, _ tone: Oilbird.Tone) {
        painted = tone
        stateLabel.stringValue = word
        stateDot.needsDisplay = true
    }

    /// The palette stays here. `Oilbird.Tone` says how a state reads; which
    /// ink that is remains the app's business.
    private static func colour(for tone: Oilbird.Tone) -> NSColor {
        switch tone {
        case .good: Theme.Colour.clean
        case .working: Theme.Colour.changed
        case .quiet: Theme.Colour.tertiaryText
        }
    }

    /// Service state is read from disk, never remembered: the CLI or an agent
    /// may have started or stopped things since this window last looked.
    /// Re-reads the engine's state and shows whatever it finds.
    ///
    /// Public because the menu bar drives it too: Resume, Pause and Reload
    /// all end with "look again", and each having its own idea of what to
    /// show is how three views drift apart.
    func reconnect(startIfPaused: Bool = true) { connect(startIfPaused: startIfPaused) }

    /// Stopping takes several seconds -- a SIGTERM with a grace period, then
    /// PostgreSQL shutting down cleanly -- and it used to happen behind a
    /// window that still said "running". Silence for that long reads as a
    /// click that did nothing.
    func showPausing() {
        holding = .untilAnswered
        web.isHidden = true
        paint("pausing", .working)
        empty.show(
            title: "Pausing", detail: "Letting the database close cleanly.", working: true)
    }

    /// Says the engine is in use, in the window rather than only as a beep.
    ///
    /// ⚠ This wrote no state at all, so a pause the engine refused left the
    /// pill reading amber "pausing" above the words saying it had not
    /// paused — for ever, since nothing ever looked again. The engine is
    /// running here by definition: something is holding it open.
    ///
    /// ⚠ And it said "A scan is running", which it cannot know. The
    /// attachment is a `flock` and a lock carries no reason across
    /// processes; six operations take one. The CLI says only that it is in
    /// use, and this now says the same thing.
    func reportInUse() {
        // Held: this is the answer to a question the user just asked, and
        // the observation replacing it with the dashboard ten seconds later
        // would lose it. Pressing the button releases it.
        holding = .untilAnswered
        shown = nil
        empty.isHidden = false
        web.isHidden = true
        empty.show(
            title: "Something is using the engine",
            detail: "A scan or another Oilbird client has it open, and Oilbird will not stop "
                + "it underneath them.",
            action: "Show the dashboard"
        ) { [weak self] in self?.connect() }
        // Asked rather than assumed, even though a refused stop means it is
        // up: the pill has to stop saying "pausing", and the engine is the
        // only thing entitled to say what replaces it.
        Task { @MainActor in
            let state = await Oilbird.engineState()
            paint(state.word, state.tone)
        }
    }

    /// Looks at the engine and shows whatever it finds, starting it if that
    /// is what the user is asking for.
    ///
    /// - Parameter startIfPaused: whether a paused engine should be started.
    ///   True on launch, because opening the app is asking to use it. WARNING
    ///   FALSE after the user pauses -- this had no such distinction, so
    ///   `pauseEngine` stopped the engine, called this, and this started it
    ///   again. Pausing unpaused itself, within a second, every time.
    private func connect(startIfPaused: Bool = true) {
        Task { @MainActor in
            let state = await Oilbird.engineState()
            switch state {
            case .running, .starting:
                holding = nil
                shown = nil
                render(state: state)
                if case .starting = state {
                    try? await Task.sleep(for: .seconds(2))
                    connect(startIfPaused: startIfPaused)
                }
                return
            case .paused where !startIfPaused:
                holding = nil
                shown = nil
                render(state: state)
                return
            case .paused, .notInstalled, .unresponsive:
                break
            }
            await start()
        }
    }

    /// Brings the engine up in front of the user.
    ///
    /// ⚠ The pill says "starting" from the first moment. It used to keep
    /// saying "paused" for the whole ~24-second start while the body
    /// underneath said "Warming up the search index" — so Resume read as a
    /// control that had done nothing, and invited a second press.
    private func start() async {
        holding = .untilAnswered
        shown = nil
        paint("starting", .working)
        empty.show(title: "Starting Oilbird", detail: "Getting the engine up.", working: true)
        do {
            let running = try await Oilbird.up { phase in
                Task { @MainActor in
                    self.empty.show(title: phase.label, detail: phase.detail, working: true)
                }
            }
            holding = nil
            render(state: .running(running))
        } catch let error as Oilbird.Error {
            // Never a blank window: say what happened and what can be done.
            showFailure(error)
        } catch {
            holding = .untilRunning
            paint("stopped", .quiet)
            empty.show(
                title: "Oilbird could not start.", detail: "", action: "Try again",
                working: false
            ) { [weak self] in self?.connect() }
        }
    }
}

/// What the window offers when something has failed.
///
/// ⚠ An extension in the same file, which groups rather than shrinks: the
/// file is the same length and the 34 `private` members stay reachable,
/// which they would not be across files. What it makes visible is that
/// failure presentation is a separable concern of this controller.
extension MainWindowController {
    // ⚠ Every arm decides the LABEL and the ACTION together, and leaves
    // something enabled to press. Chosen apart, "Show log" retries the start
    // that just failed: a dead end in the costume of a way out.

    /// The one `.retry` label anywhere that names an act other than
    /// retrying. Five sites raise it — `Supervise` twice, `Scan`, `SonarAPI`
    /// and the barrel — and all five mean "the log knows why". Matched
    /// exactly: reword it and this falls through to the plain retry arm,
    /// which is the wrong words over the right action rather than the
    /// reverse.
    static let logLabel = "Show log"
    /// `Recovery`'s floor, and the only label that is always a control.
    static let reportLabel = "Report an issue"

    /// Shows a failure with a button that does what it says.
    private func showFailure(_ error: Oilbird.Error) {
        // ⚠ Written to the log HERE, or a GUI failure assembles
        // `OilbirdError.underlying` and drops it, and "Show log" opens a log
        // that does not mention what just happened.
        Oilbird.record(error)
        // Held, so the ten-second observation does not replace an account of
        // a failure the user has not read yet. It is released the moment the
        // engine is genuinely up, however that happened.
        holding = .untilRunning
        // Set here rather than by each caller: a reinstall that fails would
        // otherwise leave the pill reading "installing" under the words
        // saying it did not.
        paint("stopped", .quiet)
        switch error.recovery {
        case .retry(let offered) where offered == Self.logLabel:
            // The case says retry and the word says read the log. The WORD
            // wins: a pending migration or a server that never reached UP are
            // exactly where starting again changes nothing.
            empty.show(
                title: error.detail,
                detail: "The log has what the server said on its way down.",
                action: offered, working: false
            ) { [weak self] in
                (NSApp.delegate as? AppDelegate)?.showLog()
                self?.offerRetry(after: error)
            }

        case .retry(let offered):
            empty.show(title: error.detail, detail: "", action: offered, working: false) {
                [weak self] in self?.connect()
            }

        case .chooseAlternative(let offered):
            // The only site is a project key that is not there, offering
            // "List projects" — and `connect()` genuinely lists them: it
            // loads the server root, which is SonarQube's project list.
            empty.show(title: error.detail, detail: "", action: offered, working: false) {
                [weak self] in self?.connect()
            }

        case .freeSpace(let needed, let available):
            // Oilbird does not tidy a disk it does not own, so the
            // honest half of "free space, then retry" is the retry. The
            // numbers go in the words, where they are of some use.
            empty.show(
                title: error.detail,
                detail: "Oilbird needs \(Oilbird.humanBytes(needed)) and there is "
                    + "\(Oilbird.humanBytes(available)) free. Make room, then try again.",
                action: "Try again", working: false
            ) { [weak self] in self?.connect() }

        case .reinstall(let id):
            // "Reinstall" now reinstalls. Which dependency is already in
            // `error.detail` — "Java is not installed." — so the button does
            // not have to repeat it.
            empty.show(title: error.detail, detail: "", action: "Reinstall", working: false) {
                [weak self] in self?.reinstall(id)
            }

        case .waitForHolder(let pid, _):
            // `since` is discarded on purpose: two of the three sites pass
            // `Date()` at the moment of throwing, so as a "held since" it
            // would be a timestamp of nothing.
            empty.show(
                title: error.detail,
                detail: "Another Oilbird process (\(pid)) has the database open.",
                action: "Wait", working: false
            ) { [weak self] in self?.waitForHolder() }

        case .reportIssue(let instruction):
            // The floor. This label is sometimes an instruction rather than a
            // control — "Remove it yourself first" — and an instruction is not
            // a button, so it is said in the words.
            empty.show(
                title: error.detail,
                detail: instruction == Self.reportLabel ? "" : instruction,
                action: Self.reportLabel, working: false
            ) { (NSApp.delegate as? AppDelegate)?.reportIssue() }
        }
    }

    /// What is offered once the log has been shown.
    ///
    /// Leaving "Show log" on screen would make the second press open Finder
    /// again and the third press after that — reading the log is an act with
    /// an end, and what a user wants next is the start, on their terms.
    private func offerRetry(after error: Oilbird.Error) {
        empty.show(
            title: error.detail,
            detail: "The log is selected in Finder. Try again once you have dealt with what "
                + "it says.",
            action: "Try again", working: false
        ) { [weak self] in self?.connect() }
    }

    /// "Wait" waits, and then looks again.
    ///
    /// Connecting the instant it is pressed would be the same lie in a
    /// shorter form: the other process is still holding the database a
    /// millisecond later, and the same panel would come straight back.
    private func waitForHolder() {
        holding = .untilAnswered
        empty.show(
            title: "Waiting for the other Oilbird",
            detail: "This window will carry on as soon as the database is free.", working: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            connect()
        }
    }

    /// Downloads one dependency again, here, and then carries on.
    ///
    /// The setup window is the app's install surface, but sending a user
    /// there for one missing runtime would lose what they were doing and put
    /// the other three downloads in front of them. `install(only:)` is the
    /// same call that window makes, narrowed to the one that failed.
    private func reinstall(_ id: Oilbird.DependencyID) {
        holding = .untilAnswered
        paint("installing", .working)
        empty.show(
            title: "Reinstalling", detail: "Fetching it again from its official source.",
            working: true)
        Task { @MainActor in
            do {
                try await Oilbird.install(only: [id]) { _, done, total in
                    // ⚠ Hops to the main actor, as the scan's progress does:
                    // the callback runs on whichever thread is draining the
                    // download.
                    Task { @MainActor in
                        self.empty.report(
                            "\(Oilbird.humanBytes(done)) of \(Oilbird.humanBytes(total))")
                    }
                }
                connect()
            } catch let error as Oilbird.Error {
                showFailure(error)
            } catch {
                holding = .untilRunning
                empty.show(
                    title: "The download did not finish", detail: "", action: "Try again",
                    working: false
                ) { [weak self] in self?.reinstall(id) }
            }
        }
    }

    private func show(running port: UInt16) {
        // ⚠ The overlay STAYS UP: revealing the web view at `load` shows
        // SonarQube's boot spinner on every open. The bird holds the frame
        // until the dashboard replaces it.
        empty.isHidden = false
        empty.show(
            title: "Opening the dashboard", detail: "Reading the last analysis.", working: true)
        web.isHidden = true
        // The tint is a token override, never a selector rewrite: a renamed
        // token is ignored and the page degrades to stock SonarQube, where a
        // half-matching selector would leave a broken hybrid.
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.addUserScript(SonarDismissals.userScript)
        web.configuration.userContentController.addUserScript(SonarTint.userScript)

        Task { @MainActor in
            // ⚠ Asked BEFORE the dashboard opens: SonarQube answers "no
            // projects" with cloud integrations a 127.0.0.1 server cannot
            // reach. `try?`, since only a confident zero is worth acting on.
            if let projects = try? await Oilbird.projects(), projects.isEmpty {
                showNothingScanned()
                return
            }
            // The barrel names the dashboard. A client spelling out the
            // host and the port is the same duplicated fact `Paths` exists to
            // prevent, one layer up.
            guard let dashboard = Oilbird.dashboardURL() else { return }
            open(dashboard)
        }
    }

    /// Oilbird's own empty state, and the button that ends it.
    private func showNothingScanned() {
        web.isHidden = true
        empty.show(
            title: "Nothing scanned yet",
            detail: "Choose a folder — or drop one on this window — and Oilbird will analyse "
                + "it and open the results. Nothing leaves this Mac.",
            action: "Scan Project…", working: false
        ) { [weak self] in self?.chooseProject() }
    }

    /// Signs in, loads a page, and uncovers the view when it has painted.
    ///
    /// ⚠ Sign in BEFORE loading, or the user meets SonarQube's login form
    /// — and they cannot get past it. The password is generated by
    /// Oilbird, stored 0600 and never shown, so that form is a wall with
    /// no key on either side of it. `Oilbird.webSession()` returns
    /// cookies and never the credential that produced them.
    private func open(_ url: URL) {
        Task { @MainActor in
            let store = web.configuration.websiteDataStore.httpCookieStore
            for cookie in await Oilbird.webSession() {
                await store.setCookie(cookie)
            }
            // Numbered BEFORE the load, because `didCommit` is what starts
            // the reveal now and it must find the generation its navigation
            // belongs to already in place.
            loadGeneration += 1
            let generation = loadGeneration
            web.load(URLRequest(url: url))
            // The safety net under `didCommit`. A navigation that neither
            // commits nor fails leaves the overlay up, and an overlay that
            // waits for ever is a window you cannot get out of.
            try? await Task.sleep(for: .seconds(25))
            beginReveal(for: generation)
        }
    }

    /// Starts one reveal poll per navigation.
    private func beginReveal(for generation: Int) {
        guard generation == loadGeneration, revealing != generation else { return }
        revealing = generation
        Task { @MainActor in await reveal(when: generation) }
    }

    /// Uncovers the web view once SonarQube's own loader has gone.
    ///
    /// Asked of the page rather than of the navigation: `didFinish` fires
    /// when the HTML shell has arrived, and the shell IS the spinner — the
    /// dashboard appears seconds later when the bundle has booted. The
    /// question is therefore about the state of the document.
    ///
    /// ⚠ All three clauses are load-bearing. "No `.global-loading`" alone is
    /// TRUE of `about:blank`, which is what the web view holds for the first
    /// tick of every load — so the poll would pass immediately and uncover
    /// the view at the exact moment the shell paints its spinner, leaving the
    /// old spinner visible for a split second. `#content` existing proves the shell has
    /// parsed, and its having children proves the app replaced the loader
    /// rather than the loader simply not having been written yet.
    ///
    /// ⚠ And it is started from `didCommit`, not from `load`. Asking the
    /// CURRENT document is only meaningful once the current document is the
    /// new one: on a reload the old, fully-booted dashboard answered yes
    /// within milliseconds, the overlay came down, and the user watched a
    /// raw web view blank itself for the whole seven-second load.
    ///
    /// The cap is not a nicety. If the page never boots, an overlay that
    /// waits forever is a window you cannot get out of; after it the
    /// web view is uncovered whatever state it is in, so the worst case is
    /// the spinner we were hiding, not a locked app.
    private func reveal(when generation: Int) async {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            guard generation == loadGeneration else { return }
            let booted =
                try? await web.evaluateJavaScript(
                    """
                    (function () {
                      var c = document.querySelector('#content');
                      if (!c) { return false; }
                      if (document.querySelector('.global-loading')) { return false; }
                      return c.childElementCount > 0;
                    })();
                    """) as? Bool
            if booted == true { break }
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard generation == loadGeneration else { return }
        web.isHidden = false
        empty.isHidden = true
    }

    /// ⇧⌘R. Reloads where you are, not where you started.
    ///
    /// ⚠ This went through `connect()`, which loads the server root — so a
    /// reload from Administration or from an issue put you back on
    /// /projects, and there is no Back anywhere to undo it. And the overlay
    /// came down instantly (see `reveal`), leaving the window blank for the
    /// whole seven seconds, which reads as a hang rather than as work.
    func reloadDashboard() {
        guard let url = web.url, url.scheme?.hasPrefix("http") == true else {
            reconnect()
            return
        }
        empty.isHidden = false
        empty.show(title: "Reloading", detail: "Fetching this page again.", working: true)
        web.isHidden = true
        open(url)
    }

    /// The same items as the menu bar item and the Engine menu, deliberately.
    ///
    /// Read from the state the app last observed rather than probed here:
    /// three surfaces asking three times is three chances to disagree, and
    /// disagreeing is what they did.
    @objc private func showEngineMenu() {
        let state = (NSApp.delegate as? AppDelegate)?.engine ?? .starting
        let menu = NSMenu()
        if state.canPause {
            menu.addItem(
                withTitle: "Pause now", action: #selector(pauseFromPill), keyEquivalent: "")
        } else if let resume = state.resumeLabel {
            menu.addItem(withTitle: resume, action: #selector(resumeFromPill), keyEquivalent: "")
        } else {
            let waiting = menu.addItem(withTitle: state.heading, action: nil, keyEquivalent: "")
            waiting.isEnabled = false
        }
        menu.addItem(.separator())
        let stops = menu.addItem(
            withTitle: Oilbird.idleTimeout().menuSentence, action: nil, keyEquivalent: "")
        stops.isEnabled = false
        menu.addItem(
            withTitle: "Settings…", action: #selector(settingsFromPill), keyEquivalent: "")
        for item in menu.items where item.action != nil { item.target = self }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: statePill.bounds.height + 4), in: statePill)
    }

    @objc private func pauseFromPill() {
        (NSApp.delegate as? AppDelegate)?.pauseEngine()
    }

    @objc private func resumeFromPill() {
        (NSApp.delegate as? AppDelegate)?.resumeEngine()
    }

    @objc private func settingsFromPill() {
        (NSApp.delegate as? AppDelegate)?.showSettings()
    }

    @objc func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message =
            "Choose a folder to analyse. Oilbird adds it to SonarQube as a project "
            + "and opens its results when the analysis finishes."
        guard panel.runModal() == .OK, let path = panel.url else { return }
        scan(path)
    }

    /// Runs a scan in front of the user.
    ///
    /// Also where a dropped folder and a folder opened from the Dock arrive:
    /// one path, so the three gestures cannot behave differently.
    ///
    /// ⚠ Not a bare `_ = try? await Oilbird.scan(path:)`: with no state, no
    /// progress and a discarded error, choosing a folder looks like a click
    /// that does nothing for the two to four minutes an analysis takes, and
    /// a scan that failed looks exactly the same as one that has not
    /// started. So the window says what it is doing, the scanner's own
    /// commentary proves it is moving, and the outcome — including a
    /// failure — is shown with a way onward.
    func scan(_ path: URL) {
        let name = path.lastPathComponent
        holding = .untilAnswered
        web.isHidden = true
        paint("scanning", .working)
        empty.show(
            title: "Scanning \(name)",
            detail: "Reading \(Oilbird.displayPath(path.path(percentEncoded: false))) and "
                + "sending the analysis to SonarQube. A first scan of a large project "
                + "takes a few minutes.",
            working: true)

        Task { @MainActor in
            do {
                let result = try await Oilbird.scan(path: path) { line in
                    // ⚠ Hops to the main actor. `onLine` is called from the
                    // thread draining the scanner's pipe, and touching a view
                    // from there is a crash that only shows up under load.
                    Task { @MainActor in self.empty.report(Self.readable(line)) }
                }
                holding = nil
                shown = nil
                paint("running", .good)
                if result.degraded {
                    holding = .untilAnswered
                    empty.show(
                        title: "Scanned \(name), without coverage",
                        detail: (result.degradedReason ?? "The project's own build toolchain "
                            + "was not available.") + " Everything else was analysed.",
                        action: "Show the results"
                    ) { [weak self] in
                        self?.holding = nil
                        self?.showResults(dashboard: result.dashboard)
                    }
                } else {
                    showResults(dashboard: result.dashboard)
                }
            } catch {
                holding = .untilRunning
                paint("running", .good)
                // `Oilbird.Error` carries a sentence written for a person;
                // anything else falls back to its own description, never to
                // "something went wrong", which cannot even be searched for.
                let said = (error as? Oilbird.Error)?.detail ?? "\(error)"
                empty.show(
                    title: "The scan did not finish", detail: said,
                    action: "Show the dashboard"
                ) { [weak self] in self?.reconnect() }
            }
        }
    }

    /// Takes the URL rather than the result: `Scan.Result` is a core type,
    /// and a client naming one reaches past the barrel it is supposed to be
    /// the only door through.
    private func showResults(dashboard: URL?) {
        guard let dashboard else {
            reconnect()
            return
        }
        // A scan has just created a project, so whatever the window last
        // decided about there being none is out of date.
        shown = nil
        open(dashboard)
    }

    /// The scanner's line, without the plumbing.
    ///
    /// Its output is prefixed `INFO:` / `WARN:` and padded, and the raw form
    /// reads as a log dump rather than as progress. The level is dropped and
    /// nothing else is: an unrecognised line passes through whole, because a
    /// filter that hides what it does not understand hides exactly the lines
    /// worth reading.
    static func readable(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for level in ["INFO:", "WARN:", "ERROR:", "DEBUG:"] where trimmed.hasPrefix(level) {
            return trimmed.dropFirst(level.count).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}

/// The load, as something the window can answer for.
///
/// ⚠ There was no navigation delegate at all. When the engine stopped under
/// an open window — `oilbird down`, or the idle watchdog doing its job — a
/// click inside the dashboard rendered SonarQube's own "The component cannot
/// be loaded" and a fresh load rendered a white page. A third-party error
/// message for Oilbird's own paused state, with nothing on it to press, is
/// a dead end.
/// The routes this window answers itself rather than serving.
///
/// ⚠ **Not a selector, not markup, not a hidden control** — Oilbird tints
/// SonarQube and never restyles it, and for the right reason: a selector
/// that half-matches produces a broken hybrid. This matches on the ROUTE, so
/// a SonarQube that moves the page matches nothing and the page is served
/// normally. *Fail to stock.*
///
/// ⚠ It is `url` observation rather than `decidePolicyFor`, because SonarQube
/// is a single-page app: its own links change the route with `pushState` and
/// never make a navigation request, so a policy decision is never asked for.
enum AnsweredRoute {
    /// Administration → Marketplace.
    ///
    /// Two things live on that page and neither works here. Its plugin half
    /// renders `marketplace.not_activated`, because Oilbird turns the update
    /// centre off — it is grouped in `sonar.properties` with telemetry, under
    /// "defaults to true and phones home". And SonarQube's own catalogue
    /// carries nothing for Community Build in any case: every compatibility
    /// range in it names 9.x, 10.x or the commercial 2025/2026 line, and none
    /// names 26.9. The rest of the page advertises the paid editions.
    case marketplace

    static func matching(_ url: URL?) -> AnsweredRoute? {
        guard let path = url?.path, path.contains("/admin/marketplace") else { return nil }
        return .marketplace
    }

    var title: String {
        switch self {
        case .marketplace: "Plugins are not installed from here"
        }
    }

    var detail: String {
        switch self {
        case .marketplace:
            "SonarQube's plugin catalogue has no builds for Community Build — every entry "
                + "in it targets SonarQube 9 or 10, or the commercial editions. Oilbird "
                + "leaves the update centre switched off, so nothing here can reach the "
                + "network either.\n\nA plugin jar dropped into the folder below is picked "
                + "up when the engine next starts, and Oilbird now keeps it across upgrades."
        }
    }
}

extension MainWindowController {
    /// Cover the page with Oilbird's own answer, or uncover it again.
    ///
    /// ⚠ Only while the engine is running and nothing else is holding the
    /// view. A paused engine already has a panel saying so, and this must
    /// not argue with it.
    @MainActor func answerRouteIfNeeded(_ url: URL?) {
        let route = AnsweredRoute.matching(url)
        guard route != answering else { return }
        answering = route
        guard holding == nil else { return }
        guard let route else {
            // Back to a page SonarQube serves: give it the window.
            empty.isHidden = true
            web.isHidden = false
            return
        }
        web.isHidden = true
        empty.show(
            title: route.title,
            detail: route.detail + "\n\n" + Oilbird.pluginFolder,
            action: "Back to Oilbird", working: false
        ) { [weak self] in
            self?.web.goBack()
        }
    }
}

extension MainWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        beginReveal(for: loadGeneration)
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        reportLoadFailure(error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        reportLoadFailure(error)
    }

    /// Asks the engine what happened, and says that instead.
    private func reportLoadFailure(_ error: Error) {
        // A load superseded by the next one is reported as a failure by
        // WebKit, and is not one — Resume while a Reload is still in flight
        // does exactly this.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            let state = await Oilbird.engineState()
            holding = nil
            shown = nil
            guard state.isRunning else {
                // Paused, wedged, or never set up: the state's own panel
                // already says so and offers the way out.
                render(state: state)
                return
            }
            holding = .untilRunning
            paint(state.word, state.tone)
            web.isHidden = true
            empty.show(
                title: "That page did not load",
                detail: "The engine is running, so this is the page rather than the server.",
                action: "Reload", working: false
            ) { [weak self] in self?.reconnect() }
        }
    }
}
