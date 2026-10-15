import Foundation
import OilbirdCore
import OilbirdKit

func tintTests() {
    Harness.suite("Tint — tokens only, and it must fail to stock") {
        // The whole safety property: a renamed token is IGNORED and the page is
        // stock SonarQube. A selector would half-match and leave a hybrid.
        Harness.test("every override is a custom property, never a selector") {
            for key in Tint.tokens.keys {
                Harness.expectTrue(key.hasPrefix("--"), "\(key) is not a custom property")
            }
            let body = Tint.css
            Harness.expectTrue(
                !body.contains(".") && !body.contains("#echoes"),
                "the stylesheet contains a selector")
        }

        // ⚠ TWO blocks, in SonarQube's own selectors: its dark palette
        // out-specifies `:root`, so a single override loses and the dashboard
        // goes stock while Oilbird's chrome stays cream.

        // No selector of our own invention: one that half-matches after an
        // upgrade leaves a broken hybrid.
        Harness.test("the stylesheet uses SonarQube's own two theme selectors") {
            Harness.expectTrue(Tint.css.hasPrefix(Tint.lightSelector + " {"))
            Harness.expectTrue(Tint.css.contains(Tint.darkSelector + " {"))
            Harness.expectEqual(
                Tint.css.components(separatedBy: "{").count, 3,
                "the stylesheet has a block nobody declared")
        }

        // The whole reason the dark block exists: with only `:root`, the
        // dark theme's own declarations win on specificity and the tint is
        // silently absent in exactly the appearance the user chose.
        Harness.test("both themes are tinted, not only the light one") {
            Harness.expectTrue(
                Tint.css.contains("--echoes-color-surface-canvas-default: #262A36;"),
                "the dark ground is not in the stylesheet")
            Harness.expectEqual(
                Tint.light.keys.sorted(), Tint.dark.keys.sorted(),
                "one theme overrides a token the other does not, so they would diverge")
        }

        // A test of our output against our input can only agree with itself:
        // `--echoes-color-background-default` passed while that name was ours
        // and SonarQube defined no such token.
        Harness.test("the palette is deterministic, so a diff means a change") {
            Harness.expectEqual(Tint.css, Tint.css)
            Harness.expectTrue(Tint.css.contains("--echoes-color-surface-default: #F9F7F1;"))
        }

        // An unescaped quote or newline ends the JavaScript string literal
        // early, leaving a syntax error that silently paints nothing.
        Harness.test("the CSS is escaped for the string literal it is embedded in") {
            let script = Tint.script
            Harness.expectTrue(!script.contains("\n  --echoes"), "a raw newline survived")
            Harness.expectTrue(script.contains("\\n"), "newlines were not escaped")
        }

        Harness.test("quotes and backslashes cannot end the literal early") {
            let nasty = Tint.javaScriptString("it's a \\ backslash")
            Harness.expectTrue(nasty.contains("\\'"), "a quote was not escaped")
            Harness.expectTrue(nasty.contains("\\\\"), "a backslash was not escaped")
            Harness.expectTrue(nasty.hasPrefix("'") && nasty.hasSuffix("'"))
        }

        // ⚠ Three of seven token names were not tokens SonarQube defines. The
        // tint ignores a name it does not know, and that safety is what lets
        // the mistake ship.
        Harness.test("every token overridden is a token SonarQube defines") {
            guard let vocabulary = Tint.vocabulary() else {
                Harness.expectTrue(false, "the token vocabulary did not load")
                return
            }
            Harness.expectTrue(
                vocabulary.names.count > 300,
                "the vocabulary has only \(vocabulary.names.count) tokens; it looks truncated")
            for name in Set(Tint.light.keys).union(Tint.dark.keys).sorted() {
                Harness.expectTrue(
                    vocabulary.names.contains(name),
                    "\(name) is not defined by the pinned SonarQube, so overriding it paints nothing")
            }
        }

        // The vocabulary is a snapshot of one server version, so a bump that
        // does not regenerate it would validate a new palette against the
        // old server's names — the same silence, one release later.
        Harness.test("the vocabulary belongs to the SonarQube this build pins") {
            guard let vocabulary = Tint.vocabulary(),
                let entry = try? Manifest.bundled().entry(.sonarqube)
            else {
                Harness.expectTrue(false, "the vocabulary or the manifest did not load")
                return
            }
            Harness.expectEqual(
                vocabulary.version, entry.version,
                "the token list was taken from a different SonarQube than this build ships")
        }

        // The window size is chosen for a UI Oilbird does not control: below
        // the dashboard's 1200 breakpoint the right-hand column is cut off and
        // SonarQube does not reflow, so there is no scrollbar either.

        // ⚠ The other half of the `chrome` check, which compares Oilbird's
        // dark ground against these values: without them it has nothing to
        // compare and reports clean over a subject it never read.
        Harness.test("the recorded vocabulary carries both SonarQube palettes") {
            guard let vocabulary = Tint.vocabulary() else {
                Harness.expectTrue(false, "the vocabulary did not load")
                return
            }
            for key in [
                "light-surface", "light-canvas", "light-text", "light-border",
                "dark-surface", "dark-canvas", "dark-text", "dark-border",
            ] {
                let value = vocabulary.themeValue(key) ?? ""
                Harness.expectTrue(
                    value.hasPrefix("#"),
                    "\(key) is \(value.isEmpty ? "missing" : value); run `make tint-tokens`")
            }
        }

        Harness.test("the window is never narrower than the dashboard it embeds") {
            guard let vocabulary = Tint.vocabulary() else {
                Harness.expectTrue(false, "the vocabulary did not load")
                return
            }
            Harness.expectTrue(
                vocabulary.minimumViewport >= 1000,
                "the recorded breakpoint (\(vocabulary.minimumViewport)) looks unparsed")
            Harness.expectTrue(
                Oilbird.minimumWindowWidth >= vocabulary.minimumViewport,
                "the window may be sized to \(Oilbird.minimumWindowWidth), narrower than the "
                    + "\(vocabulary.minimumViewport) SonarQube needs — the dashboard would clip")
        }
    }
}
