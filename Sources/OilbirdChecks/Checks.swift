import Foundation

/// Every gate, in the order they run, and what running them means.
///
/// The order is cheapest first and slowest last, so a broken build is told
/// about in a second rather than after the pseudo-terminal work. It is not a
/// dependency order: no gate depends on another, deliberately — each reads the
/// working copy and answers for itself.
public enum Checks {
    static let all: [any Check] = [
        DomainMatrix(),
        TargetBoundary(),
        PathLiterals(),
        InvisibleCost(),
        StoredPreferences(),
        Comments(),
        Documentation(),
        Severities(),
        SettingsWindow(),
        Chrome(),
        Parity(),
        GenericAPI(),
        Overrides(),
        Screens(),
        Coverage(),
    ]

    /// What the process should exit with.
    ///
    /// `0` clean, `1` findings, `2` the gate itself could not run. Three
    /// states and not two: a gate whose subject changed shape has found
    /// nothing wrong with the code, and reporting it as a violation sends
    /// somebody looking in the wrong file.
    public enum Outcome: Int32 {
        case clean = 0
        case findings = 1
        case broken = 2
    }

    /// Runs the named gates, or all of them, printing as it goes.
    public static func run(only selected: [String] = []) -> Outcome {
        let chosen = selected.isEmpty ? all : all.filter { selected.contains($0.name) }
        if chosen.isEmpty {
            print("checks: no gate named \(selected.joined(separator: ", "))")
            print("       there are: \(all.map(\.name).joined(separator: ", "))")
            return .broken
        }

        var outcome = Outcome.clean
        for gate in chosen {
            print("→ \(gate.name)")
            do {
                try gate.selfTest()
                let report = try gate.run()
                print("\(gate.name): \(report.summary)")
                for note in report.notes { print("  \(note)") }
                if report.findings.isEmpty {
                    if report.skipped {
                        print("\(gate.name): NOT CHECKED — see above")
                    } else {
                        print("\(gate.name): clean — and it has been made to fail on purpose (E5)")
                    }
                } else {
                    for finding in report.findings { print("  \(finding)") }
                    print("\(gate.name): \(report.findings.count) finding(s)")
                    outcome = .findings
                }
            } catch let shape as Shape {
                print("\(gate.name): \(shape.said)")
                return .broken
            } catch let proof as SelfTest {
                print("\(gate.name): SELF-TEST FAILED — \(proof.said)")
                return .broken
            } catch {
                print("\(gate.name): \(error)")
                return .broken
            }
        }
        return outcome
    }

    /// One line per gate, for `--list`.
    public static func list() {
        let width = all.map(\.name.count).max() ?? 0
        for gate in all {
            print("  \(gate.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(gate.holds)")
        }
    }

    /// `screenshot <name> <columns> <verb> ...`: the README's pictures,
    /// captured from the binary rather than drawn.
    public static func screenshot(_ arguments: [String]) -> Outcome {
        Screenshot.capture(arguments)
    }

    /// `comments-budget`: re-records what the commenting rules are owed.
    public static func commentsBudget() -> Outcome {
        do {
            print(try Comments.recordBudget(), terminator: "")
            return .clean
        } catch let shape as Shape {
            FileHandle.standardError.write(Data("comments-budget: \(shape.said)\n".utf8))
            return .broken
        } catch {
            FileHandle.standardError.write(Data("comments-budget: \(error)\n".utf8))
            return .broken
        }
    }

    /// `oilbird-checks coverage-budget`, for `make coverage-budget`.
    public static func coverageBudget() -> Outcome {
        do {
            print(try Coverage.recordBudget(), terminator: "")
            return .clean
        } catch let shape as Shape {
            FileHandle.standardError.write(Data("coverage-budget: \(shape.said)\n".utf8))
            return .broken
        } catch {
            FileHandle.standardError.write(Data("coverage-budget: \(error)\n".utf8))
            return .broken
        }
    }

    /// `theme-values <directory>`: the generator `make tint-tokens` calls.
    public static func themeValues(_ directory: String?) -> Outcome {
        guard let directory else {
            print("usage: oilbird-checks theme-values <css-directory>")
            return .broken
        }
        do {
            for line in try ThemeValues.lines(from: URL(filePath: directory)) { print(line) }
            return .clean
        } catch let shape as Shape {
            FileHandle.standardError.write(Data("theme-values: \(shape.said)\n".utf8))
            return .broken
        } catch {
            FileHandle.standardError.write(Data("theme-values: \(error)\n".utf8))
            return .broken
        }
    }
}
