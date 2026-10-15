import Foundation

/// The wordmark: five rows for first contact, one line for every day.
///
/// ⚠ **Decoration, and it prints ONLY at a terminal with colour.** Piped,
/// redirected, in CI, under `NO_COLOR` or `TERM=dumb` it emits nothing at all
/// — not a plainer banner, NOTHING. A wordmark in a log file is noise, and no
/// information lives only in here: every fact the banner carries is repeated
/// in the lines underneath it.
extension UI {
    /// A five-row block font, written out rather than generated.
    ///
    /// The alternative is a figlet dependency to draw seven fixed characters,
    /// and this project builds with the Command Line Tools and the
    /// repository alone. Six columns each.
    private static let glyphs: [Character: [String]] = [
        "O": ["██████", "██  ██", "██  ██", "██  ██", "██████"],
        "I": ["  ██  ", "  ██  ", "  ██  ", "  ██  ", "  ██  "],
        "L": ["██    ", "██    ", "██    ", "██    ", "██████"],
        "B": ["█████ ", "██  ██", "█████ ", "██  ██", "█████ "],
        "R": ["█████ ", "██  ██", "█████ ", "██ ██ ", "██  ██"],
        "D": ["█████ ", "██  ██", "██  ██", "██  ██", "█████ "],
    ]

    /// What the bird is actually for: three arcs leaving a point, which is the
    /// app icon's own idea reduced to characters that are one cell wide
    /// everywhere. A wide glyph here would drag the wordmark out of true.
    private static let arcs = [
        "      )",
        "   )  )",
        "o  )  )",
        "   )  )",
        "      )",
    ]

    /// The gradient, and it is ANSI indices like everything else.
    ///
    /// Oilbird's mark is terracotta, and red→yellow is the warm quarter of the
    /// sixteen colours the reader already chose — so the handsome version and
    /// the principled version are the same version.
    private static let warm: [Role] = [
        .ember, .ember, .flame, .flame, .amber, .amber, .spark,
    ]

    /// The wordmark at one line, for the screens you see every day.
    ///
    /// ⚠ The five-row banner is right for first contact and for `--help`, and
    /// wrong for the menu — bare `oilbird` is the most-typed thing here, and a
    /// logo that eats a fifth of an 80×24 terminal every time stops being a
    /// welcome and becomes a toll. The same gradient runs through the letters
    /// of the name itself and the same three arcs follow it: the identity
    /// survives, the five rows do not.
    ///
    /// `nil`, not a plain "oilbird", when there is nothing to paint it with.
    public func mark() -> String? {
        guard rich else { return nil }
        let letters = zip("oilbird", Self.warm)
            .map { "{\($0.1.rawValue)|\($0.0)}" }
            .joined()
        return letters + " {flame|·}{amber|)}{spark|)}"
    }

    /// The five-row form. Empty when there is no terminal to draw on, and
    /// empty when the terminal is too narrow to hold it.
    ///
    /// ⚠ It bails out rather than wrapping. A wordmark folded across two lines
    /// is not a wordmark, and a 56-column banner in a 40-column pane is worse
    /// than none.
    public func banner() -> [String] {
        guard rich else { return [] }
        // ⚠ One column of gutter between cells. Without it the glyphs touch
        // and the wordmark reads as three solid blocks rather than as seven
        // letters — which is exactly how the first render came out.
        let rows = (0..<5).map { row -> String in
            let letters = zip("OILBIRD", Self.warm)
                .map { letter, role in
                    "{\(role.rawValue)|\(Self.glyphs[letter]?[row] ?? "")}"
                }
                .joined(separator: " ")
            return "  " + letters + "   {flame|" + Self.arcs[row] + "}"
        }
        guard let first = rows.first, measure == 0 || cells(first) + 2 <= measure else {
            return []
        }
        return rows
    }
}
