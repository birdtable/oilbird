import CoreServices
import Foundation
import OilbirdCore
import OilbirdKit

/// What is left when Oilbird is closed, who may end it, and no dead end over
/// the two switches that decide both.
///
/// This lives outside `AppDelegate` so it can be tested: an executable target
/// cannot be `@testable import`-ed (SwiftPM #7596), and "can these two
/// switches together strand somebody?" needs an assertion, not a reading.
func residencyTests() {
    Harness.suite("Residency — what is left when Oilbird is closed") {
        Harness.test("the default keeps Oilbird in the menu bar") {
            let fresh = Oilbird.residency(Preferences.Stored())
            Harness.expectTrue(
                !fresh.closingLastWindowQuits,
                "closing the window quit outright")
            Harness.expectTrue(fresh.menuBarIcon)
            Harness.expectNil(fresh.note, "there is nothing to warn about in the default")
        }

        Harness.test("turning residency off makes the last window close quit") {
            var stored = Preferences.Stored()
            stored.stayResident = false
            Harness.expectTrue(
                Oilbird.residency(stored).closingLastWindowQuits,
                "a person who wants a window and nothing else was not listened to")
        }

        // ⚠ No dead end over every COMBINATION, not just the one thought about.
        // Closing to the menu bar leaves the Dock, so exactly one of the two
        // marks is present in each, and the app changes them together.

        // ⚠ And a way OUT, which was free while the Dock's Quit quit: an
        // ordinary quit closes now, so the ending must be reachable by
        // somebody with no window open.
        Harness.test("no combination of the two switches leaves no way back, or out") {
            for resident in [true, false] {
                for icon in [true, false] {
                    var stored = Preferences.Stored()
                    stored.stayResident = resident
                    stored.menuBarIcon = icon
                    let residency = Oilbird.residency(stored)
                    Harness.expectTrue(
                        residency.hasAWayBack,
                        "stayResident \(resident) with menuBarIcon \(icon) strands the app")
                    Harness.expectTrue(
                        residency.hasAWayOut,
                        "stayResident \(resident) with menuBarIcon \(icon) cannot be ended")
                    // Exactly one mark, never none and never both: two marks
                    // for one app is the Dock saying open while the menu bar
                    // says closed.
                    Harness.expectTrue(
                        residency.menuBarIcon != residency.dockIcon,
                        "stayResident \(resident) with menuBarIcon \(icon) shows "
                            + "\(residency.menuBarIcon && residency.dockIcon ? "both" : "neither") "
                            + "marks once the window closes")
                }
            }
        }

        // ⚠ The folder the Marketplace panel points at has to be the one
        // SonarQube actually reads, and the one `Install.carried` preserves.
        // Three places naming a path is how two of them go stale.
        Harness.test("the plugin folder is the one an upgrade carries over") {
            let shown = Oilbird.pluginFolder
            Harness.expectTrue(
                shown.hasSuffix("extensions/plugins"),
                "the panel points somewhere SonarQube does not read: \(shown)")
            Harness.expectTrue(
                Install.carried.contains("extensions/plugins"),
                "the folder shown to the user is not the folder an upgrade preserves")
            // ⚠ Through `displayPath`, asserted as "never the raw home
            // directory" and not "starts with a tilde": the suite runs under a
            // sandboxed `OILBIRD_HOME` with no home prefix to shorten.
            Harness.expectTrue(
                !shown.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path),
                "the reader was shown a raw home path: \(shown)")
        }

        // ⚠ The first row says what Oilbird is COSTING: whether it holds 1.6
        // GB and when it stops. `Paused` alone repeats the icon, dimmed, and
        // is the least informative thing in the menu.
        Harness.test("the menu bar leads with what the state costs") {
            let paused = Oilbird.menuHeading(for: .paused)
            // Nothing more to say: no port, no memory, and an idle rule that
            // has already fired.
            Harness.expectEqual(paused, Oilbird.EngineState.paused.heading)

            for state in [Oilbird.EngineState.starting, .notInstalled] {
                Harness.expectEqual(
                    Oilbird.menuHeading(for: state), state.heading,
                    "a state with nothing to add invented something")
            }
        }

        // ⚠ EVERY item carries one: macOS puts a gear on `Settings…` whether
        // asked or not, and one item with an icon indents its whole group
        // forty points, giving the menu three left edges.
        Harness.test("every engine state has a mark as well as a word") {
            var seen: Set<String> = []
            for state: Oilbird.EngineState in [
                .paused, .starting, .notInstalled,
            ] {
                Harness.expectNotEmpty(state.symbol, "\(state.heading) has no mark")
                Harness.expectNotEmpty(state.resumeSymbol, "\(state.heading) has no resume mark")
                seen.insert(state.symbol)
            }
            Harness.expectEqual(
                seen.count, 3, "two states share a mark, so the shape says less than the word")
        }

        // ⚠ The soft quit: it leaves the Dock, not just
        // the window. `closeToMenuBar` reads exactly this.
        Harness.test("closing to the menu bar means leaving the Dock") {
            var stored = Preferences.Stored()
            stored.menuBarIcon = true
            Harness.expectTrue(
                !Oilbird.residency(stored).dockIcon,
                "the tile stayed behind, so Oilbird still looks open in the Dock")

            // And the corner where it must NOT: with no menu bar icon the
            // tile is the only way back in and the only way to the ending.
            stored.menuBarIcon = false
            Harness.expectTrue(
                Oilbird.residency(stored).dockIcon,
                "the last way back was dropped along with the window")
        }

        // Not a refusal — the combination is legitimate — but it must not
        // be silent: somebody who has just turned the menu bar icon off has
        // no way of knowing the Dock is now the whole of it.
        Harness.test("the one awkward combination says so, and only that one") {
            var stored = Preferences.Stored()
            stored.menuBarIcon = false
            let quiet = Oilbird.residency(stored)
            Harness.expectTrue(quiet.onlyTheDock)
            Harness.expectNotEmpty(
                quiet.note ?? "",
                "the Dock became the only way back and nothing said so")

            stored.stayResident = false
            Harness.expectNil(
                Oilbird.residency(stored).note,
                "with no residency there is no windowless state to warn about")
        }

        // ⚠ In this one combination the Dock menu is both the only place a
        // person will look and the one place the ending is not, so naming the
        // way back is no longer enough: the note says where it went.
        Harness.test("the note names the way out, not only the way back") {
            var stored = Preferences.Stored()
            stored.menuBarIcon = false
            let note = Oilbird.residency(stored).note ?? ""
            Harness.expectTrue(
                note.contains(Oilbird.residency(stored).terminateTitle ?? "\u{0}"),
                "the Dock's Quit no longer quits and the note did not say what does")
        }

        // ⚠ A word on a key is a promise, and this is the assertion that it is
        // kept: a Dock menu whose Quit does not quit, or a ⌘Q labelled "Quit
        // Oilbird" that closes, both break it.
        Harness.test("the item on ⌘Q is never called Quit unless ⌘Q quits") {
            for resident in [true, false] {
                var stored = Preferences.Stored()
                stored.stayResident = resident
                let residency = Oilbird.residency(stored)
                Harness.expectTrue(
                    residency.closeTitle.hasPrefix("Quit") == !residency.quitCloses,
                    "⌘Q is called \"\(residency.closeTitle)\" and "
                        + (residency.quitCloses ? "closes" : "quits"))
            }
        }

        // One item ends the app and says Completely, and it exists exactly
        // when closing and ending are different acts.
        Harness.test("exactly one ending, and only when it differs from closing") {
            var stored = Preferences.Stored()
            let resident = Oilbird.residency(stored)
            Harness.expectEqual(resident.closeTitle, "Close Oilbird")
            Harness.expectEqual(resident.terminateTitle, "Quit Oilbird Completely")

            stored.stayResident = false
            let leaving = Oilbird.residency(stored)
            Harness.expectEqual(leaving.closeTitle, "Quit Oilbird")
            Harness.expectNil(
                leaving.terminateTitle,
                "a Completely beside a plain Quit is two names for one act")
        }

        Harness.test("the explanation says what this switch does, in both positions") {
            var stored = Preferences.Stored()
            let staying = Oilbird.residency(stored).explanation
            stored.stayResident = false
            let leaving = Oilbird.residency(stored).explanation
            Harness.expectTrue(
                staying != leaving,
                "one sentence for both positions is wrong in one of them, which is "
                    + "where somebody about to change it is reading")
            for sentence in [staying, leaving] {
                Harness.expectTrue(
                    !sentence.contains("Option-Command-Q"),
                    "⌥⌘Q was the second name for Quit and it is gone")
            }
        }

        // ⚠ With the menu bar icon off, "closes to the menu bar" names a menu
        // bar it is not in, while the note under it says the Dock is the only
        // way back: one section, two rows, disagreeing.
        Harness.test("the explanation does not promise a menu bar that is switched off") {
            var stored = Preferences.Stored()
            stored.menuBarIcon = false
            Harness.expectTrue(
                !Oilbird.residency(stored).explanation.contains("menu bar"),
                "it named the menu bar as where Oilbird goes, with no icon in it")
            stored.menuBarIcon = true
            Harness.expectTrue(
                Oilbird.residency(stored).explanation.contains("menu bar"),
                "with the icon on, where it goes is worth saying")
        }

        // The fault: change the preference on disk, and what the delegate
        // reads back differs. Through `Preferences`, so the wiring is
        // exercised rather than only the branch.
        Harness.test("the stored preference, and nothing else, decides it") {
            let before = Preferences.load()
            defer { try? Preferences.save(before) }

            var stored = before
            stored.stayResident = true
            try? Preferences.save(stored)
            Harness.expectTrue(!Oilbird.residency().closingLastWindowQuits)

            stored.stayResident = false
            try? Preferences.save(stored)
            Harness.expectTrue(
                Oilbird.residency().closingLastWindowQuits,
                "the switch did not reach the delegate")
        }
    }

    quitRequestTests()
}

