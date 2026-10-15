import AppKit
import OilbirdKit

/// The menu bar.
///
/// ⚠ There was none. A programmatic AppKit app gets no main menu unless it
/// builds one, and Oilbird never did — the running app had exactly two menu
/// bar items, Apple and an empty "Oilbird".
///
/// That is not a cosmetic gap. Key equivalents are dispatched from menu
/// items, so with no Edit menu there is no ⌘C for the responder chain to
/// route, and **copy and paste did nothing anywhere in the app** — including
/// inside the dashboard, where an issue message could not be copied out. The
/// Edit menu below is doing real work; the rest is what a Mac app owes its
/// user.
@MainActor
enum AppMenu {
    /// Builds and installs it. Actions route through the responder chain to
    /// whatever is focused — usually the web view — so most items need no
    /// target of their own.
    static func install(target: AnyObject) {
        let main = NSMenu()

        // MARK: Oilbird
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Oilbird", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        // ⚠ The icon keeps the left edge straight: macOS supplies one for
        // every app-menu item it recognises and lays titles out past that
        // column, so an item without one starts 40 points left of the rest.
        let settings = add(appMenu, "Settings…", #selector(AppDelegate.showSettings), ",", target)
        settings.image = NSImage(
            systemSymbolName: "gearshape", accessibilityDescription: nil)
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Oilbird", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        // ⚠ ⌘Q keeps `terminate:` in both modes; only its TITLE follows the
        // preference. Rebinding the key leaves the Dock's Quit still quitting,
        // and one selector puts all three routes on one rule.
        let close = appMenu.addItem(
            withTitle: "", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        close.tag = Ending.close
        let endings = NSMenuItem.separator()
        endings.tag = Ending.separator
        appMenu.addItem(endings)
        // The only item that ends the process, here as well as in the menu bar
        // item: with the menu bar icon off this is the one way out,
        // reached by clicking the Dock icon.
        let terminate = add(appMenu, "", #selector(AppDelegate.quitCompletely), "", target)
        terminate.tag = Ending.terminate
        // Without an icon its title starts 40 points left of every other
        // item's, for the reason given above "Settings…".
        terminate.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        app.submenu = appMenu
        // ⚠ `showEndings` runs again on every open: AppKit injects its own
        // "Quit and Keep Windows" when it chooses, and the preference behind
        // these names can change in Settings while the menu sits built.
        appMenu.delegate = target as? NSMenuDelegate
        main.addItem(app)

        // MARK: File
        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(fileMenu, "Scan Project…", #selector(AppDelegate.scanProject), "o", target)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        file.submenu = fileMenu
        main.addItem(file)

        // MARK: Edit — the one that was load-bearing.

        // Responder-chain selectors with no target, which is what lets
        // WKWebView answer them: without this menu the key equivalents do not
        // exist.
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        main.addItem(edit)

        // MARK: Engine

        // The only non-standard menu, holding exactly what the header pill and
        // the menu bar item hold, so a keyboard user is not second-class.
        let engine = NSMenuItem()
        let engineMenu = NSMenu(title: "Engine")
        add(engineMenu, "Resume", #selector(AppDelegate.resumeEngine), "r", target)
        let pause = add(engineMenu, "Pause", #selector(AppDelegate.pauseEngine), "p", target)
        pause.keyEquivalentModifierMask = [.command, .option]
        engineMenu.addItem(.separator())
        let reload = add(
            engineMenu, "Reload Dashboard", #selector(AppDelegate.reloadDashboard), "r", target)
        reload.keyEquivalentModifierMask = [.command, .shift]
        add(engineMenu, "Show Log", #selector(AppDelegate.showLog), "", target)
        engine.submenu = engineMenu
        main.addItem(engine)

        // MARK: Window
        let window = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.submenu = windowMenu
        main.addItem(window)
        NSApp.windowsMenu = windowMenu

        // MARK: Help
        let help = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        add(helpMenu, "Show Log", #selector(AppDelegate.showLog), "", target)
        add(helpMenu, "Report an Issue…", #selector(AppDelegate.reportIssue), "", target)
        help.submenu = helpMenu
        main.addItem(help)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
        showEndings()
    }

    /// Tags on the three items the residency preference decides, so
    /// `showEndings` can find them again. Kept rather than held as stored
    /// references because this menu outlives nothing and owns nothing — the
    /// app menu is the app's.
    private enum Ending {
        static let close = 1
        static let separator = 2
        static let terminate = 3
    }

    /// Names the two endings for what they currently do, and hides the
    /// second when there is only one.
    ///
    /// ⚠ Called again on every settings change, not only at launch. The
    /// General switch decides whether ⌘Q closes or quits, so an item titled
    /// once at launch is wrong from the instant somebody flips it — and an
    /// item wearing the wrong word beside ⌘Q is the fault `Oilbird.Residency`
    /// exists to prevent.
    ///
    /// With residency off there is no second ending to offer: ⌘Q already
    /// quits, and a "Quit Oilbird Completely" beside a "Quit Oilbird" is
    /// two names for one act.
    static func showEndings(_ residency: Oilbird.Residency = Oilbird.residency()) {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
        appMenu.item(withTag: Ending.close)?.title = residency.closeTitle
        let terminate = appMenu.item(withTag: Ending.terminate)
        terminate?.title = residency.terminateTitle ?? ""
        terminate?.isHidden = residency.terminateTitle == nil
        appMenu.item(withTag: Ending.separator)?.isHidden = residency.terminateTitle == nil

        // ⚠ AppKit puts a "Quit and Keep Windows" beside any `terminate:` item.
        // Once a quit can be refused it neither quits nor keeps anything, so
        // it is hidden for as long as that is true.
        for injected in appMenu.items
        where injected.tag != Ending.close
            && injected.action == #selector(NSApplication.terminate(_:))
        {
            injected.isHidden = residency.quitCloses
        }
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ target: AnyObject
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
