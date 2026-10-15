import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// A real terminal, for the one screen that needs one.
///
/// ⚠ Hand-rolled rather than taken from `SwiftTUITestSupport`. That library
/// imports swift-testing, and these suites are an executable with their own
/// harness — deliberately, so a fault injected into the library reaches the
/// binary under test. Importing it would have meant a second test system
/// beside this one.
///
/// It emulates nothing. It strips escape sequences and keeps the printable
/// bytes, which is enough to ask "did the word appear" and not enough to ask
/// "where on the screen" — and the frame tests already answer the second
/// question without a terminal at all.
final class PTYSession {
    let parentEnd: Int32
    let columns: Int
    let rows: Int
    private let process = Process()
    private var seen = Data()

    init?(running executable: URL, arguments: [String] = [], columns: Int = 96, rows: Int = 24) {
        var parent: Int32 = 0
        var child: Int32 = 0
        var size = winsize(
            ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&parent, &child, nil, nil, &size) == 0 else { return nil }
        parentEnd = parent
        self.columns = columns
        self.rows = rows

        let childEnd = FileHandle(fileDescriptor: child, closeOnDealloc: false)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = childEnd
        process.standardOutput = childEnd
        process.standardError = childEnd
        // ⚠ A named terminal and a UTF-8 locale, or the app negotiates ASCII
        // and no colour and the journey tests a different program than the
        // one a person runs.
        process.environment = [
            "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
            "COLUMNS": String(columns), "LINES": String(rows),
        ]
        do { try process.run() } catch { return nil }
        close(child)
    }