/// Telling a person's Quit from the machine going down.
///
/// ⚠ **The consequence of getting this wrong is a Mac that will not
/// restart**, and it is silent until somebody tries. A log-out, a restart and
/// a Software Update installer all ask to quit, but not the same way a ⌘Q
/// does, and this is the suite that keeps that distinction true.
///
/// The events are built here the way loginwindow builds them: a
/// `kAEQuitApplication` carrying a `kAEQuitReason` attribute.
private func quitRequestTests() {
    func quitEvent(reason: OSType?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            event.setAttribute(
                NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(kAEQuitReason))
        }
        return event
    }

    Harness.suite("Quit requests — a person, or the machine going down") {
        // ⌘Q and the menu bar item send no Apple event at all; the Dock's
        // Quit sends one with nothing in it. Both are the user, and both
        // are the ones the product is allowed to decline.
        Harness.test("no event, and an event with no reason, are both the user") {
            Harness.expectEqual(Oilbird.quitRequest(nil), .user)
            Harness.expectEqual(Oilbird.quitRequest(quitEvent(reason: nil)), .user)
            Harness.expectTrue(Oilbird.quitRequest(nil).mayBeRefused)
        }

        // Every reason loginwindow is documented to send, by name, because
        // a missing one is a hung log-out that no test would otherwise
        // notice.
        Harness.test("every reason the system sends is the system, and may not be refused") {
            let reasons: [(OSType, String)] = [
                (OSType(kAELogOut), "log out"),
                (OSType(kAEReallyLogOut), "log out"),
                (OSType(kAEShowRestartDialog), "restart"),
                (OSType(kAERestart), "restart"),
                (OSType(kAEShowShutdownDialog), "shut down"),
                (OSType(kAEShutDown), "shut down"),
            ]
            for (code, name) in reasons {
                let request = Oilbird.quitRequest(quitEvent(reason: code))
                Harness.expectEqual(request, .system(name))
                Harness.expectTrue(
                    !request.mayBeRefused,
                    "\(name) would have been refused, which hangs the machine")
            }
        }

        // ⚠ Fails towards letting go: a reason code this build has not heard
        // of still means something other than a person pressing Quit, and
        // guessing wrong that way costs a menu item, not a shutdown.
        Harness.test("an unrecognised reason is still the system") {
            let request = Oilbird.quitRequest(quitEvent(reason: 0x626F_6F74))
            Harness.expectTrue(
                !request.mayBeRefused,
                "a reason nobody recognised was read as a person pressing Quit")
            Harness.expectEqual(request, .system("reason boot"))
        }

        // The log is the only trace this decision leaves — everything else
        // about it is the absence of something — so the four characters
        // have to survive into it readably.
        Harness.test("an unprintable reason code falls back to its number") {
            Harness.expectEqual(Oilbird.quitRequest(quitEvent(reason: 1)), .system("reason 1"))
        }
    }
}
