import Foundation

/// Every filesystem location is named exactly once, in `Paths.swift`.
///
/// A rename must be one edit. A literal elsewhere is what makes it five.
///
/// The rule is about locations OILBIRD OWNS. A path belonging to another
/// application, which Oilbird only ever prints for a person to go and find, is
/// a different thing: `Paths` cannot own it, renaming it is not Oilbird's edit
/// to make, and putting it there would claim a container Oilbird never
/// touches. Those are exempted by name below, each with a reason — and an
/// exemption matching nothing is stale, where the zero IS the finding (DM-4).
struct PathLiterals: Check {
    let name = "paths"
    let holds = "no filesystem path literal outside Paths.swift"

    /// Literals that name a location. `/usr/bin/…` is an absolute system tool
    /// path, which `Paths` does not own — nothing is launched by bare name,
    /// so those must be literal and absolute.
    private static let literal = Rx("\"(~/[^\"]*|/tmp/[^\"]*|Library/[^\"]*)\"")

    /// A foreign path, quoted verbatim, and why Oilbird may name it.
    private static let foreign: [String: String] = [
        "~/Library/Application Support/Claude/claude_desktop_config.json": """
        Claude Desktop's own config. The Agents pane names it so a person \
        can find the file to merge the MCP snippet into — Oilbird never \
        opens it, and the one fact a reader needs is the one they cannot \
        guess.
        """
    ]

    /// The rule's own E5 probe, and the one file it may appear in.
    ///
    /// ⚠ Not an exemption for a directory, and not a probe assembled from
    /// fragments to slip past the matcher. This rule's subject IS the string
    /// literal, so the trick that clears the `calls` check — a literal is
    /// prose — cannot apply here: a path literal in a string is precisely
    /// what it forbids. What is true instead is narrower. This ONE literal,
    /// in THIS ONE file, is the proof the rule can fail, and it is held both
    /// ways: anywhere else it is an ordinary finding, and if it stops
    /// appearing here the probe is gone, the rule is no longer proven
    /// failable, and that is a finding too. There is nothing to go stale
    /// unnoticed.
    private static let probe = "~/Library/Caches/Oilbird"
    private static let probeLives = "Sources/OilbirdChecks/PathLiterals.swift"

    func selfTest() throws {
        guard Self.literal.matches("    let x = \"\(Self.probe)\"\n") else {
            throw SelfTest("a path literal was not detected")
        }
    }

    func run() throws -> Report {
        let home = Checkout.core("Paths")
        var report = Report(summary: "")
        var read = 0
        var matched: Set<String> = []
        var sawProbe = false

        for file in Checkout.swiftFiles(under: "Sources") where file != home {
            guard let text = try? String(contentsOf: Checkout.url(file), encoding: .utf8) else {
                report.findings.append("\(file) could not be read")
                continue
            }
            read += 1
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for hit in Self.literal.hits(in: line as NSString) {
                    guard let found = hit.group(1) else { continue }
                    if Self.foreign[found] != nil {
                        matched.insert(found)
                        continue
                    }
                    if found == Self.probe && file == Self.probeLives {
                        sawProbe = true
                        continue
                    }
                    report.findings.append(
                        "\(file):\(number + 1)  path literal \"\(found)\" outside Paths")
                }
            }
        }

        for stale in Set(Self.foreign.keys).subtracting(matched).sorted() {
            report.findings.append("the exemption for \"\(stale)\" matches nothing; it is stale")
        }
        if !sawProbe {
            report.findings.append(
                "the E5 probe \"\(Self.probe)\" is no longer in \(Self.probeLives), so the "
                    + "rule is no longer proven able to fail on a real file")
        }
        report.summary =
            "\(read) files, \(Self.foreign.count) foreign path(s) exempted, 1 probe"
        return report
    }
}
