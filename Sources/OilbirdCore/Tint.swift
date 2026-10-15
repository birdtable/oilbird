import Foundation

/// The palette Oilbird paints over SonarQube's dashboard, and the script that
/// carries it.
///
/// **Tokens only, never selectors.** SonarQube ships a large set of
/// `--echoes-*` CSS custom properties, and overriding those degrades safely: a
/// token that no longer exists means the override is simply ignored and the
/// page is stock SonarQube. A selector override that half-matches after an
/// upgrade leaves a broken hybrid, which is worse than never having tinted.
/// **Fail to stock, never to half-styled.**
///
/// Permitted by the mission: Oilbird may tint
/// SonarQube's UI and may not restyle it — no markup rewriting, no hidden
/// controls, no changed wording.
///
/// This lives in the core rather than the app because it is string logic with
/// a testable shape, and testable logic belongs where the test suites reach.
public enum Tint {
    /// ⚠ Every name here must exist in the SonarQube this build pins.
    ///
    /// Three of the original seven did not — `--echoes-color-background-
    /// default`, `-default-hover` and `-neutral-weak-default` are not tokens
    /// SonarQube 26.9 defines. The page background is `surface`, not
    /// `background`. Because the design fails to stock rather than to
    /// half-styled, the result was a dashboard that looked entirely untinted
    /// except for the accent colour, with nothing anywhere saying why.
    ///
    /// `tintTests` now reads the CSS out of the installed server and fails
    /// on any name that is not in it, so the safe degradation can no longer
    /// hide a typo.
    public static let tokens: [String: String] = light

    public static let light: [String: String] = [
        // The page and its panels.
        "--echoes-color-surface-default": "#F9F7F1",
        "--echoes-color-surface-canvas-default": "#F2EFE7",
        "--echoes-color-surface-hover": "#F2EFE7",
        // The accent — the one part of the original set that was correct,
        // which is why the buttons were terracotta while nothing else moved.
        "--echoes-color-background-accent-default": "#B4623A",
        "--echoes-color-background-accent-hover": "#8F4D2E",
        "--echoes-color-border-weak": "#E6E1D6",
        "--echoes-color-border-bold": "#DCD6C8",
    ]

    /// ⚠ **SonarQube 26.9 has a dark theme, follows the system into it, and
    /// this file had no answer for that.** Its dark palette is declared at
    /// `html[data-echoes-theme=dark]`, which out-specifies the `:root` the
    /// tint above wrote — so in dark mode every override was overridden and
    /// the dashboard went stock while Oilbird's chrome stayed cream: in dark
    /// mode SonarQube turned dark and Oilbird's frame did not. Forcing the
    /// page light was the wrong way out of it: the user had chosen dark.
    ///
    /// Same token names, so nothing new can be misspelled that the light
    /// set would not already catch, and the same safe degradation: a name
    /// SonarQube stops defining leaves that one value stock.
    public static let dark: [String: String] = [
        "--echoes-color-surface-default": "#2F3444",
        "--echoes-color-surface-canvas-default": "#262A36",
        "--echoes-color-surface-hover": "#343948",
        "--echoes-color-background-accent-default": "#D4794C",
        "--echoes-color-background-accent-hover": "#E08A5E",
        "--echoes-color-border-weak": "#3A3F4E",
        "--echoes-color-border-bold": "#4A5060",
    ]

    /// The selectors the two blocks are written under.
    ///
    /// SonarQube's own, character for character, so each lands at the same
    /// specificity as the declaration it is replacing and wins on document
    /// order — the style element is appended to `documentElement`, after
    /// everything in `<head>`. A selector of our own invention would either
    /// lose to theirs or, worse, win in only some of the places theirs
    /// applies.
    public static let lightSelector = ":root,[data-echoes-theme=light]"
    public static let darkSelector = "html[data-echoes-theme=dark],[data-echoes-theme=dark]"

