import Foundation

/// Calls whose cost is invisible at the call site.
///
/// Every entry here is a system API that looks free, reads as free, and is
/// not. A code review cannot catch these — `ProcessInfo.processInfo.hostName`
/// is one property access and thirty-five seconds of blocked main thread — so
/// the gate catches them instead.
///
/// Add to `forbidden` when a call turns out to cost something the name does
/// not say. The reason is part of the entry: a rule whose why is elsewhere
/// gets deleted by the next person who trips over it.
struct InvisibleCost: Check {
    let name = "calls"
    let holds = "no call whose cost the name does not say"

    private struct Forbidden {
        let pattern: Rx
        let why: String
    }

    private static let forbidden: [Forbidden] = [
        Forbidden(
            pattern: Rx("ProcessInfo\\.processInfo\\.hostName"),
            why: """
                resolves the machine name through CFHost/Bonjour, not \
                gethostname. It raises macOS's local-network permission prompt \
                and BLOCKS until the user answers — 35.01s measured on a clean \
                VM. Use Owner.machineName().
                """),
        Forbidden(
            pattern: Rx("for line in result\\.stdout"),
            why: """
                replays a finished process's whole buffer through a progress \
                callback. `Child.run` delivers lines as they arrive; iterating \
                the collected stdout afterwards is the shape of the defect \
                where a scan printed nothing for 11.4 seconds and then 125 \
                lines at once, while the window's progress line claimed to be \
                live commentary. Pass `onLine:` to Child.run instead.
                """),
    ]

    func selfTest() throws {
        let probe = "        let h = ProcessInfo.processInfo.hostName\n"
        guard Self.forbidden.contains(where: { $0.pattern.matches(probe) }) else {
            throw SelfTest("a forbidden call was not detected")
        }
    }

    func run() throws -> Report {
        var report = Report(summary: "")
        var read = 0
        for file in Checkout.swiftFiles(under: "Sources") {
            guard let text = try? String(contentsOf: Checkout.url(file), encoding: .utf8) else {
                report.findings.append("\(file) could not be read")
                continue
            }
            read += 1
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                // ⚠ Strings and the trailing comment stripped, not just a
                // whole-line `//`: a forbidden call quoted in a string is the rule
                // naming its own subject, and no call hides in a literal.
                let code = Code.withoutProse(line: line)
                for rule in Self.forbidden where rule.pattern.matches(code) {
                    report.findings.append(
                        "\(file):\(number + 1)  \(rule.pattern.pattern)\n      \(rule.why)")
                }
            }
        }
        report.summary = "\(read) files, \(Self.forbidden.count) forbidden calls"
        return report
    }
}
