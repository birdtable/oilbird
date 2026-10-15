import Foundation
import OilbirdKit

/// What a person is shown when Oilbird names a file.
///
/// ⚠ **These exist because a screenshot cannot fail.** A pane checked only
/// in pictures taken under a short home directory can ship a row that wraps
/// across its own control under a long one, and no test looks at a single
/// character of the difference. Every length below is written down rather
/// than read from the machine running the suite, so a short user name cannot
/// make this green.
func displayPathTests() {
    // The length that wraps, and the reason these tests exist. The name is
    // synthetic and the LENGTH is not: thirty-three characters is what an
    // email-style user name costs.
    let longHome = "/Users/firstname.last@example.com"

    Harness.suite("Display paths — a home directory is a tilde") {
        // The row's own geometry, worked out here because a suite cannot lay
        // out a window: 361pt of usable card at 0.6em and 10.5pt fits 57
        // characters. The full helper path under that home is 83.
        let oneLine = 57

        Harness.test("an 83-character path under a long home fits on one line once shortened") {
            let real = longHome + "/Applications/Oilbird.app/Contents/Helpers/oilbird"
            Harness.expectEqual(real.count, 83, "the case under test changed length")
            let shown = Oilbird.displayPath(real, relativeTo: longHome)
            Harness.expectEqual(
                shown, "~/Applications/Oilbird.app/Contents/Helpers/oilbird")
            Harness.expectTrue(
                shown.count <= oneLine,
                "\(oneLine) characters is one line of that row; \(shown.count) wraps again")
        }

        Harness.test("a much longer path still loses the home") {
            let deep =
                longHome + "/src/oilbird/.build/release/"
                + "Oilbird.app/Contents/Helpers/oilbird-mcp"
            let shown = Oilbird.displayPath(deep, relativeTo: longHome)
            Harness.expectTrue(
                shown.hasPrefix("~"), "a long path was left absolute: \(shown)")
            Harness.expectEqual(shown.count, deep.count - longHome.count + 1)
            Harness.expectTrue(
                !shown.contains(longHome), "the home directory survived in \(shown)")
        }

        // ⚠ The one that a `hasPrefix` alone gets wrong. A home is a
        // prefix of `<home>-backup`, and abbreviating on that would hand
        // back `~-backup/...`, a path to a file that does not exist.
        Harness.test("a sibling that merely starts the same is left alone") {
            let sibling = longHome + "-backup/Applications/Oilbird.app"
            Harness.expectEqual(
                Oilbird.displayPath(sibling, relativeTo: longHome), sibling)
        }

        Harness.test("a path outside the home directory is untouched") {
            for outside in [
                "/usr/local/bin/oilbird",
                "/Applications/Oilbird.app/Contents/Helpers/oilbird",
                "/Users/someone-else/Applications/Oilbird.app",
                "/Library/Application Support/Oilbird",
            ] {
                Harness.expectEqual(
                    Oilbird.displayPath(outside, relativeTo: longHome), outside,
                    "\(outside) is not under \(longHome) and must not be shortened")
            }
        }

        Harness.test("the home directory itself is one character") {
            Harness.expectEqual(Oilbird.displayPath(longHome, relativeTo: longHome), "~")
        }

        // A home with a trailing separator is what a path typed by hand
        // looks like half the time, and it must not double the separator.
        Harness.test("a trailing separator on the home changes nothing") {
            Harness.expectEqual(
                Oilbird.displayPath(longHome + "/Library", relativeTo: longHome + "/"),
                "~/Library")
        }

        // Refusing rather than guessing: with no home there is no prefix to
        // remove, and returning "~" for everything would be worse than
        // showing the truth.
        Harness.test("an empty home leaves every path absolute") {
            Harness.expectEqual(
                Oilbird.displayPath("/usr/local/bin/oilbird", relativeTo: ""),
                "/usr/local/bin/oilbird")
        }

        Harness.test("the real home is the default, and it is applied") {
            let inside = NSHomeDirectory() + "/Library/Caches/Oilbird"
            Harness.expectEqual(Oilbird.displayPath(inside), "~/Library/Caches/Oilbird")
        }
    }
}

/// ⚠ The pane handed out a path inside `dist/Oilbird.app`, which is
/// the build output — `make app` begins `rm -rf "$(APP)"`, so that binary is
/// deleted and recreated on every build. It was pasted into a client before
/// anyone noticed.
func installLocationTests() {
    Harness.suite("Where Oilbird is running from, and whether to trust the path") {
        let home = "/Users/firstname.last@example.com"

        Harness.test("Applications is somewhere a path may be written down") {
            for parent in ["/Applications", "\(home)/Applications"] {
                Harness.expectEqual(
                    Oilbird.installLocation(
                        of: URL(filePath: "\(parent)/Oilbird.app"), home: home),
                    .stable, "\(parent) should be trusted")
            }
        }

        // ⚠ The VERDICT is asserted, never the path: comparing payloads goes
        // red on a Desktop redirected into OneDrive, because resolving
        // symlinks is correct and the test was what was wrong.
        Harness.test("a build directory, a download and a checkout are not") {
            let volatilePlaces = [
                "\(home)/src/oilbird/dist",
                "\(home)/Downloads",
                "\(home)/Desktop",
                "/Volumes/Oilbird",
            ]
            for parent in volatilePlaces {
                let verdict = Oilbird.installLocation(
                    of: URL(filePath: "\(parent)/Oilbird.app"), home: home)
                guard case .volatile = verdict else {
                    Harness.expectTrue(false, "\(parent) was trusted, and should not be")
                    continue
                }
                Harness.expectTrue(true, "\(parent) is not a place to keep an app")
            }
        }

        // The build-output path itself, payload and all — this one cannot
        // be redirected out from under the assertion.
        Harness.test("the build output names itself in the warning") {
            let dist = "\(home)/src/oilbird/dist"
            Harness.expectEqual(
                Oilbird.installLocation(of: URL(filePath: "\(dist)/Oilbird.app"), home: home),
                .volatile(dist))
        }

        // A directory whose name merely starts the same is a different
        // directory — the `hasPrefix` bug, which this must not have.
        Harness.test("a lookalike directory is not Applications") {
            Harness.expectEqual(
                Oilbird.installLocation(
                    of: URL(filePath: "\(home)/Applications-old/Oilbird.app"), home: home),
                .volatile("\(home)/Applications-old"))
            Harness.expectEqual(
                Oilbird.installLocation(
                    of: URL(filePath: "/Applications/Nested/Oilbird.app"), home: home),
                .volatile("/Applications/Nested"),
                "a subfolder of Applications is not Applications")
        }
    }
}
