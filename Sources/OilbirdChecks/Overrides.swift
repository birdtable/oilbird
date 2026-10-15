import Foundation

/// Every control Oilbird removes is still exactly where it thinks it is.
///
/// Oilbird tints SonarQube and never restyles it, so hiding controls is
/// forbidden by default: a selector that HALF-matches leaves a broken
/// hybrid — worse than never having touched the page. That rule is right,
/// and this gate is the condition under which a narrow exception to it is
/// safe: each override names a ROUTE, and the route must appear EXACTLY
/// ONCE in the web app SonarQube actually ships.
///
///   zero  SonarQube moved the page. The rule now hides nothing, so the page
///         is served as stock. That is the correct direction to fail in, but
///         it is still a finding: the override is dead and the page is back.
///   many  the dangerous one. Something else on the page answers the same
///         string, and `display:none` would take a control nobody meant to
///         touch. Verified real: this page also links to
///         marketplace.visualstudio.com and to a
///         `?referrer=sonarqube-marketplace` trial page, which is why the
///         selectors are `=` and never `*=`.
///
/// Read from the INSTALLED web app rather than from a recorded copy, for the
/// same reason `Chrome` reads the installed CSS: the thing that can change
/// underneath us is the thing to measure.
struct Overrides: Check {
    let name = "overrides"
    let holds = "every hidden control is exactly where the override says it is"

    private static let block = Rx(
        "overrides: \\[Override\\] = \\[(.*?)\\n    \\]", [.dotMatchesLineSeparators])
    private static let row = Rx("Override\\(")
    private static let entry = Rx(
        "Override\\((.*?)\\)(?=,\\s*$|,\\n|\\n\\s*\\])",
        [.dotMatchesLineSeparators, .anchorsMatchLines])
    private static let route = Rx("route:\\s*\"([^\"]+)\"")
    private static let group = Rx("group:\\s*\"([^\"]+)\"")
    private static let links = Rx("links:\\s*(\\d+)")

    /// Where the pinned server's web app is unpacked, read out of `Paths`
    /// rather than written down again.
    ///
    /// ⚠ The Python this replaces kept its own copy of the container path. It
    /// was never wrong, and it was a second place to edit that no rule held —
    /// the rule being the one this directory's own `paths` gate enforces on
    /// everything else. Parsing the one declaration is both shorter and the
    /// thing the product does.
    private static let cacheRoot = Rx("static var cache: URL \\{\\s*library\\(\"([^\"]+)\"\\)")
    private static let verifiedAgainst = Rx("overridesVerifiedAgainst = \"([^\"]+)\"")
    /// The pinned SonarQube, read out of the manifest rather than restated.
    private static let pinned = Rx(
        "\"sonarqube\"\\s*:\\s*\\{[^}]*?\"version\"\\s*:\\s*\"([^\"]+)\"",
        [.dotMatchesLineSeparators])
    private static let manifest = "Sources/OilbirdCore/Resources/manifest.json"
    private static let containerVariable = Rx(
        "containerRootVariable = \"([A-Z_]+)\"")

    private struct Anchor {
        enum Kind { case route, group }
        let kind: Kind
        let value: String
        /// Declared rather than assumed, so a SonarQube which adds, moves or
        /// drops one goes red instead of hiding something else.
        let expected: Int
    }

    private static func webApp() throws -> URL {
        let paths = try Checkout.read(Checkout.core("Paths")) as NSString
        guard let suffix = cacheRoot.first(in: paths)?.group(1) else {
            throw Shape("Paths no longer declares its cache root as `library(\"…\")`")
        }
        guard let variable = containerVariable.first(in: paths)?.group(1) else {
            throw Shape("Paths no longer declares a container root variable")
        }
        let override = ProcessInfo.processInfo.environment[variable].flatMap {
            $0.isEmpty ? nil : URL(filePath: $0)
        }
        let home = override ?? FileManager.default.homeDirectoryForCurrentUser
        return
            home
            .appending(path: "Library")
            .appending(path: suffix)
            .appending(path: "sonarqube/web/js")
    }

    func selfTest() throws {
        guard Self.route.matches("Override(route: \"/admin/marketplace\", links: 1)") else {
            throw SelfTest("an override's route was not read")
        }
        guard Self.links.first(in: "links: 2" as NSString)?.group(1) == "2" else {
            throw SelfTest("a declared link count was not read")
        }
        // The sidebar pattern must tell a nav entry from a sentence linking to
        // the same place, in either quoting (26.10 minifies to backticks), or
        // the rule is "contains the string" wearing a longer pattern.
        let nav = "SidebarNavigation.Item,{to:\"/admin/marketplace\""
        let backticked = "SidebarNavigation.Item,{Icon:l,to:`/admin/marketplace`"
        let prose = "Link,{to:\"/admin/marketplace\""
        guard Self.sidebar("/admin/marketplace").matches(nav),
            Self.sidebar("/admin/marketplace").matches(backticked),
            !Self.sidebar("/admin/marketplace").matches(prose)
        else {
            throw SelfTest("the sidebar pattern does not separate a nav item from a link")
        }
    }

