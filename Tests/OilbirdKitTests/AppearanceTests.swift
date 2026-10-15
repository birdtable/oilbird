import Foundation
import OilbirdCore
import OilbirdKit

/// Light, dark, or the Mac's own choice — stored, and defaulted safely.
func appearancePreferenceTests() {
    Harness.suite("Appearance — one choice for the chrome and the dashboard") {
        Harness.test("the three choices are offered, with Auto first and default") {
            Harness.expectEqual(Preferences.Appearance.choices.count, 3)
            Harness.expectEqual(Preferences.Appearance.choices.first, .auto)
            Harness.expectEqual(
                Preferences.Stored().appearance, .auto,
                "a fresh install must follow the system rather than pick for the user")
            Harness.expectEqual(
                Preferences.Appearance.choices.map(\.label), ["Auto", "Light", "Dark"])
        }

        // ⚠ Only `auto` leaves the appearance unpinned. Pinning whichever one the
        // Mac happens to be wearing looks identical until the user changes their
        // mind with Oilbird open — the failure `Theme` ends.
        Harness.test("Auto pins nothing; Light and Dark pin something") {
            Harness.expectTrue(Preferences.Appearance.auto.followsSystem)
            Harness.expectTrue(!Preferences.Appearance.light.followsSystem)
            Harness.expectTrue(!Preferences.Appearance.dark.followsSystem)
        }

        Harness.test("the choice survives a restart") {
            let before = Preferences.load()
            defer { try? Preferences.save(before) }

            var stored = before
            stored.appearance = .dark
            try? Preferences.save(stored)
            Harness.expectEqual(
                Preferences.load().appearance, .dark,
                "a setting that has to be made again every launch is not a setting")

            stored.appearance = .auto
            try? Preferences.save(stored)
            Harness.expectEqual(Preferences.load().appearance, .auto)
        }

        // The migration, for the same reason every other field here has
        // one: a file written before this existed must not cost the user
        // anything, and a file written by a LATER build must not either.
        Harness.test("a file without the key, or with one this build cannot read, is Auto") {
            let before = Preferences.load()
            defer { try? Preferences.save(before) }

            for value in ["", "<key>appearance</key><string>sepia</string>"] {
                let plist = """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    <plist version="1.0">
                    <dict>
                        <key>idleTimeout</key>
                        <string>2h</string>
                        \(value)
                    </dict>
                    </plist>
                    """
                try? FileManager.default.createDirectory(
                    at: Paths.config.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? Data(plist.utf8).write(to: Paths.config)
                let read = Preferences.load()
                Harness.expectEqual(
                    read.appearance, .auto,
                    "an unreadable appearance should fall back, not be a value")
                Harness.expectEqual(
                    read.idleTimeout, .after(minutes: 120),
                    "the rest of the file was lost along with the appearance")
            }
        }
    }
}
