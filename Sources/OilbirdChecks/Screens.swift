import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Every screen fits the terminal it is drawn on.
///
/// ⚠ `oilbird status` measured 103 cells against a 96-column measure and
/// nothing noticed for weeks, because through a PIPE the same line is 89 and
/// fine: the overflow existed only on the surface that has a width, and every
/// test in the suite reads the piped form. This runs the real binary on a real
/// pseudo-terminal and measures what lands there.
///
/// Only the verbs that need no engine, so this stays a gate rather than a
/// fifteen-second engine start. They are also the ones a person
/// meets first, and `status` is the one that was broken.
struct Screens: Check {
    let name = "screens"
    let holds = "no screen overflows the terminal, and none names a colour"

    private static let control = Rx("\u{1b}\\[[0-9;?]*[A-Za-z]")
    private static let sgr = Rx("\u{1b}\\[([0-9;]*)m")

    /// The design system spends eight and only eight. 39 is the default
    /// foreground and 0 the reset; anything else is truecolour or a
    /// background, both refused. The terminal's own palette, and nothing that
    /// names a colour itself.
    ///
    /// ⚠ This was the eight standard foregrounds, and it is the sixteen now,
    /// which is a widening of the VOCABULARY and not a loosening of the rule.
    /// The rule is `direct` below: `38` and `48` are how SGR says "here is the
    /// exact colour I want", and Oilbird must never say that. `36` means "the
    /// colour this reader chose for cyan", so one screen suits a light
    /// terminal, a dark one and a Solarized one without Oilbird knowing which
    /// it is; `38;5;163` overrides the reader's theme with a colour Oilbird
    /// picked.
    ///
    /// The renderer negotiates upward on its own and would emit `38;5;163` on
    /// any modern terminal. `Frames.capability()` caps it at sixteen for this
    /// reason, and this gate is what would catch that cap being removed.
    private static let allowed: Set<String> = {
        var slots: Set<String> = ["", "0", "1", "2", "3", "4", "7", "22", "23", "24", "27", "39", "49"]
        for code in [30...37, 90...97, 40...47, 100...107] {
            slots.formUnion(code.map(String.init))
        }
        return slots
    }()

    /// SGR 38 and 48 take an explicit colour: `38;5;N` from the 256 cube, or
    /// `38;2;R;G;B` truecolor. Either one is Oilbird choosing a colour instead
    /// of naming a role, which is the thing this gate exists to prevent.
    private static let direct: Set<String> = ["38", "48"]

    /// Widths a person actually uses, and the narrowest each screen is held
    /// to.
    ///
    /// ⚠ 60 for prose and 80 for the two TABLES, and that is a limit rather
    /// than an oversight. `--help` lists a verb, its argument and what it
    /// does; `version` puts pinned beside installed beside a licence. Neither
    /// reflows without truncating a verb name or a version, and a help screen
    /// that hides half of `cli-install` is worse at 60 columns than one the
    /// terminal folds. Everything whose content is a SENTENCE reflows and is
    /// held to 60.
    private static let wide = [96, 80]
    private static let narrow = [96, 80, 60]
    /// One screen, the widths it is held to, and whether drawing it needs a
    /// running engine.
    private struct Screen {
        let argv: [String]
        let widths: [Int]
        var needsEngine = false
    }

    private static let screens: [Screen] = [
        Screen(argv: ["--help"], widths: wide),
        Screen(argv: ["version"], widths: wide),
        Screen(argv: ["status"], widths: narrow),
        Screen(argv: ["scans"], widths: narrow),
        Screen(argv: ["stauts"], widths: narrow),
        Screen(argv: ["log", "abc"], widths: narrow),
        // ⚠ `api` opens a picker whose rows are SonarQube's own prose — one
        // blurb is 142 characters, drawn into 60 — and the catalogue comes
        // off the running server, so this one screen needs an engine.
        Screen(argv: ["api"], widths: narrow, needsEngine: true),
    ]