    /// The tokens the pinned SonarQube actually defines, and the version
    /// they came from.
    ///
    /// Checked in rather than read from the install, so the gate runs
    /// hermetically and in CI — a test that can only run where SonarQube
    /// happens to be installed is a test that does not run.
    ///
    /// The version is carried with it and asserted against the manifest, so
    /// a server bump without regenerating this list fails rather than
    /// validating the new palette against the old server's vocabulary. That
    /// is the whole reason this is a file and not a comment.
    public struct Vocabulary: Sendable {
        public let version: String
        public let names: Set<String>
        /// The width SonarQube's own content container is built for.
        ///
        /// ⚠ `.sw-container{max-width:1280px}`, not the lowest media-query
        /// breakpoint. The breakpoint (1200) is where the stylesheet starts
        /// making adjustments; the container is how wide the layout
        /// actually is, and a window matching the breakpoint still showed a
        /// horizontal scrollbar because the content is wider than the point
        /// at which the CSS begins to care.
        ///
        /// Below this the UI does not reflow — it is cut off. Oilbird chose
        /// a window size for a UI it does not control, twice, before asking
        /// that UI what it needed.
        public let minimumViewport: CGFloat

        /// The grounds and text of both SonarQube themes, keyed
        /// `dark-surface`, `light-text` and so on.
        ///
        /// ⚠ Recorded because Oilbird's chrome is matched to them and had
        /// no way of knowing when they moved. SonarQube 26.9 follows the
        /// system into a dark theme; Oilbird did not, and the product was a
        /// cream frame around a `#2a2f40` page. Matching once fixes that
        /// once — recording the values is what makes a restyle in a future
        /// SonarQube a red gate rather than a screenshot somebody happens
        /// to take.
        public let themeValues: [String: String]

        public func themeValue(_ key: String) -> String? { themeValues[key] }
    }