    /// ⚠ Counted as a SIDEBAR link target, not as any occurrence of the string
    /// and not even as any `to:"…"`. A route appears in the router's own table
    /// as well as in the sidebar, so counting occurrences measures something
    /// that is not what renders: `/admin/permission_templates` appears twice
    /// and is one link. The first version of this counted occurrences and
    /// happened to be right about `/admin/marketplace`, which spells its table
    /// entry differently.
    ///
    /// ⚠ And `to:"…"` alone is still not enough. All four occurrences of
    /// `to:"/admin/settings?category=almintegration"` are inline links inside
    /// *Create Project* warnings — "ask an administrator to configure DevOps
    /// integration" — and none is a sidebar item. An override on that route
    /// passed the count and would have blanked the explanation in a wizard
    /// while leaving the settings page untouched. `SidebarNavigation`
    /// immediately before the target is what tells a nav entry apart from a
    /// sentence that happens to link somewhere.
    private static func sidebar(_ anchor: String) -> Rx {
        Rx("SidebarNavigation(?:\\.[A-Za-z]+)*,\\{[^{}]*?to:([\"`])\(escaped(anchor))\\1")
    }

    private static func escaped(_ text: String) -> String {
        NSRegularExpression.escapedPattern(for: text)
    }

    func run() throws -> Report {
        let tint = try Checkout.read(Checkout.core("Tint")) as NSString
        guard let found = Self.block.first(in: tint), let body = found.group(1) else {
            throw Shape("Tint.overrides is gone, or has changed shape")
        }
        let rows = body as NSString
        let declared = Self.row.hits(in: rows).count

        var anchors: [Anchor] = []
        for hit in Self.entry.hits(in: rows) {
            guard let text = hit.group(1) else { continue }
            let subject = text as NSString
            let expected = Self.links.first(in: subject)?.group(1).flatMap(Int.init) ?? 1
            if let route = Self.route.first(in: subject)?.group(1) {
                anchors.append(Anchor(kind: .route, value: route, expected: expected))
            } else if let group = Self.group.first(in: subject)?.group(1) {
                anchors.append(Anchor(kind: .group, value: group, expected: expected))
            }
        }

        // ⚠ A parser that silently drops an entry ships an override nobody
        // verified: a lookahead missing the last row reported "2 override(s)"
        // against three, and nothing about that looked wrong.
        guard anchors.count == declared else {
            throw Shape(
                "Tint.swift declares \(declared) override(s) but only \(anchors.count) could "
                    + "be read — the rest would ship unverified")
        }

        // ⚠ The one arm that runs everywhere, CI included. Without it a bump is
        // caught only by somebody remembering to run `make lint` where an
        // engine is installed.
        guard let checked = Self.verifiedAgainst.first(in: tint)?.group(1) else {
            throw Shape("Tint.overridesVerifiedAgainst is gone, or has changed shape")
        }
        guard
            let version = Self.pinned.first(in: try Checkout.read(Self.manifest) as NSString)?
                .group(1)
        else {
            throw Shape("the manifest no longer pins a SonarQube version this can read")
        }
        var report = Report(summary: "")
        if checked != version {
            report.findings.append(
                "the overrides were verified against SonarQube \(checked) and this build pins "
                    + "\(version). Run `make lint` on a machine with an engine, confirm every "
                    + "route is still exactly where it says, then move "
                    + "`overridesVerifiedAgainst`")
        }

        guard !anchors.isEmpty else {
            // Nothing hidden is a legitimate state — the exception is meant to
            // stay small — but say so rather than pass silently.
            report.summary = "no overrides declared; nothing to hold"
            report.skipped = true
            return report
        }

        let web = try Self.webApp()
        guard Checkout.isDirectory(web.path) else {
            // ⚠ Not a failure, and said LOUDLY. CI has no install step and must
            // never have one, so the web app is absent on every hosted runner
            // and failing here fails the build for everyone.

            // Passing silently would be worse: a check that checks nothing
            // while reading as green. So it passes and says, in the log, that
            // the overrides were not checked at all.
            report.summary = "NOT CHECKED — no installed web app at \(web.path)"
            report.notes.append(
                "The overrides are verified only on a machine that has run `oilbird install`.")
            report.skipped = true
            return report
        }

        let bundles =
            (try? FileManager.default.contentsOfDirectory(at: web, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "js" } ?? []
        guard !bundles.isEmpty else { throw Shape("no javascript under \(web.path)") }
        let texts = bundles.compactMap { try? String(contentsOf: $0, encoding: .utf8) }

        for anchor in anchors {
            let pattern: Rx
            let anywhere: Rx
            switch anchor.kind {
            case .route:
                pattern = Self.sidebar(anchor.value)
                anywhere = Rx("to:\"\(Self.escaped(anchor.value))\"")
            case .group:
                // A group is matched by the handle the accordion carries.
                pattern = Rx("\"data-component\":([\"`])\(Self.escaped(anchor.value))\\1")
                anywhere = pattern
            }
            let hits = texts.reduce(0) { $0 + pattern.hits(in: $1 as NSString).count }
            let loose = texts.reduce(0) { $0 + anywhere.hits(in: $1 as NSString).count }

            if hits == 0 && loose > 0 && anchor.kind == .route {
                report.findings.append(
                    "'\(anchor.value)' is linked \(loose) time(s) but never from the sidebar — "
                        + "those are links inside the page, and hiding them would take text "
                        + "nobody meant to touch while leaving the control itself in place")
            } else if hits == 0 {
                report.findings.append(
                    "'\(anchor.value)' appears nowhere in the shipped web app — SonarQube "
                        + "moved it, so the override now hides nothing and the page is back")
            } else if hits != anchor.expected {
                report.findings.append(
                    "'\(anchor.value)' is declared as \(anchor.expected) and the web app now "
                        + "has \(hits) — the selector covers a different set of controls than "
                        + "it was written for")
            }
        }
        report.summary = "\(anchors.count) override(s) against \(bundles.count) bundles"
        return report
    }
}