    /// How many cells a string occupies. A combining mark takes none and an
    /// East Asian wide or fullwidth character takes two.
    static func cells(_ text: String) -> Int {
        var total = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.canonicalCombiningClass != .notReordered { continue }
            total += Width.isWide(scalar) ? 2 : 1
        }
        return total
    }

    func selfTest() throws {
        guard Self.sgr.first(in: "\u{1b}[38;5;163mx" as NSString)?.group(1) == "38;5;163" else {
            throw SelfTest("an explicit 256-colour sequence was not read")
        }
        guard Self.control.strip(from: "\u{1b}[2Jabc") == "abc" else {
            throw SelfTest("a control sequence was not stripped, so every line would measure long")
        }
        guard Self.cells("宽") == 2, Self.cells("abc") == 3 else {
            throw SelfTest("a wide character did not measure two cells")
        }
    }

    func run() throws -> Report {
        let binary = Checkout.url(".build/debug/oilbird")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw Shape("no binary at .build/debug/oilbird — run `make build` first")
        }

        let engineAnswers = Self.answers(binary)

        var findings: [String] = []
        var skipped: [String] = []
        var measured = 0
        for screen in Self.screens {
            let spelled = "`oilbird \(screen.argv.joined(separator: " "))`"
            if screen.needsEngine && !engineAnswers {
                skipped.append(spelled)
                continue
            }
            for columns in screen.widths {
                let raw = try Self.draw(binary, screen.argv, columns: columns)
                for parameters in Self.sgr.capture(in: raw as NSString) {
                    let fields = parameters.components(separatedBy: ";")
                    if fields.contains(where: { Self.direct.contains($0) }) {
                        findings.append(
                            "\(spelled) emits SGR \(parameters) — an explicit colour, which "
                                + "overrides the reader's own palette")
                        continue
                    }
                    for field in fields where !Self.allowed.contains(field) {
                        findings.append(
                            "\(spelled) emits SGR \(field), which is not a palette slot or a "
                                + "text attribute")
                    }
                }
                // The measure is clamped at 96 however wide the window is.
                let measure = min(columns, 96)
                let plain = Self.control.strip(from: raw).replacingOccurrences(of: "\r", with: "")
                for line in plain.components(separatedBy: "\n") {
                    measured += 1
                    let width = Self.cells(line)
                    if width > measure {
                        let excerpt = line.trimmingCharacters(in: .whitespaces).prefix(60)
                        findings.append(
                            "\(spelled) at \(columns) columns: a line is \(width) cells against "
                                + "a measure of \(measure) — \(excerpt)")
                    }
                }
            }
        }

        guard measured > 0 else { throw SelfTest("no lines were measured") }
        var report = Report(
            summary:
                "\(Self.screens.count) screens, \(measured) lines measured at "
                + "\(Self.narrow) columns")
        // Deduplicated, order kept: the same overflow at three widths is one
        // thing to fix, and printing it three times buries the second finding.
        var seen: Set<String> = []
        report.findings = findings.filter { seen.insert($0).inserted }
        // Named rather than silent. A screen nobody measured is not a screen
        // that passed, and a gate that quietly drops one is worth less than
        // its output says (`DM-4`).
        if !skipped.isEmpty {
            report.notes.append(
                "not measured, no engine answered: \(skipped.joined(separator: ", "))")
        }
        return report
    }

    /// Is an engine running?
    ///
    /// ⚠ **A screen that needs an engine and has none draws the STARTUP
    /// SEQUENCE instead**, and a spinner repainting is one line to `strip`:
    /// measured at 14,632 cells against a measure of 80. That is this gate
    /// going red for a reason that is not the code, which is how a gate ends
    /// up switched off.
    ///
    /// Asked of `status --json`, which reports and never starts, so the probe
    /// cannot cause the state it is asking about — the interactive screen is
    /// the one that offers to start an engine, so it is never a dead end.
    ///
    /// ⚠ And read as a FIELD, not an exit code. `status --json` exits 0 with
    /// `"running": false` when nothing is up, and `api --json` exits 0 with
    /// an error object, so anything reading only a status code reads both
    /// states as "fine". The first version of this probe asked `api --json`
    /// and never skipped anything.
    private static func answers(_ binary: URL) -> Bool {
        let task = Process()
        task.executableURL = binary
        task.arguments = ["status", "--json"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.replacingOccurrences(of: " ", with: "").contains("\"running\":true")
    }

    /// The binary, on a real pseudo-terminal of a given width, and everything
    /// it wrote.
    ///
    /// ⚠ Raw bytes, escape sequences and all. The suites' `PTYSession` keeps a
    /// cursor-tracking grid instead, which is the right thing for asking "did
    /// the word appear" and the wrong thing here: this gate's whole subject is
    /// the escape sequences a grid throws away.
    static func draw(_ binary: URL, _ argv: [String], columns: Int) throws -> String {
        var parent: Int32 = 0
        var child: Int32 = 0
        var size = winsize(ws_row: 44, ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&parent, &child, nil, nil, &size) == 0 else {
            throw Shape("could not open a pseudo-terminal")
        }

        let childEnd = FileHandle(fileDescriptor: child, closeOnDealloc: false)
        let task = Process()
        task.executableURL = binary
        task.arguments = argv
        task.standardInput = childEnd
        task.standardOutput = childEnd
        task.standardError = childEnd
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLUMNS"] = String(columns)
        task.environment = environment
        do {
            try task.run()
        } catch {
            close(parent)
            close(child)
            throw Shape("could not run the binary (\(error))")
        }
        close(child)

        var buffer = Data()
        let began = Date()
        while Date().timeIntervalSince(began) < 60 {
            var poll = pollfd(fd: parent, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&poll, 1, 100)
            if ready > 0 {
                var chunk = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(parent, &chunk, chunk.count)
                if count <= 0 { break }
                buffer.append(contentsOf: chunk[0..<count])
            } else if !task.isRunning {
                break
            }
        }
        close(parent)
        task.waitUntilExit()
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// East Asian width, for the cell measure.
///
/// The ranges the Unicode standard marks `W` or `F`, which are the only two
/// that take two cells. Written out rather than taken from a library: there is
/// no East Asian width property on `Unicode.Scalar` in the standard library,
/// and the alternative was a dependency for one predicate.
enum Width {
    private static let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
        0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3,
        0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF,
        0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        wide.contains { $0.contains(scalar.value) }
    }
}
