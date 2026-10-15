import AppKit
import OilbirdKit

/// Composition only: windows, menus, and the glue that binds them.
/// No parsing, no policy, no provisioning — all of that is OilbirdKit's, where
/// a test can reach it.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var firstRun: FirstRunWindowController?
    private var main: MainWindowController?
    private var statusItem: StatusItem?
    private var settings: SettingsWindowController?
    private var watch: Timer?

    /// Set by `quitCompletely` and by nothing else, so the one item that is
    /// allowed to end Oilbird is not refused along with every other quit.
    /// A stored flag rather than a separate exit path, because the exit path
    /// has to be `NSApp.terminate` — that is what runs
    /// `applicationWillTerminate` and lets AppKit shut the app down properly.
    private var endingCompletely = false

    /// The engine state every surface renders.
    ///
    /// ⚠ **One poll for the whole app, and it is new.** The window wrote its
    /// pill at nine call sites and never once read the engine back, so
    /// `oilbird down` in a terminal — or the idle watchdog doing exactly
    /// what it is for — left a green "running" pill over an
    /// engine that was gone. The menu bar item did poll, and its
    /// comment gives the reason that applies to every surface: the CLI and
    /// an agent change this state too, and neither can call back into this
    /// process.
    ///
    /// Held here rather than fetched three times because `validateMenuItem`
    /// cannot await, and because three surfaces asking separately is three
    /// chances to disagree — which is what the Engine menu offering Resume
    /// over a running engine was.
    private(set) var engine: Oilbird.EngineState = .starting

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Before any window is made, so nothing is drawn once in the
        // system's appearance and then again in the chosen one.
        applyAppearance()
        // Before any window. Without this the app has no Edit menu, and
        // therefore no ⌘C anywhere in it.
        AppMenu.install(target: self)

        // ⚠ Installed unconditionally, before any window. The menu bar item
        // IS where Oilbird lives when no window is open, so nothing about how
        // the app started may decide whether it exists.
        applyMenuBarPreference()

        // Ten seconds, as the menu bar item polled before this: far below
        // anything a person reads as stale, and it costs one file read and
        // one loopback request.
        watch = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.observe() }
        }

        // Anything left by a previous run is reaped before anything starts —
        // a surviving server holding a port would otherwise present as an
        // inexplicable failure rather than as a leftover.
        open()
    }

    // MARK: an open window does not hold the engine up

    // ⚠ DECIDED: no `Idle.Attachment` for a window being open, so the watchdog
    // may stop the engine under one someone is reading. Paused is a
    // first-class state.

    // Oilbird is built to be left open, so "a window exists" is the weakest
    // evidence anyone is there, and holding 1.6 GB on it repeals zero idle
    // cost for every user who does what the app encourages.

    // What made the old behaviour bad was the silence, not the stop: a green
    // pill over a dead engine is a dead end. Real work is still
    // protected, since every verb takes an attachment for its own duration.

    /// Asks the engine what it is doing and tells every surface.
    ///
    /// Not `@discardableResult`-shaped work: each surface decides what to do
    /// with the answer. The window ignores it while it is running something
    /// of its own; the menu bar item always redraws.
    @MainActor func observe() async {
        engine = await Oilbird.engineState()
        statusItem?.render(state: engine)
        main?.observed(engine)
    }

    /// ⚠ Also on activation, and not only on the timer. Coming back to
    /// Oilbird after twenty minutes in an editor is exactly when its pill is
    /// most likely to be wrong and most likely to be read, and waiting up to
    /// ten seconds to correct it means the first thing the user sees is the
    /// stale answer.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in await observe() }
    }

    /// A folder dropped on the Dock icon, or opened with Oilbird from
    /// Finder, is a scan.
    ///
    /// ⚠ There was no handler at all, and no document type declared, so the
    /// Dock icon refused the drag outright while the window accepted one and
    /// then ignored it. Dropping a folder on the Dock icon scans it;
    /// `Resources/Info.plist` declares the folder type that makes the Dock
    /// offer it.
    func application(_ application: NSApplication, open urls: [URL]) {
        var directory: ObjCBool = false
        let folders = urls.filter {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory)
                && directory.boolValue
        }
        // One scan at a time — `scan` takes one project directory, and
        // queueing four behind each other with no way to see or cancel them
        // is worse than taking the first and saying nothing about the rest.
        guard let folder = folders.first else { return }
        showMain()
        main?.scan(folder)
    }

    /// The one way back to a window, from the menu bar item or the Dock.
    ///
    /// Which window that is has to be asked, not remembered: the container
    /// can be installed or deleted while the app sits in the menu bar, and
    /// the answer is only right at the moment it is needed.
    @MainActor @objc func open() {
        // ⚠ Back into the Dock FIRST, before any window. An `.accessory` app
        // shows windows but gets no Dock tile and no menu bar, so
        // `Quit Oilbird Completely` would be missing from that menu.
        wearTheDock()
        // "Anything left to download?", not "is everything verified?": the
        // strong question sends a fully installed machine to first-run and
        // runs a fixture analysis before the window appears.
        if firstRun != nil || Oilbird.survey().contains(where: \.needsInstall) {
            showFirstRun()
        } else {
            showMain()
        }
    }

    private func showFirstRun() {
        // Reuse it for the same reason `showMain` does: setup can be closed
        // to the menu bar now, and reopening must not stack a second copy of
        // a window that is mid-download.
        if let existing = firstRun {
            existing.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = FirstRunWindowController()
        controller.onFinished = { [weak self] in
            // The window BECOMES the main window rather than closing and
            // reopening: the user stays where they were.
            self?.firstRun?.close()
            self?.firstRun = nil
            self?.showMain()
        }
        firstRun = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Deliberately NOT started here. The window shows what will be
        // downloaded and how much, and waits to be told to go —
        // the disclosure must precede the first byte.
    }

    private func showMain() {
        // Reuse the window if it is only hidden: closing it does not quit
        // Oilbird any more, so "Open" must bring back the one that exists
        // rather than stacking a second copy behind it.
        if let existing = main {
            existing.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = MainWindowController()
        main = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: what the menu bar calls

    // Also reachable from the header and the menu bar item; here is what keeps
    // a keyboard user first-class.

    @MainActor @objc func showSettings() {
        if settings == nil { settings = SettingsWindowController() }
        // `present`, not `showWindow`: the window's live panes are driven
        // by a timer it starts here and stops when it closes, and a second
        // opening has to restart it.
        settings?.present()
    }

    /// Settings changed something this object owns. Applied now rather than
    /// at next launch — a switch whose effect you have to quit to see is a
    /// switch nobody believes.
    @MainActor func settingsChanged() {
        applyMenuBarPreference()
        applyAppearance()
        // The app menu re-reads the preference for itself when it opens
        // (`menuNeedsUpdate`); this redraws the menu bar item's menu, which
        // carries the same two endings and is rebuilt rather than retitled.
        Task { @MainActor in await observe() }
    }

    /// The app menu, before it is drawn.
    ///
    /// ⚠ Here rather than only at launch. The residency switch decides what
    /// ⌘Q's item is CALLED and whether "Quit Oilbird Completely" is in the
    /// menu at all, and a title written once at launch does not re-read a
    /// preference — nor does it see the item AppKit injects beside
    /// `terminate:` after the menu is built. See `AppMenu.showEndings`.
    func menuNeedsUpdate(_ menu: NSMenu) {
        AppMenu.showEndings()
    }

    /// Light, dark, or the Mac's own choice — for everything Oilbird draws.
    ///
    /// ⚠ Set on `NSApplication` rather than on each window, and that is the
    /// whole reason it works. Windows are made later than this runs — the
    /// settings window on its first open, an alert, a sheet, the main window
    /// after setup finishes — and a per-window assignment leaves whichever
    /// one is made next wearing the system's choice beside its siblings
    /// wearing the user's. The application's appearance is inherited by
    /// every window it owns, including ones that do not exist yet.
    ///
    /// It reaches the dashboard by the same inheritance: the `WKWebView`'s
    /// `prefers-color-scheme` follows the appearance of the window it is in,
    /// so SonarQube's own script stamps `data-echoes-theme` to match. One
    /// control, both halves of the product. See `Theme.appearance`.
    @MainActor private func applyAppearance() {
        NSApp.appearance = Theme.appearance(Oilbird.settings().appearance)
    }

    /// The menu bar item exists, or does not, according to the preference.
    ///
    /// ⚠ Installed unconditionally before this, and the comment explaining
    /// why is still true of the DEFAULT: the menu bar item is where Oilbird
    /// lives when no window is open, so nothing about how the app *started*
    /// may decide whether it exists. A deliberate choice by the user is a
    /// different thing, and `applicationShouldTerminateAfterLastWindowClosed`
    /// reads the same preferences so the two cannot leave the app with
    /// nowhere to be.
    @MainActor private func applyMenuBarPreference() {
        guard Oilbird.settings().menuBarIcon else {
            statusItem = nil
            // ⚠ The two marks are one guarantee written twice: dropping the
            // menu bar icon from an app already out of the Dock leaves it
            // running, invisible, with no way to the ending.
            wearTheDock()
            return
        }
        guard statusItem == nil else { return }
        let status = StatusItem()
        status.onOpen = { [weak self] in self?.open() }
        statusItem = status
        Task { @MainActor in await observe() }
    }

    @MainActor @objc func scanProject() { main?.chooseProject() }

    /// ⚠ `open()`, not `showMain()`. On a machine with nothing installed the
    /// pill and the menu bar item both offer a way forward, and it is
    /// setup rather than a resume — sending that to the main window gave it
    /// an engine to start that does not exist yet.
    @MainActor @objc func resumeEngine() {
        Task { @MainActor in
            open()
            main?.reconnect()
            await observe()
        }
    }

    @MainActor @objc func pauseEngine() {
        Task { @MainActor in
            // Said BEFORE the wait: a SIGTERM, a grace period and a clean
            // PostgreSQL shutdown is several seconds in which the window still
            // says "running" and the click reads as doing nothing.
            main?.showPausing()
            // Not forced: a scan in flight outranks a menu click, and the
            // window says so rather than the scan dying under it.
            guard await Oilbird.down() else {
                NSSound.beep()
                main?.reportInUse()
                await observe()
                return
            }
            // WARNING `startIfPaused: false`. Reconnecting normally sees a
            // stopped engine and starts one, so pausing unpaused itself.
            main?.reconnect(startIfPaused: false)
            await observe()
        }
    }

    @MainActor @objc func reloadDashboard() { main?.reloadDashboard() }

    /// The Engine menu must not offer what the state cannot do.
    ///
    /// ⚠ Resume enabled while the engine runs, or Pause while it is paused,
    /// is a press that does nothing and a menu that teaches both are always
    /// possible — and disagrees with the pill's own menu about the same
    /// fact. Both ask `Oilbird.EngineState` the same two questions.
    ///
    /// ⚠ `NSMenuItemValidation` is declared on the class and it is not
    /// decoration. AppKit finds this through `respondsToSelector:`, and a
    /// Swift method on an `NSObject` subclass is not exposed to the
    /// Objective-C runtime unless something asks for it — so with the
    /// method written and the conformance missing, every item validated as
    /// enabled and this would be dead code, leaving Resume bright over a
    /// running engine.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(resumeEngine): engine.canResume
        case #selector(pauseEngine): engine.canPause
        // Nothing to reload before there is a window with a page in it.
        case #selector(reloadDashboard): main != nil && engine.isRunning
        default: true
        }
    }

    @MainActor @objc func showLog() {
        NSWorkspace.shared.selectFile(
            Oilbird.logPath, inFileViewerRootedAtPath: "")
    }

    @MainActor @objc func reportIssue() {
        guard let url = URL(string: "https://github.com/birdtable/oilbird/issues/new") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Clicking the Dock icon with no window open reopens it, which is what
    /// every Mac app does and what closing-without-quitting requires.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { open() }
        return true
    }

    /// ⚠ Closing the last window does NOT quit Oilbird, by default.
    ///
    /// It used to, unconditionally, and that was the wrong shape once the
    /// engine and the app were given separate lifetimes: quitting left the
    /// engine running with nothing on screen to say so, nowhere to pause
    /// it, and no way back except the Dock. On a fresh install there was
    /// not even a menu bar item, because one was created only when setup
    /// was already complete. Quitting should hide Oilbird in the menu bar
    /// instead, and that is fixed here and in `applicationDidFinishLaunching`.
    ///
    /// The residency preference decides this and `applicationShouldTerminate`
    /// together, off one flag, because they are one question asked twice:
    /// the red button and ⌘Q are the same intention arriving two ways.
    /// `Oilbird.residency` holds the rule, the item titles and the sentence
    /// the General pane shows, and the rule that some way back and some way
    /// out always survives — is asserted there rather than believed here.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Oilbird.residency().closingLastWindowQuits
    }

    /// ⚠ **An ordinary Quit closes Oilbird; only "Quit Oilbird Completely"
    /// ends it.** The models considered and rejected are recorded in
    /// `Oilbird.Residency`. Read that before changing this.
    ///
    /// ⚠ **Refusing to terminate does not refuse a log-out.** A log-out, a
    /// restart and a Software Update installer do not ask the same way a ⌘Q
    /// does — they carry `kAEQuitReason` and a person's Quit does not —
    /// which is what `Oilbird.quitRequest` reads. Rebinding ⌘Q instead
    /// cannot reach the Dock's Quit: it sends `terminate:` and there is no
    /// item of ours to rebind. The Dock menu's Quit is exactly the one that
    /// has to close, not end.
    ///
    /// So there are exactly three ways past the refusal, and all three are
    /// here: the preference is off, our own "Completely" item set the flag,
    /// or the system said why it is asking.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if endingCompletely { return .terminateNow }
        guard Oilbird.residency().quitCloses else { return .terminateNow }
        guard Oilbird.quitRequest(NSAppleEventManager.shared().currentAppleEvent).mayBeRefused
        else { return .terminateNow }
        closeToMenuBar()
        return .terminateCancel
    }

    /// What an ordinary Quit does instead of quitting.
    ///
    /// The windows are named rather than swept out of `NSApp.windows`:
    /// that list also holds AppKit's own, the status item's window among
    /// them, and closing that one would take away the very surface this
    /// leaves the user on.
    @MainActor func closeToMenuBar() {
        let ours: [NSWindowController?] = [main, firstRun, settings]
        for controller in ours.compactMap({ $0 }) { controller.close() }
        // Hand the foreground on, or Oilbird's menus sit above whatever the
        // user turned to next. `deactivate` and not `hide`: a hidden app must
        // be unhidden before a window it is told to show appears.
        NSApp.deactivate()
        // ⚠ Leaving the Dock is the whole of "closed": an app that keeps its
        // tile has only lost its window, and the two marks then disagree.

        // ⚠ Only when there IS a menu bar icon. With that switch off the tile
        // is the only way back in and the only way to the ending, so dropping
        // it leaves a running app nobody can see or stop.

        // ⚠ AFTER the windows close: `.accessory` taken while one is still up
        // leaves the tile behind until something refreshes it.
        guard Oilbird.residency().menuBarIcon else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Back into the Dock, with a menu bar of its own.
    ///
    /// Idempotent, and cheap when nothing changes — every way back in calls
    /// it rather than each one remembering to.
    @MainActor func wearTheDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The one item in the product that ends the process.
    ///
    /// It is in the menu bar item and in the app menu, under the same name,
    /// and it is the only thing that sets the flag. Quitting still does NOT
    /// stop the engine — see `StatusItem.quit` for why their lifetimes are
    /// separate.
    @MainActor @objc func quitCompletely() {
        endingCompletely = true
        NSApp.terminate(nil)
    }

    /// Quitting releases this client's attachment. It does NOT stop services
    /// another client may be using — no client owns the lifetime, and the idle
    /// rule decides the rest.
    func applicationWillTerminate(_ notification: Notification) {
        watch?.invalidate()
    }
}

// `--write-icon <path>` before NSApplication is touched, so `make icon` can run
// the release binary and the bundle can never show a mark the app does not.
if let index = CommandLine.arguments.firstIndex(of: "--write-icon"),
    CommandLine.arguments.count > index + 1
{
    let path = CommandLine.arguments[index + 1]
    exit(Icon.write(to: URL(filePath: path)) ? 0 : 1)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
