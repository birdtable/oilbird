import Foundation

// The browser, driven through a real terminal.

// ⚠ A frame test renders a view; this runs the BINARY, the only way to ask
// whether the program comes up, paints, answers a key and gives the shell back.

// ⚠ Skipped, not failed, when the fixture binary is absent: a journey failing
// for want of something to drive teaches nobody anything.
func browserJourneyTests() {
    Harness.suite("Issue browser — through a real terminal") {
        let fixture = URL(fileURLWithPath: ".build/debug/oilbird-browse-fixture")
        guard FileManager.default.isExecutableFile(atPath: fixture.path) else {
            Harness.test("the journey is skipped: no fixture binary") {
                Harness.expectTrue(true, "")
            }
            return
        }

        Harness.test("it comes up, paints the issues, and gives the shell back") {
            guard let session = PTYSession(running: fixture) else {
                Harness.expectTrue(false, "no pseudo-terminal")
                return
            }
            let painted = session.wait(seconds: 20) { $0.contains("fixture-project") }
            Harness.expectTrue(painted, "the browser never painted: \(session.screen.suffix(400))")
            Harness.expectTrue(
                session.screen.contains("BLOCKER"), "the issues are not on screen")
            Harness.expectTrue(
                session.screen.contains("Rename this class"), "the messages are not on screen")

            // ⚠ No rules anywhere. `.automatic` boxes the list, `.plain` rules
            // every row, and `.listRowSeparator(.hidden)` reaches neither,
            // because the separator belongs to the list.

            // ⚠ Checked BETWEEN the rows: inspecting only lines carrying issue
            // text passes `.plain`, which draws its rule on a line of its
            // own.
            let rules = Set("─│┌┐└┘├┤┬┴┼╭╮╰╯━┃┏┓┗┛")
            let lines = session.screen.split(separator: "\n", omittingEmptySubsequences: false)
            let issueRows = lines.indices.filter {
                lines[$0].contains("BLOCKER") || lines[$0].contains("MINOR")
                    || lines[$0].contains("MAJOR")
            }
            Harness.expectTrue(issueRows.count >= 2, "too few issue rows to check spacing")
            if let first = issueRows.first, let last = issueRows.last {
                for index in first...last {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    Harness.expectTrue(
                        line.isEmpty || !line.allSatisfy(rules.contains),
                        "a rule is drawn between the issues: \(lines[index])")
                }
            }

            // ⚠ `q` leaves. A browser that cannot be left is worse than one
            // that never starts, because the reader's shell is gone with it.
            session.send("q")
            Harness.expectTrue(session.finish(), "the browser did not exit on q")
        }

        // ⚠ The severity cycle is asserted here and not only as a function,
        // because the binding is the half that can rot: `cycled` can be
        // perfect while the key that calls it is never wired.
        Harness.test("s cycles the severity filter, and the screen says which") {
            guard let session = PTYSession(running: fixture) else {
                Harness.expectTrue(false, "no pseudo-terminal")
                return
            }
            defer { session.finish() }
            guard session.wait(seconds: 20, until: { $0.contains("fixture-project") }) else {
                Harness.expectTrue(false, "the browser never painted")
                return
            }
            // ⚠ "1 of 3", not "3 of 3". An unfiltered count reads "3 issues",
            // so "3 of 3" never appears and an assertion that accepted it
            // would pass whether or not the key did anything.
            let narrowed = session.send("s", thenWaitFor: { $0.contains("1 of 3") })
            Harness.expectTrue(
                narrowed,
                "pressing s changed nothing on screen: \(session.screen.suffix(400))")
            session.send("q")
        }

        // ⚠ The filter must swallow the keys the browser uses as commands.
        // `/` opens it; from then on `s` is a letter, not a severity cycle.
        Harness.test("typing into the filter narrows rather than issuing commands") {
            guard let session = PTYSession(running: fixture) else {
                Harness.expectTrue(false, "no pseudo-terminal")
                return
            }
            defer { session.finish() }
            guard session.wait(seconds: 20, until: { $0.contains("fixture-project") }) else {
                Harness.expectTrue(false, "the browser never painted")
                return
            }
            // ⚠ SETTLE, never wait for a word: `/` opens an empty field, so
            // nothing on screen changes and a content condition times out
            // while the browser works.
            session.send("/")
            session.settle()
            // ⚠ "import", not "unused": two of the three fixture issues say
            // "unused", so that needle narrows to 2 of 3. Matching exactly one
            // is the stronger claim anyway.
            let narrowed = session.send("import", thenWaitFor: { $0.contains("1 of 3") })
            Harness.expectTrue(
                narrowed, "the filter did not narrow: \(session.screen.suffix(400))")
            session.send("q")
        }
    }
}
