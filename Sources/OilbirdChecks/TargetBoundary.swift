import Foundation

/// Two directions across the library/executable boundary.
///
/// `K-1`  No library target imports a UI framework.
///        The compiler does NOT hold this: AppKit is in the macOS SDK and
///        SwiftPM imposes no barrier on a library target — verified, a library
///        target with `import AppKit` builds clean, exit 0. This gate is the
///        actual enforcement.
///
/// `K-2`  No file in an EXECUTABLE target holds logic.
///        An executable target cannot be `@testable import`-ed (SwiftPM
///        #7596), so anything there is untestable by construction. A file that
///        imports a UI framework and never references it is portable logic
///        filed in the one target no test can reach. Enforced here because
///        no other check held it — a rule nobody can check is an opinion.
///
/// `K-2` fails. Everything else is reported as "ready to move", not failed:
/// composition is allowed to be large, it is just not allowed to be logic.
struct TargetBoundary: Check {
    let name = "targets"
    let holds = "no UI framework in a library target, no logic in an executable one"

    private static let libraries = ["OilbirdModel", "OilbirdCore", "OilbirdKit", "OilbirdChecks"]
    private static let executables = [
        "OilbirdApp", "OilbirdCLI", "OilbirdMCP", "OilbirdChecksCLI",
    ]
    private static let uiImport = Rx(
        "^\\s*import\\s+(AppKit|SwiftUI|UIKit|Cocoa|WebKit)\\b", [.anchorsMatchLines])
    private static let uiSymbol = Rx("\\bNS[A-Z]\\w+|\\bUI[A-Z]\\w+|\\bWK[A-Z]\\w+|@main\\b|SwiftUI\\.")

    func selfTest() throws {
        guard Self.uiImport.matches("import AppKit\n") else {
            throw SelfTest("K-1 did not detect a UI import")
        }
        guard !Self.uiSymbol.matches("let x = 1\n") else {
            throw SelfTest("K-2 saw a UI symbol where there is none")
        }
    }

    func run() throws -> Report {
        var report = Report(summary: "")
        var movable: [String] = []
        var read = 0

        for target in Self.libraries {
            for file in Checkout.swiftFiles(under: "Sources/\(target)") {
                guard let text = try? String(contentsOf: Checkout.url(file), encoding: .utf8)
                else {
                    report.findings.append("K-1  \(file) could not be read")
                    continue
                }
                read += 1
                let subject = text as NSString
                for hit in Self.uiImport.hits(in: subject) {
                    report.findings.append(
                        "K-1  \(file):\(Line.of(hit.start, in: subject))  library target "
                            + "imports \(hit.group(1) ?? "a UI framework")")
                }
            }
        }

        for target in Self.executables {
            let directory = "Sources/\(target)"
            guard Checkout.exists(directory) else { continue }
            for file in Checkout.swiftFiles(under: directory) {
                guard let text = try? String(contentsOf: Checkout.url(file), encoding: .utf8)
                else {
                    report.findings.append("K-2  \(file) could not be read")
                    continue
                }
                read += 1
                let importsUI = Self.uiImport.matches(text)
                let usesUI = Self.uiSymbol.matches(text)
                if importsUI && !usesUI {
                    report.findings.append(
                        "K-2  \(file)  imports a UI framework and references it nowhere — "
                            + "this is logic in a target no test can reach")
                } else if !importsUI && !usesUI {
                    movable.append(
                        "\(file)  (\(text.components(separatedBy: "\n").count) lines)")
                }
            }
        }

        report.summary =
            "\(read) files across \(Self.libraries.count) library "
            + "and \(Self.executables.count) executable targets"
        if !movable.isEmpty {
            report.notes.append("ready to move (no UI, no reference): \(movable.count) file(s)")
            report.notes.append(contentsOf: movable.map { "  \($0)" })
        }
        return report
    }
}