    /// What is on the screen, as a person would read it.
    ///
    /// ⚠ A cursor-tracking grid, not a strip of the escape sequences. The
    /// first version kept the printable bytes and dropped the rest, and a
    /// full-screen program does not write its screen in reading order: it
    /// positions the cursor and writes fragments. So `1 of 3` arrived as
    /// `1of 3` — the space was a cursor move — and `Remove this unused` came
    /// out as `movunued`. Assertions over that soup fail at random, which is
    /// the worst kind of test.
    ///
    /// This is the minimum that makes the text true: absolute and relative
    /// cursor moves, the two erases, and printable characters into a grid.
    /// It is not a terminal emulator and does not need to be.
    var screen: String {
        var grid = [[Character]](
            repeating: [Character](repeating: " ", count: columns), count: rows)
        var row = 0
        var column = 0
        var index = seen.startIndex
        let bytes = Array(seen)

        func place(_ character: Character) {
            guard row >= 0, row < rows else { return }
            if column >= columns {
                column = 0
                row += 1
                guard row < rows else { return }
            }
            guard column >= 0 else { return }
            grid[row][column] = character
            column += 1
        }

        var pending: [UInt8] = []
        index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B, index + 1 < bytes.count, bytes[index + 1] == 0x5B {
                var end = index + 2
                while end < bytes.count, !(0x40...0x7E).contains(bytes[end]) { end += 1 }
                guard end < bytes.count else { break }
                let parameters = String(decoding: bytes[(index + 2)..<end], as: UTF8.self)
                    .split(separator: ";").map { Int($0) ?? 0 }
                switch bytes[end] {
                case UInt8(ascii: "H"), UInt8(ascii: "f"):
                    row = (parameters.first ?? 1) - 1
                    column = (parameters.count > 1 ? parameters[1] : 1) - 1
                case UInt8(ascii: "A"): row -= max(1, parameters.first ?? 1)
                case UInt8(ascii: "B"): row += max(1, parameters.first ?? 1)
                case UInt8(ascii: "C"): column += max(1, parameters.first ?? 1)
                case UInt8(ascii: "D"): column -= max(1, parameters.first ?? 1)
                case UInt8(ascii: "J"):
                    // 2 clears everything; anything else clears to the end.
                    if parameters.first == 2 {
                        grid = [[Character]](
                            repeating: [Character](repeating: " ", count: columns), count: rows)
                    }
                case UInt8(ascii: "K"):
                    if row >= 0, row < rows, column >= 0 {
                        for x in column..<columns { grid[row][x] = " " }
                    }
                default: break
                }
                index = end + 1
                continue
            }
            if byte == 0x1B {
                // OSC and anything else: skip to its terminator.
                var end = index + 1
                while end < bytes.count, bytes[end] != 0x07, bytes[end] != 0x1B { end += 1 }
                index = min(end + 1, bytes.count)
                continue
            }
            if byte == 0x0A { row += 1; column = 0; index += 1; continue }
            if byte == 0x0D { column = 0; index += 1; continue }
            if byte < 0x20 { index += 1; continue }

            // Gather one UTF-8 scalar so a box glyph is one cell, not three.
            pending.removeAll(keepingCapacity: true)
            var length = 1
            if byte >= 0xF0 {
                length = 4
            } else if byte >= 0xE0 {
                length = 3
            } else if byte >= 0xC0 {
                length = 2
            }
            for offset in 0..<length where index + offset < bytes.count {
                pending.append(bytes[index + offset])
            }
            for character in String(decoding: pending, as: UTF8.self) { place(character) }
            index += length
        }
        return grid.map { String($0).replacingOccurrences(of: " +$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    /// Reads until `condition` holds over everything seen, or time runs out.
    func wait(seconds: Double, until condition: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        if condition(screen) { return true }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var readable = fd_set()
            withUnsafeMutablePointer(to: &readable) { set in
                set.withMemoryRebound(to: Int32.self, capacity: 32) { words in
                    for index in 0..<32 { words[index] = 0 }
                    words[Int(parentEnd) / 32] |= Int32(1 << (Int(parentEnd) % 32))
                }
            }
            var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
            guard select(parentEnd + 1, &readable, nil, nil, &timeout) > 0 else { continue }
            let count = read(parentEnd, &buffer, buffer.count)
            guard count > 0 else { break }
            seen.append(contentsOf: buffer[0..<count])
            if condition(screen) { return true }
        }
        return condition(screen)
    }

    func send(_ keys: String) {
        var bytes = Array(keys.utf8)
        _ = write(parentEnd, &bytes, bytes.count)
    }

    /// Reads until the program stops writing for `quiet`.
    ///
    /// ⚠ For the case where the proof a key landed is not a word on the
    /// screen. Opening an empty filter field changes no text — there is no
    /// placeholder to wait for — so a content condition cannot say the frame
    /// arrived, and typing before it does sends the letters to the browser as
    /// commands. This waits for the program to go quiet, which it can
    /// actually observe, rather than sleeping a guessed interval.
    func settle(quiet: Double = 0.25, within seconds: Double = 5) {
        let deadline = Date().addingTimeInterval(seconds)
        var lastChange = Date()
        var previous = seen.count
        while Date() < deadline {
            _ = wait(seconds: 0.05, until: { _ in false })
            if seen.count != previous {
                previous = seen.count
                lastChange = Date()
            } else if Date().timeIntervalSince(lastChange) >= quiet {
                return
            }
        }
    }

    /// Sends keys and waits for the screen to prove they landed.
    ///
    /// ⚠ Sending and asserting without this between them is a race, and it
    /// failed about one run in four: `/` opens the filter on the next frame,
    /// and the letters typed before that frame went to the browser as
    /// commands instead. Waiting on a CONDITION rather than sleeping keeps
    /// the suite fast when the program is quick and correct when it is not.
    @discardableResult func send(
        _ keys: String, thenWaitFor condition: (String) -> Bool, seconds: Double = 10
    ) -> Bool {
        send(keys)
        return wait(seconds: seconds, until: condition)
    }

    /// Waits for the program to leave, and says whether it did.
    @discardableResult func finish(seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            _ = wait(seconds: 0.1, until: { _ in false })
        }
        if process.isRunning { process.terminate() }
        close(parentEnd)
        return !process.isRunning
    }
}
