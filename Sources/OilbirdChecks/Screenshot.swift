import Foundation

/// Real terminal output, drawn as an SVG.
///
///     oilbird-checks screenshot <name> <columns> <verb> [argument ...]
///
/// The README's pictures are captured from the binary rather than drawn by
/// hand, so a screen that changes and a README that does not is a state this
/// repository can notice. `make screenshots` regenerates every one of them.
///
/// SVG rather than a PNG or a GIF, for three reasons that all come down to the
/// same one: it is text. It diffs, it stays sharp on a retina display at any
/// size, and producing it needs no image library, no Homebrew formula and no
/// second toolchain, which the build rules out anyway.
///
/// Not a check: this generates. `screens` is the gate over the same output,
/// and it reads a pseudo-terminal for the same reason this does.
enum Screenshot {
    /// Cell geometry, in the units the SVG uses. The advance width is SF
    /// Mono's, measured rather than guessed: 0.6 em at any size.
    private static let fontSize = 13.0
    private static let advance = fontSize * 0.6
    private static let lineHeight = fontSize * 1.45
    private static let padding = 14.0

    /// The sixteen slots, as a terminal would resolve them, in a palette that
    /// suits a README on either of GitHub's themes. Oilbird names roles and
    /// never colours, so these are the reader's end of that contract, chosen
    /// once here rather than baked into the product.
    private static let palette: [Int: String] = [
        30: "#3b4048", 31: "#c74e52", 32: "#4e9a52", 33: "#a0842c",
        34: "#4573b5", 35: "#9a4fa8", 36: "#2f8b91", 37: "#d0d0d0",
        90: "#6f7680", 91: "#e06c75", 92: "#78b47c", 93: "#c9a227",
        94: "#6a9bd8", 95: "#b96fc4", 96: "#4bb3ba", 97: "#f2f2f2",
    ]
    private static let foreground = "#c9d1d9"
    private static let background = "#0d1117"

    /// One run of characters sharing a style.
    private struct Run {
        var text = ""
        var colour: String?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
    }

    private struct Style {
        var colour: String?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
    }

