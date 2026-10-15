import Foundation
import OilbirdChecks

/// The gates, as a command.
///
/// Composition only: argv in, an exit code out. Everything it does is in
/// `OilbirdChecks`, which is a library target so the suites can reach it —
/// `K-2`, and the reason the gates are two targets rather than one.
@main
struct Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "--help" || arguments.first == "-h" {
            print("usage: oilbird-checks [<gate> ...]")
            print("       oilbird-checks --list")
            print("       oilbird-checks theme-values <css-directory>")
            print("       oilbird-checks comments-budget")
            print("       oilbird-checks coverage-budget")
            print("")
            print("With no arguments, every gate runs. Exit 0 clean, 1 findings,")
            print("2 a gate that could not run at all.")
            print("")
            Checks.list()
            exit(0)
        }
        if arguments.first == "--list" {
            Checks.list()
            exit(0)
        }
        if arguments.first == "screenshot" {
            exit(Checks.screenshot(Array(arguments.dropFirst())).rawValue)
        }
        if arguments.first == "comments-budget" {
            exit(Checks.commentsBudget().rawValue)
        }
        if arguments.first == "coverage-budget" {
            exit(Checks.coverageBudget().rawValue)
        }
        if arguments.first == "theme-values" {
            exit(Checks.themeValues(arguments.dropFirst().first).rawValue)
        }
        exit(Checks.run(only: arguments).rawValue)
    }
}
