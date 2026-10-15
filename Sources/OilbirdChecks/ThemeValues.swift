import Foundation

/// The handful of values Oilbird's own chrome has to agree with.
///
///     oilbird-checks theme-values <sonarqube-web-css-directory>
///
/// `make tint-tokens` appends what this prints to
/// `Sources/OilbirdCore/Resources/sonarqube-tokens.txt`, beside the token
/// names and the `# min-viewport` line, for the same reason those are there:
/// the value is read out of the pinned server rather than remembered, so a
/// bump that restyles the dashboard cannot leave Oilbird's frame quietly
/// wrong.
///
/// SonarQube 26.9 declares two complete palettes in `echoes-*.css`, one per
/// theme, scoped by attribute selector. It follows `prefers-color-scheme` into
/// the dark one by default — which is how the product came to be a cream frame
/// around a `#2a2f40` page.
///
/// Not a gate: this generates, it does not hold. `Chrome` is the gate, and it
/// reads what this wrote.
enum ThemeValues {
    /// The two selectors SonarQube writes its palettes under, character for
    /// character. Oilbird's tint reuses them so each override lands at the
    /// same specificity as the declaration it replaces.
    private static let themes = [
        (name: "light", selector: ":root,[data-echoes-theme=light]"),
        (name: "dark", selector: "html[data-echoes-theme=dark],[data-echoes-theme=dark]"),
    ]

    /// What the chrome has to agree with, and nothing else.
    ///
    /// BOTH grounds, deliberately. `html,body{background-color:#fff!important}`
    /// is still in `main-*.css` in both themes, so the visible page ground in
    /// dark is painted by the app shell over the top of it and is one of these
    /// two — and which one cannot be settled by reading the stylesheets.
    /// Oilbird's chrome is therefore held within tolerance of BOTH, which is a
    /// stronger promise than guessing right would have been.
    private static let wanted = [
        (role: "surface", token: "--echoes-color-surface-default"),
        (role: "canvas", token: "--echoes-color-surface-canvas-default"),
        (role: "text", token: "--echoes-color-text-default"),
        (role: "border", token: "--echoes-color-border-weak"),
    ]

    private static let declaration = Rx("(--echoes-[a-z0-9-]+):\\s*([^;}]+)")

    /// Every custom property declared in one theme's block.
    private static func palette(_ text: NSString, _ selector: String) -> [String: String] {
        let opening = text.range(of: selector + "{")
        guard opening.location != NSNotFound else { return [:] }
        let after = opening.location + opening.length
        let closing = text.range(
            of: "}", range: NSRange(location: after, length: text.length - after))
        guard closing.location != NSNotFound else { return [:] }
        let body =
            text.substring(with: NSRange(location: after, length: closing.location - after))
            as NSString
        var found: [String: String] = [:]
        for hit in declaration.hits(in: body) {
            guard let name = hit.group(1), let value = hit.group(2) else { continue }
            found[name] = value.trimmingCharacters(in: .whitespaces)
        }
        return found
    }

    /// The `# theme <name>-<role> <value>` lines, or a `Shape` saying why not.
    static func lines(from directory: URL) throws -> [String] {
        let stylesheets =
            ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "css" }
            .sorted { $0.path < $1.path }
        guard !stylesheets.isEmpty else {
            // ⚠ A generator that cannot read its subject must SAY so: emitting
            // nothing writes a tokens file with no theme lines, and `Chrome`
            // then reports clean over a subject it never saw.
            throw Shape(
                "no stylesheets under \(directory.path). Refusing to emit an empty palette")
        }

        let text =
            stylesheets.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined() as NSString
        var written: [String] = []
        for theme in themes {
            let found = palette(text, theme.selector)
            guard !found.isEmpty else {
                throw Shape(
                    "SonarQube declares no `\(theme.selector)` block any more. Its theming has "
                        + "changed shape; Oilbird's tint and its dark chrome both assume this "
                        + "selector")
            }
            for entry in wanted {
                guard let value = found[entry.token] else {
                    throw Shape(
                        "\(entry.token) is not declared for the \(theme.name) theme. Oilbird's "
                            + "chrome is matched against it")
                }
                written.append("# theme \(theme.name)-\(entry.role) \(value)")
            }
        }
        return written
    }
}
