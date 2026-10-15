import Foundation
import OilbirdCore

func preferencesTests() {
    Harness.suite("Preferences — the idle timeout is a choice, not a verdict") {
        Harness.test("the default is the polite one") {
            try? FileManager.default.removeItem(at: Paths.config)
            Harness.expectEqual(Preferences.load().idleTimeout, .thirtyMinutes)
        }

        Harness.test("a choice survives being written and read") {
            for timeout in Preferences.IdleTimeout.presets + [.after(minutes: 45)] {
                try? Preferences.save(Preferences.Stored(idleTimeout: timeout))
                Harness.expectEqual(Preferences.load().idleTimeout, timeout)
            }
        }

        Harness.test("every option has a label a person can choose between") {
            for timeout in Preferences.IdleTimeout.presets + [.after(minutes: 45)] {
                Harness.expectNotEmpty(timeout.label, "for \(timeout)")
            }
        }

        // Interpolating `rawValue` into a fixed frame makes the one place the
        // idle policy is shown read "Stops after never", which says the
        // opposite of what it means in the case most likely to be checked.
        Harness.test("the menu sentence is a sentence in every case") {
            for timeout in Preferences.IdleTimeout.presets + [.after(minutes: 45)] {
                Harness.expectNotEmpty(timeout.menuSentence, "for \(timeout)")
                Harness.expectTrue(
                    !timeout.menuSentence.contains("after never"), timeout.menuSentence)
            }
            Harness.expectTrue(
                Preferences.IdleTimeout.never.menuSentence.lowercased().contains("never"),
                "never does not say so")
            Harness.expectTrue(
                Preferences.IdleTimeout.thirtyMinutes.menuSentence.contains("30m"),
                Preferences.IdleTimeout.thirtyMinutes.menuSentence)
        }

        // "never" is the absence of a limit, not a very large one. A very large
        // number would eventually fire.
        Harness.test("never means never, not eventually") {
            Harness.expectNil(Preferences.IdleTimeout.never.seconds)
            try? Preferences.save(Preferences.Stored(idleTimeout: .never))
            let longAgo = Date(timeIntervalSinceNow: -60 * 60 * 24 * 365)
            Harness.expectTrue(!Preferences.shouldStopWhenIdle(since: longAgo))
        }

        Harness.test("a timeout fires once it has elapsed, and not before") {
            try? Preferences.save(Preferences.Stored(idleTimeout: .thirtyMinutes))
            Harness.expectTrue(
                !Preferences.shouldStopWhenIdle(since: Date(timeIntervalSinceNow: -60)),
                "stopped after a minute")
            Harness.expectTrue(
                Preferences.shouldStopWhenIdle(since: Date(timeIntervalSinceNow: -31 * 60)),
                "did not stop after 31 minutes")
        }

        // Nothing here can corrupt anything, so defaults are safe. A malformed
        // PORT would be different -- which is why ports are not configurable.
        Harness.test("a malformed preferences file falls back to defaults") {
            try? FileManager.default.createDirectory(
                at: Paths.config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("not a plist".utf8).write(to: Paths.config)
            Harness.expectEqual(Preferences.load().idleTimeout, .thirtyMinutes)
            try? FileManager.default.removeItem(at: Paths.config)
        }

        // ⚠ Any number of minutes, not three fixed choices: the interval is a
        // user setting, and 45 minutes is an ordinary thing to want.
        Harness.test("any interval a person types is understood") {
            let cases: [(String, Preferences.IdleTimeout?)] = [
                ("45", .after(minutes: 45)),
                ("45m", .after(minutes: 45)),
                ("30m", .after(minutes: 30)),
                ("2h", .after(minutes: 120)),
                ("never", .never),
                ("  90  ", .after(minutes: 90)),
                ("NEVER", .never),
                // Below the floor: refused, not silently rounded up.
                ("1", nil),
                ("4", nil),
                ("0", nil),
                ("banana", nil),
                ("", nil),
            ]
            for (text, expected) in cases {
                Harness.expectEqual(
                    Preferences.IdleTimeout(rawValue: text), expected, "parsing '\(text)'")
            }
        }

        // The stored form is the string the old enum used, so a preferences
        // file written by an earlier build decodes unchanged — a user
        // upgrading mid-session must not be handed a broken settings file.
        Harness.test("a preferences file from the old build still loads") {
            for (stored, expected) in [
                ("30m", Preferences.IdleTimeout.after(minutes: 30)),
                ("2h", .after(minutes: 120)),
                ("never", .never),
            ] {
                let json = Data(#"{"idleTimeout":"\#(stored)"}"#.utf8)
                guard
                    let decoded = try? JSONDecoder().decode(Preferences.Stored.self, from: json)
                else {
                    Harness.expectTrue(false, "a stored '\(stored)' failed to decode")
                    continue
                }
                Harness.expectEqual(decoded.idleTimeout, expected)
            }
        }

        // A value already stored below the floor is honoured: it was legal
        // when written, and refusing it would leave a settings file that
        // cannot be loaded at all. Only new input is held to the floor.
        Harness.test("a stored value below the floor still loads") {
            let json = Data(#"{"idleTimeout":"2m"}"#.utf8)
            let decoded = try? JSONDecoder().decode(Preferences.Stored.self, from: json)
            Harness.expectEqual(decoded?.idleTimeout, .after(minutes: 2))
            Harness.expectNil(
                Preferences.IdleTimeout(rawValue: "2m"), "the floor let new input through")
        }

        Harness.test("an interval round-trips through its stored form") {
            for timeout in [
                Preferences.IdleTimeout.after(minutes: 45), .after(minutes: 120),
                .never,
            ] {
                Harness.expectEqual(
                    Preferences.IdleTimeout(rawValue: timeout.rawValue) ?? .never, timeout,
                    "'\(timeout.rawValue)' did not survive the round trip")
            }
        }

        // ⚠ EVERY property, and the fixture cannot go stale: `Stored` writes
        // its own coding keys, encoder and decoder, so adding one is three
        // edits and missing one says `saved` and writes nothing.

        // The `prefs` check compares the three lists; this asks the same of the
        // BEHAVIOUR, which is stronger, since a property can be in all three
        // and still not survive.

        // `Mirror` enumerates the stored properties at run time, so a property
        // added without a line in `changed` is caught by the first assertion
        // and named.
        Harness.test("every stored property survives a write and a read") {
            var changed = Preferences.Stored()
            changed.idleTimeout = .after(minutes: 17)
            changed.lastPorts = Preferences.LastPorts(web: 9111, search: 9112)
            changed.menuBarIcon = false
            changed.stayResident = false
            changed.projectNames = ["/tmp/probe": "Probe"]
            changed.appearance = .dark
            changed.webMemoryMegabytes = 3072
            changed.pinnedWebPort = 9333
            changed.neverAnalysed = ["**/probe-never/**"]
            changed.treatedAsTests = ["**/probe-tests/**"]

            let defaults = Mirror(reflecting: Preferences.Stored())
            let mutated = Mirror(reflecting: changed)
            for (fallback, altered) in zip(defaults.children, mutated.children) {
                let name = altered.label ?? "an unnamed property"
                Harness.expectTrue(
                    String(describing: fallback.value) != String(describing: altered.value),
                    "`\(name)` is still at its default — this test does not cover it, so "
                        + "nothing here would notice it failing to save")
            }

            guard let json = try? JSONEncoder().encode(changed) else {
                Harness.expectTrue(false, "a Stored with every property set would not encode")
                return
            }
            guard let read = try? JSONDecoder().decode(Preferences.Stored.self, from: json) else {
                Harness.expectTrue(false, "a Stored with every property set would not decode")
                return
            }
            for (written, came) in zip(mutated.children, Mirror(reflecting: read).children) {
                Harness.expectEqual(
                    String(describing: came.value), String(describing: written.value),
                    "`\(came.label ?? "an unnamed property")` did not survive the round trip")
            }
        }
    }
}
