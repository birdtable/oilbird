import AppKit
import OilbirdKit

/// Oilbird in the menu bar.
///
/// The engine and the app have separate lifetimes, and that is only honest
/// if the app is still reachable once its window is shut. Without this, closing the
/// window quit Oilbird outright: the engine kept running — nothing stops it
/// on quit — but there was nowhere to see that, nowhere to pause it, and
/// nothing to reopen but the Dock.
///
/// It also gives paused somewhere to be visible when no window is open, which
/// is most of the time it will be paused.
@MainActor
final class StatusItem {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var onOpen: (() -> Void)?

    init() {
        // Set once. The mark does not change with the engine's state any
        // more — see `menuBarMark` — so redrawing it every ten seconds would
        // be work with no output.
        item.button?.image = Self.menuBarMark()
        item.button?.toolTip = "Oilbird"
        render(state: .starting)
    }

    /// The mark at menu-bar size.
    ///
    /// ⚠ **Re-laid-out for the menu bar, not scaled down from the app icon.**
    /// `Icon`'s canvas is 128 units of rounded tile, and the bird plus its
    /// clicks occupy roughly the middle 46 of them — the rest is margin the
    /// tile needs and a menu bar does not. Rendering that canvas into an
    /// 18-point square therefore produced a six-point bird with a
    /// sub-pixel arc beside it: the clicks vanished and the item read as
    /// just a bird. The vocabulary below is `Icon`'s —
    /// one ink silhouette, clicks leaving the beak — with the coordinates
    /// re-chosen so the drawing fills the box it is given.
    ///
    /// Two arcs rather than three, stroked at five grid units — about three
    /// device pixels on a Retina display — because a hairline arc is the
    /// first thing to disappear at this size. The eye, the wing and the
    /// third arc are dropped: a template image is a mask, so the wing's pale
    /// grey over dark ink becomes nothing at all, and a one-point white eye
    /// is noise.
    ///
    /// ⚠ **The clicks are drawn always.** They used to be conditional on the
    /// engine running, and the engine is stopped most of the time by design
    /// to cost nothing while idle — so for the majority of Oilbird's life the menu bar
    /// showed a bird and nothing else, which is another product's mark.
    /// Running against paused is carried by `button.appearsDisabled`
    /// instead; dimming the whole mark is legible at this size, and a
    /// three-pixel arc winking in and out is not.
    static func menuBarMark() -> NSImage {
        // Wider than it is tall, because the mark is a bird plus what it is
        // shouting. A status item is variable-width, so the box is shaped to
        // the drawing rather than the drawing squashed into a square.
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The mark's extent in grid units, so it centres with nothing
            // measuring. The one-point inset keeps the tail and outer arc off
            // the edge, where the menu bar's highlight would clip them.
            let box = CGSize(width: 74, height: 42)
            let inset = rect.insetBy(dx: 1, dy: 1)
            let unit = min(inset.width / box.width, inset.height / box.height)
            context.translateBy(
                x: (rect.width - box.width * unit) / 2,
                y: (rect.height - box.height * unit) / 2)
            // Described top-left as in `Icon`; Core Graphics draws bottom-left.
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * unit, y: (box.height - y) * unit)
            }

            // The bird: overlapping solid shapes in one fill, so it reads as
            // one silhouette rather than an assembly.
            context.setFillColor(NSColor.black.cgColor)
            context.saveGState()
            context.translateBy(x: 20 * unit, y: (box.height - 27) * unit)
            context.rotate(by: 13 * .pi / 180)
            context.fillEllipse(
                in: CGRect(x: -15 * unit, y: -10.5 * unit, width: 30 * unit, height: 21 * unit))
            context.restoreGState()
            // A bigger head than the icon's, with tail and beak keeping their
            // relative length. The head is what makes this read as a bird at
            // 16 points; a big head over a short tail reads as a fish.
            context.fillEllipse(
                in: CGRect(
                    x: 24 * unit, y: (box.height - 27.5) * unit,
                    width: 19 * unit, height: 19 * unit))
            context.beginPath()
            context.move(to: point(14, 23))
            context.addLine(to: point(0, 42))
            context.addLine(to: point(17, 31))
            context.fillPath()
            context.beginPath()
            context.move(to: point(38.5, 13.5))
            context.addLine(to: point(48, 18))
            context.addLine(to: point(38.5, 22.5))
            context.fillPath()

            // The clicks, on the beak's own axis. Radii ten units apart so
            // that five units of stroke still leave five of daylight between
            // them — closer and the pair fuses into one thick smudge.
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(5 * unit)
            context.setLineCap(.round)
            for radius in [9.0, 19.0] as [CGFloat] {
                context.beginPath()
                context.addArc(
                    center: point(52.5, 18), radius: radius * unit,
                    startAngle: -48 * .pi / 180, endAngle: 48 * .pi / 180, clockwise: false)
                context.strokePath()
            }
            return true
        }
        // A template, so macOS inverts it on a dark menu bar and while the
        // menu is open.
        image.isTemplate = true
        return image
    }

    /// Draws one engine state.
    ///
    /// ⚠ Pushed, not polled, and it used to have its own ten-second timer.
    /// The window had none at all and the Engine menu had neither, so
    /// three surfaces held three ideas of the same fact and two of them were
    /// stale. `AppDelegate` now polls once for the whole app — the reason is
    /// unchanged and still the right one: the CLI and an agent change this
    /// state too, and neither can call back into this process.
    ///
    /// ⚠ **Four groups, and only the last one quits.** What the service is
    /// doing, what you can open, closing, and one item that ends the process.
    /// The first group is the engine state and the one action that changes
    /// it, inline rather than in a submenu, because a submenu would bury
    /// Pause. The separator before the last item
    /// is the point of the whole arrangement: ending Oilbird is one item,
    /// on its own, and its name says so.
    /// One row, with the symbol that keeps the column straight.
    ///
    /// ⚠ EVERY item takes one. macOS decorates `Settings…` itself, and a
    /// menu where one item has an icon indents that item's whole group by
    /// forty points — which is why this menu had three different left edges
    /// and why giving the rest icons is the fix rather than the decoration.
    private func row(
        _ title: String, _ symbol: String, _ action: Selector? = nil, key: String = ""
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return entry
    }

    func render(state: Oilbird.EngineState) {
        let residency = Oilbird.residency()
        let menu = NSMenu()
        // Dimmed, never redrawn. The mark is the product's identity and must
        // survive every state; the state is the ink it is drawn in.
        item.button?.appearsDisabled = !state.isRunning

        let heading = row(Oilbird.menuHeading(for: state), state.symbol)
        heading.isEnabled = false
        menu.addItem(heading)

        if case .running = state {
            // Cross-process: a scan in another terminal counts, and this app
            // can only see that there is one.

            // ⚠ Neutral wording, because the lock cannot support "a scan is
            // running": `Oilbird.inUse()` is a `flock` probe and six
            // operations take it, issues and gate among them.
            if Oilbird.inUse() {
                let busy = row("In use — something has it open", "dot.radiowaves.left.and.right")
                busy.isEnabled = false
                menu.addItem(busy)
            }
        }
        // The same two questions the pill's menu and the Engine menu ask, so
        // the three cannot offer different things. Under the state, because it
        // is the one action that changes the line above it.
        if state.canPause {
            menu.addItem(row("Pause now", "pause.fill", #selector(pause)))
        } else if let label = state.resumeLabel {
            menu.addItem(row(label, state.resumeSymbol, #selector(resume)))
        }
        menu.addItem(.separator())

        menu.addItem(row("Open Oilbird", "macwindow", #selector(open)))
        // ⚠ The dashboard is reachable from every other surface, so it belongs
        // on the one always on screen. Only while there is a server: an item
        // opening a page that will not load is a dead end.
        if case .running = state {
            menu.addItem(row("Open Dashboard", "chart.bar.doc.horizontal", #selector(openDashboard)))
        }
        menu.addItem(row("Settings…", "gearshape", #selector(openSettings)))

        // ⚠ Closing is offered only when it differs from ending: with
        // residency off, ⌘Q and this menu's last item both quit, so two
        // entries would be two names for one thing.
        if let ending = residency.terminateTitle {
            menu.addItem(.separator())
            menu.addItem(
                row(residency.closeTitle, "xmark", #selector(closeToMenuBar), key: "q"))
            menu.addItem(.separator())
            // `power`, the same symbol the app menu puts on the same item:
            // one ending, one name, one mark, wherever it is met.
            menu.addItem(row(ending, "power", #selector(quit)))
        } else {
            menu.addItem(.separator())
            menu.addItem(row(residency.closeTitle, "power", #selector(quit), key: "q"))
        }

        for entry in menu.items where entry.action != nil { entry.target = self }
        item.menu = menu
    }

    @objc private func open() { onOpen?() }

    @objc private func resume() {
        (NSApp.delegate as? AppDelegate)?.resumeEngine()
    }

    /// Stops the engine, and only the engine. Quitting is a separate item,
    /// because "I am done with this for now" and "close this program" are
    /// different intentions and conflating them is what made the window's
    /// close button feel destructive.
    ///
    /// ⚠ Through the delegate, not `Oilbird.down()` here. This surface had
    /// its own copy of pause and so it also had its own idea of what a
    /// refusal looked like: the window's Pause says "Pausing" for the
    /// several seconds a clean shutdown takes and explains a refusal, and
    /// pausing from the menu bar did neither.
    @objc private func pause() {
        (NSApp.delegate as? AppDelegate)?.pauseEngine()
    }

    /// SonarQube's own dashboard, in the user's browser.
    ///
    /// ⚠ The port is asked for at the moment it is needed, never
    /// remembered. It is assigned by the OS at every start, so a URL held
    /// from the last one points at nothing — or, worse, at whatever took
    /// that port since.
    @objc private func openDashboard() {
        guard let dashboard = Oilbird.dashboardURL() else { return }
        NSWorkspace.shared.open(dashboard)
    }

    @objc private func openSettings() {
        (NSApp.delegate as? AppDelegate)?.showSettings()
    }

    /// Puts Oilbird's windows away and leaves it here. The ordinary act.
    @objc private func closeToMenuBar() {
        (NSApp.delegate as? AppDelegate)?.closeToMenuBar()
    }

    /// Ends the app, and only the app — the one item in the product that
    /// does, which is why it wears the word Completely and stands alone
    /// under its own separator.
    ///
    /// ⚠ Through `quitCompletely`, not `NSApp.terminate` directly. An
    /// ordinary quit is now refused in `applicationShouldTerminate`, and
    /// this item has to be exempt or the only way out of Oilbird would be
    /// the only one that does not work.
    ///
    /// ⚠ Quitting does NOT stop the engine. Their lifetimes are separate:
    /// the engine may be serving a scan started from a terminal or an
    /// agent, and the thing that stops an idle engine is
    /// the idle watchdog, which is its own process and outlives this one.
    /// Stopping the engine here would break another client's work in order to
    /// duplicate a rule that is already being kept. "Pause now" is how a user
    /// says they want the 1.6 GB back.
    @objc private func quit() {
        (NSApp.delegate as? AppDelegate)?.quitCompletely()
    }
}