    public static func vocabulary() -> Vocabulary? {
        guard let url = Bundled.url(named: "sonarqube-tokens", extension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        var version = ""
        var names: Set<String> = []
        var minimumViewport: CGFloat = 0
        var themeValues: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") {
                if line.contains("SonarQube"), let found = line.split(separator: " ").last {
                    version = String(found).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                }
                if line.hasPrefix("# min-viewport "), let found = line.split(separator: " ").last {
                    minimumViewport = CGFloat(Double(found) ?? 0)
                }
                if line.hasPrefix("# theme ") {
                    let parts = line.split(separator: " ")
                    if parts.count == 4 { themeValues[String(parts[2])] = String(parts[3]) }
                }
                continue
            }
            names.insert(String(line).trimmingCharacters(in: .whitespaces))
        }
        return Vocabulary(
            version: version, names: names, minimumViewport: minimumViewport,
            themeValues: themeValues)
    }

    public static var css: String {
        block(lightSelector, light) + "\n" + block(darkSelector, dark)
    }

    static func block(_ selector: String, _ values: [String: String]) -> String {
        let body = values.sorted { $0.key < $1.key }
            .map { "  \($0.key): \($0.value);" }
            .joined(separator: "\n")
        return "\(selector) {\n\(body)\n}"
    }

    /// The injected script.
    ///
    /// The CSS is embedded as a JavaScript string literal, so every quote,
    /// backslash and newline in it must be escaped — an unescaped one would
    /// end the literal early and leave a syntax error that silently paints
    /// nothing.
    /// Controls Oilbird removes from SonarQube's own UI, and the exact
    /// string in the shipped web app that each one is anchored to.
    ///
    /// ⚠ **This is a deliberate exception to "may not hide controls".** That rule exists
    /// because a selector which HALF-matches leaves a broken hybrid, and it
    /// is right about that. The exception is narrow and gated: each entry
    /// names the route it hides, the `overrides` check verifies that route
    /// still appears EXACTLY ONCE in the web app SonarQube ships, and a
    /// build where it appears zero times or twice goes red.
    ///
    /// ⚠ Anchored on the ROUTE, never on a class. A route is semantic and a
    /// class is cosmetic — and the danger is not theoretical: the same page
    /// links to `marketplace.visualstudio.com` and to a
    /// `?referrer=sonarqube-marketplace` trial page, so `[href*=marketplace]`
    /// would take two controls nobody meant to touch. `=` and not `*=`.
    ///
    /// Zero matches means SonarQube moved the page: the rule then hides
    /// nothing and the page is served as stock, which is the correct
    /// direction to fail in.
    public struct Override: Sendable, Equatable {
        /// What the override is anchored to.
        ///
        /// ⚠ Two kinds, because one kind was not enough and the difference
        /// was nearly a bug. Hiding the four items of the Security group
        /// leaves the group itself — an accordion that opens onto nothing.
        /// That is half-styled, and it is worse than
        /// the page it replaced. A group is hidden as a group.
        public enum Anchor: Sendable, Equatable {
            /// A sidebar link, by the route it points at.
            case route(String)
            /// A whole sidebar group, by the `data-component` it carries.
            case group(String)
        }

        public let anchor: Anchor
        /// Why this one is gone, for the person reading the file in a year.
        public let because: String
        /// How many times the anchor is expected to appear in the web app.
        ///
        /// Declared rather than assumed, so that a SonarQube which adds or
        /// moves one goes red instead of silently hiding a different control
        /// — or nothing at all.
        public let links: Int

        public init(route: String, because: String, links: Int = 1) {
            self.init(anchor: .route(route), because: because, links: links)
        }

        public init(group: String, because: String) {
            self.init(anchor: .group(group), because: because, links: 1)
        }

        public init(anchor: Anchor, because: String, links: Int) {
            self.anchor = anchor
            self.because = because
            self.links = links
        }

        /// Anchored, so it matches the one control and nothing near it.
        public var selector: String {
            switch anchor {
            case .route(let route): "a[href=\"\(route)\"]"
            case .group(let component): "[data-component=\"\(component)\"]"
            }
        }
    }

    /// ⚠ Each of these is a control that cannot do anything on one person's
    /// machine — not a control somebody might not want. If it is useless,
    /// it does not get the space.
    ///
    /// ⚠ A route is not enough on its own to know what it hides.
    /// `/admin/settings?category=almintegration` looked like a safe fourth
    /// entry here — the gate found four occurrences and they were real. All
    /// four turned out to be inline links inside *Create Project* warnings
    /// ("ask an administrator to configure DevOps integration"), not a
    /// sidebar item at all: hiding them would have blanked the explanation
    /// in a wizard while leaving the settings page exactly where it was.
    /// the `overrides` check now requires each route to be a
    /// `SidebarNavigation` entry, which is what tells a nav link apart from
    /// a sentence that happens to link somewhere.
    /// The SonarQube these overrides were last checked against, by hand, on a
    /// machine with an engine installed.
    ///
    /// ⚠ This exists because the `overrides` check CANNOT run in CI. It reads
    /// the unpacked web app, hosted runners have no install step and must
    /// never have one, so on every push the check says NOT CHECKED and passes.
    /// That is the honest answer to "did you verify this" and it is a poor
    /// answer to "is it still true after the bump". This is the half that does
    /// run everywhere: the check compares this against the pinned version in
    /// `manifest.json` and fails the moment they differ. A SonarQube bump
    /// therefore cannot land until somebody has run the check with an engine
    /// and moved this line, which is the only evidence that means anything.
    public static let overridesVerifiedAgainst = "26.10.0.133078"

    public static let overrides: [Override] = [
        Override(
            route: "/admin/marketplace",
            because:
                "Its plugin half renders `marketplace.not_activated` because Oilbird leaves "
                + "the update centre off, and SonarQube's catalogue carries no build for "
                + "Community Build in any case — every compatibility range in it names 9.x, "
                + "10.x or the commercial 2025/2026 line. The rest of the page advertises "
                + "the paid editions. Oilbird answers the route with where plugins actually "
                + "go."),
        Override(
            group: "administration-sidebar-security",
            because:
                "Users, Groups, Global Permissions and Permission Templates — the whole "
                + "group and nothing else is in it. One machine, one person, one "
                + "administrator who is also the only reader, and Oilbird holds the "
                + "credential. Permission templates decide what a NEW project grants to "
                + "groups that do not exist."),
        Override(
            route: "/admin/settings/encryption",
            because: "A secret key for encrypting settings values — SMTP passwords, DevOps "
                + "tokens. Nothing on a local instance has a secret worth sealing."),
    ]

    /// The rules that take those controls off the page.
    ///
    /// `display:none` on the anchor's list item where there is one, and on
    /// the anchor otherwise — written as one selector list so a SonarQube
    /// that changes the surrounding markup still removes the link itself.
    public static var overrideCSS: String {
        overrides
            .map { "\($0.selector), li:has(\($0.selector)) { display: none !important; }" }
            .joined(separator: "\n")
    }

    public static var script: String {
        """
        (function () {
          var style = document.createElement('style');
          style.textContent = \(javaScriptString(css + "\n" + overrideCSS));
          document.documentElement.appendChild(style);
        })();
        """
    }

    public static func javaScriptString(_ text: String) -> String {
        let escaped =
            text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "'\(escaped)'"
    }
}