    /// Applies one SGR sequence's parameters to the running style.
    private static func apply(_ parameters: String, to style: inout Style) {
        let fields = parameters.isEmpty ? ["0"] : parameters.components(separatedBy: ";")
        for field in fields {
            switch Int(field) ?? 0 {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 39: style.colour = nil
            case let code where palette[code] != nil: style.colour = palette[code]
            default: break
            }
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The raw bytes of one screen, turned into an SVG of the same width.
    static func svg(from raw: String, columns: Int, title: String) -> String {
        let sgr = Rx("\u{1b}\\[([0-9;]*)m")
        let other = Rx("\u{1b}\\[[0-9;?]*[A-Za-z]")
        /// `ESC[2K`, erase the line the cursor is on.
        ///
        /// ⚠ Matched BEFORE `other`, which used to swallow it with every other
        /// escape. `UI.Slot` writes `\r\u{1B}[2K` before each frame of a
        /// spinner, so a terminal shows one line redrawn in place — and this
        /// drew every frame end to end instead. `doctor` came out with a
        /// `textLength` of 23,423 on a 714-pixel canvas: three of its four
        /// rows ran off the edge and the README has been showing that.
        let erase = Rx("\u{1b}\\[2K")

        var lines: [[Run]] = []
        var current: [Run] = []
        var style = Style()
        let subject = raw as NSString
        var offset = 0

        func push(_ character: Character) {
            if var last = current.last, last.colour == style.colour, last.bold == style.bold,
                last.dim == style.dim, last.italic == style.italic,
                last.underline == style.underline
            {
                last.text.append(character)
                current[current.count - 1] = last
            } else {
                current.append(
                    Run(
                        text: String(character), colour: style.colour, bold: style.bold,
                        dim: style.dim, italic: style.italic, underline: style.underline))
            }
        }

        while offset < subject.length {
            if let hit = sgr.first(in: subject, from: offset), hit.start == offset {
                apply(hit.group(1) ?? "", to: &style)
                offset += hit.result.range.length
                continue
            }
            if let hit = erase.first(in: subject, from: offset), hit.start == offset {
                current = []
                offset += hit.result.range.length
                continue
            }
            if let hit = other.first(in: subject, from: offset), hit.start == offset {
                offset += hit.result.range.length
                continue
            }
            let character = Character(subject.substring(with: NSRange(location: offset, length: 1)))
            offset += 1
            switch character {
            case "\n":
                lines.append(current)
                current = []
            case "\r":
                continue
            default:
                push(character)
            }
        }
        if !current.isEmpty { lines.append(current) }
        // Trailing blank lines are the shell's, not the screen's.
        while let last = lines.last, last.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        {
            lines.removeLast()
        }

        let width = Double(columns) * advance + padding * 2
        let height = Double(lines.count) * lineHeight + padding * 2
        var out = """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(width))" \
            height="\(Int(height))" viewBox="0 0 \(Int(width)) \(Int(height))" \
            font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" \
            font-size="\(Int(fontSize))" role="img" aria-label="\(escaped(title))">
            <title>\(escaped(title))</title>
            <rect width="100%" height="100%" rx="6" fill="\(background)"/>

            """
        for (row, runs) in lines.enumerated() {
            let baseline = padding + Double(row + 1) * lineHeight - lineHeight * 0.28
            var column = 0
            for run in runs {
                let start = column
                column += run.text.count
                // ⚠ Each run is pinned to its cell width with `textLength`, and
                // each x assumes a 0.6 em advance: a fallback face lays the string
                // out 4% wider and closes a two-space gap by column 54.
                let leading = run.text.prefix { $0 == " " }.count
                let visible = String(run.text.dropFirst(leading))
                    .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
                if visible.isEmpty { continue }
                let x = padding + Double(start + leading) * advance
                var attributes = #"xml:space="preserve""#
                attributes += " x=\"\(String(format: "%.1f", x))\""
                attributes += " y=\"\(String(format: "%.1f", baseline))\""
                attributes += " textLength=\"\(String(format: "%.1f", Double(visible.count) * advance))\""
                attributes += #" lengthAdjust="spacingAndGlyphs""#
                attributes += " fill=\"\(run.colour ?? foreground)\""
                if run.bold { attributes += #" font-weight="600""# }
                if run.italic { attributes += #" font-style="italic""# }
                if run.underline { attributes += #" text-decoration="underline""# }
                if run.dim { attributes += #" opacity="0.62""# }
                out += "<text \(attributes)>\(escaped(visible))</text>\n"
            }
        }
        return out + "</svg>\n"
    }

    /// Runs one verb on a real pseudo-terminal and writes its SVG.
    static func capture(_ arguments: [String]) -> Checks.Outcome {
        guard arguments.count >= 3, let columns = Int(arguments[1]) else {
            print("usage: oilbird-checks screenshot <name> <columns> <verb> [argument ...]")
            return .broken
        }
        let name = arguments[0]
        let argv = Array(arguments.dropFirst(2))
        let binary = Checkout.url(".build/debug/oilbird")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            FileHandle.standardError.write(
                Data("screenshot: no binary at .build/debug/oilbird\n".utf8))
            return .broken
        }
        do {
            let raw = try Screens.draw(binary, argv, columns: columns)
            let title = "oilbird " + argv.joined(separator: " ")
            let folder = Checkout.url("docs/images")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "\(name).svg")
            try svg(from: raw, columns: columns, title: title).write(
                to: file, atomically: true, encoding: .utf8)
            print("docs/images/\(name).svg")
            return .clean
        } catch {
            FileHandle.standardError.write(Data("screenshot: \(error)\n".utf8))
            return .broken
        }
    }
}
