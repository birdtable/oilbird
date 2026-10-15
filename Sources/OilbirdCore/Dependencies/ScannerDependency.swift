import Foundation
import OilbirdModel

/// The SonarScanner CLI, as a `ManagedDependency`.
///
/// It is the smallest of the four artifacts and the only one that is pure
/// client: it analyses a directory and reports the result to the server. That
/// shape is what makes its `verify()` the awkward one — the scanner cannot
/// demonstrate that it works using only itself. It needs a JVM to run in and a
/// server to report to, and this type owns neither.
public struct ScannerDependency: ManagedDependency {
    public let id = DependencyID.scanner

    /// Where a fixture scan reports to.
    ///
    /// `nil` until the server is running and a token exists. It is an
    /// injected value rather than something this type discovers, because the
    /// port is assigned by the OS at start (`Ports`) and the token is a
    /// credential this domain must not read.
    private let target: AnalysisTarget?

    public init(reportingTo target: AnalysisTarget? = nil) {
        self.target = target
    }

    /// The server a fixture scan reports to, and the token it authenticates
    /// with.
    ///
    /// The token is carried here rather than in the argument list on purpose:
    /// the scanner echoes its arguments on failure, so a token passed as `-D`
    /// would land in `ps` output and in every captured stderr. It travels by
    /// environment, which is what makes `Log.subprocess` safe to log verbatim.
    public struct AnalysisTarget: Sendable {
        public let host: URL
        public let token: String

        public init(host: URL, token: String) {
            self.host = host
            self.token = token
        }
    }

    // MARK: - Installed, but not yet verifiable

    /// A precondition `verify()` needs and does not own.
    ///
    /// **This is the type's one real design decision, so here is the whole
    /// reasoning.** `DependencyHealth` has three cases and not one of them
    /// means *unknown*:
    ///
    /// - `.present` is the JRE mistake verbatim. That JRE was on disk, printed
    ///   a flawless `java -version`, was pronounced usable, and could not boot
    ///   Elasticsearch. "Presence on disk is not presence" exists because
    ///   someone reported presence on the strength of a binary existing. Reporting
    ///   `.present` for a scanner that has never scanned anything is the same
    ///   error with a different filename.
    /// - `.corrupt` is a different lie with a price attached. A caller reading
    ///   `.corrupt` discards the artifact and downloads it again. The scanner is not
    ///   damaged and the second download will produce a byte-identical tree, so
    ///   the answer costs the user 11 MiB and leaves them exactly where they
    ///   started — and it will do so on every attempt, because the missing JDK
    ///   is still missing.
    /// - `.missing` costs the same download and is false on its face.
    ///
    /// So the honest answer is not a health at all. Nothing was *found* about
    /// the scanner, because the check could not be **performed** — and a call
    /// that could not do its job is what `throws` is for. `verify()` is already
    /// `async throws`; this uses the channel that is there rather than widening
    /// the one that is not.
    ///
    /// Two properties fall out of that choice, and both are the point:
    ///
    /// 1. **It cannot be ignored.** A fourth `DependencyHealth` case would be
    ///    matched by any `default:` branch a caller already has, and treated as
    ///    benign — a silent pass, which is the exact failure `verify()` exists
    ///    to prevent. A thrown error has to be caught to be discarded.
    /// 2. **It carries a recovery.** `OilbirdError` cannot be constructed
    ///    without one, so every unverifiable state arrives with something the
    ///    user can do. `.corrupt(reason:)` carries a bare string; had
    ///    this been an enum case, "your Java runtime is missing" would have
    ///    been a dead end wearing an enum.
    ///
    /// The one thing the first version got wrong was leaving the *caller* no
    /// way to tell this throw from any other. `Oilbird.doctor` caught it and
    /// wrote `.corrupt(reason: "verify threw")` — the same lie one layer up —
    /// and `Oilbird.install` treated it as a failed install and stopped, on a
    /// machine where all four artefacts were present and correct. Hence
    /// `.notCheckable`: the cause is what a caller matches on, and it is the
    /// only thing that separates "could not check" from "checked, and it is
    /// broken".
    ///
    /// It is named rather than inlined so the suites can assert a recovery for
    /// every case without a network, a JDK or a server.
    public enum Unverifiable: Sendable, CaseIterable {
        /// The scanner is a JVM program. Without Oilbird's JDK there is
        /// nothing to run it in, and the macOS `java` stub is not a fallback
        /// — reaching for it would be a `PATH` lookup and the user's own
        /// runtime at once.
        case noRuntime

        /// A scan is not a self-contained computation: the scanner fetches its
        /// analysers from the server and posts the report back to it. With
        /// nowhere to report, no scan completes, and there is no offline mode
        /// to stand in for one.
        case noServer

        /// The failure as the user sees it, with the action attached.
        public var error: OilbirdError {
            switch self {
            case .noRuntime:
                // `.reinstall(.jdk)` and not `.reinstall(.scanner)`: the scanner
                // is fine and downloading it again proves that over and over.
                // The button must fetch the dependency that is absent.
                OilbirdError(
                    .notCheckable,
                    "Oilbird cannot check the scanner until its Java runtime is installed.",
                    recovery: .reinstall(.jdk),
                    underlying: "scanner verify: no JDK at \(Paths.Cache.jdk.path)")
            case .noServer:
                OilbirdError(
                    .notCheckable,
                    "Oilbird cannot check the scanner until its analysis server is running.",
                    // The action is to start Oilbird, not to run the same
                    // check again — "Try again" was a button that could only
                    // produce this message a second time.
                    recovery: .retry("Start Oilbird"),
                    underlying: "scanner verify: no analysis target supplied")
            }
        }
    }

    // MARK: - The triple

    /// The CLI jar carries the version in its name, so the pinned version has
    /// a path and presence can be asked about *it* rather than about the
    /// directory.
    public func cliJar(version: String) -> URL {
        Paths.Cache.scanner.appending(path: "lib/sonar-scanner-cli-\(version).jar")
    }

    /// Cheap, and it asks about the pinned version rather than about a jar.
    ///
    /// ⚠ This globbed `sonar-scanner-cli*.jar` and then returned the
    /// **manifest's** version regardless of what the glob matched —
    /// presence on disk reported as presence of the pinned thing.
    /// Bumping the scanner would have skipped the install (`Oilbird.install`
    /// continues on `.present`), left the old jar running every scan, and had
    /// `doctor` print the new version beside it. The one artefact whose
    /// version is legible from a filename was the one not being read.
    ///
    /// So the question is the one `SonarQubeDependency` already asks: does
    /// the jar *this build pins* exist? A different jar is not this one, and
    /// `.missing` is the honest answer for it — the scanner on disk is not
    /// damaged, it is simply not the pinned scanner, and `.corrupt` would
    /// tell the user their install was broken when it is merely superseded.
    ///
    /// `verify()` is still what turns presence into "installed": it runs a
    /// real analysis.
    public func detect() -> DependencyHealth {
        guard let entry = try? Manifest.bundled().entry(id) else {
            return .corrupt(reason: "Oilbird cannot tell which scanner version it expects.")
        }
        // The jar, not `bin/sonar-scanner`. Detecting on the wrapper script
        // would report present for an install missing the thing Oilbird
        // actually launches, and absent for one that had only the jar.
        guard FileManager.default.fileExists(atPath: cliJar(version: entry.version).path) else {
            return .missing
        }
        return .present(version: entry.version)
    }

    /// Download, digest, unpack, strip quarantine — all of it shared.
    ///
    /// There is deliberately no bespoke transfer or extraction here. A
    /// dependency that fetched its own bytes would be a second place for the
    /// fail-closed rule and the quarantine ordering to be got wrong.
    public func install(progress: @Sendable (Int64, Int64) -> Void) async throws {
        let entry = try Manifest.bundled().entry(id)
        try await fetchAndPlace(entry, progress: progress)
    }

    /// Runs the workload: a real scan of a real fixture project, exit 0 or
    /// nothing (`manifest.json` declares `scan-fixture`).
    ///
    /// The order below is the whole design. Cheap `detect()` gates the
    /// expensive run; the two preconditions this dependency does not own are
    /// checked **before** anything is launched, so that a missing JDK or a
    /// stopped server can never be misfiled as a broken scanner. Only then is
    /// the scanner actually run, and only exit 0 is a pass.
    public func verify() async throws -> DependencyHealth {
        switch detect() {
        case .missing: return .missing
        case .corrupt(let reason): return .corrupt(reason: reason)
        case .present: break
        }
        guard Resolver.scannerJar() != nil else { return .missing }
        // The precondition, not the path: `ScannerCommand` resolves the JDK
        // itself. Checked here so a missing runtime is reported as one, with
        // the button that fetches it.
        guard Resolver.executable(.java) != nil else { throw Unverifiable.noRuntime.error }
        guard let target else { throw Unverifiable.noServer.error }

        Log.phase("verify scanner")
        let fixture = try fixtureProject()
        defer { try? FileManager.default.removeItem(at: fixture) }

        // Taken before the child starts, so the comparison is about this run
        // and not about whatever the machine already had.
        let containment = ScannerCommand.Containment.witness()
        let launch = try ScannerCommand.launch(
            hostPort: UInt16(target.host.port ?? 0), projectKey: Self.fixtureProjectKey,
            extra: scanArguments(analysing: fixture))
        let result = try await Child.run(
            launch.executable, launch.argv,
            // Only the token. Everything the child needs to stay inside the
            // container is an explicit argument now, rather than a `JAVA_HOME`
            // the scanner consults too late to matter.
            environment: Resolver.childEnvironment(adding: ["SONAR_TOKEN": target.token]),
            currentDirectory: fixture)

        guard result.status == 0 else { return .corrupt(reason: describe(result)) }

        // Presence is not proof, for the containment too: the self-check verifies that the
        // scan it just ran stayed inside Oilbird's directories, rather than
        // trusting the flags that were supposed to keep it there.
        let escaped = containment.escapedSince()
        guard escaped.isEmpty else {
            return .corrupt(
                reason:
                    "The scanner wrote outside Oilbird's container, at \(escaped.joined(separator: ", ")).")
        }
        guard let entry = try? Manifest.bundled().entry(id) else {
            return .corrupt(reason: "Oilbird cannot tell which scanner version it expects.")
        }
        return .present(version: entry.version)
    }

    // MARK: -

    /// A throwaway project with one analysable file in it.
    ///
    /// A sibling of the install directory, which is the idiom `Install` already
    /// uses for its `.incoming` and `.previous` staging — so it inherits the
    /// cache root without naming a location, and "reclaim disk space" sweeps it
    /// up with everything else. It is rebuilt on every call rather than cached:
    /// a fixture that a previous run left half-written would verify the wrong
    /// thing, quietly.
    private func fixtureProject() throws -> URL {
        let root = Paths.install(id).appendingPathExtension("fixture")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.fixtureSource.utf8).write(to: root.appending(path: "oilbird_fixture.py"))
        return root
    }

    /// Small, valid, and boring on purpose. The scanner refuses a project with
    /// nothing in it to analyse, and a fixture with a real finding in it would
    /// make the pass depend on which rules the server happens to have enabled.
    private static let fixtureSource = """
        def oilbird_fixture(value: int) -> int:
            \"\"\"Exists so that the scanner has something to analyse.\"\"\"
            return value + 1
        """

    /// Everything by `-D`, nothing by file: Oilbird never writes a
    /// `sonar-project.properties` into a directory it is analysing. Here the directory is
    /// ours, but the rule is kept so this path and the real scan path stay the
    /// same shape.
    private func scanArguments(analysing fixture: URL) -> [String] {
        [
            "-Dsonar.projectKey=\(Self.fixtureProjectKey)",
            "-Dsonar.projectName=\(Self.fixtureProjectKey)",
            "-Dsonar.projectBaseDir=\(fixture.path)",
            "-Dsonar.sources=.",
            "-Dsonar.scm.disabled=true",
        ]
    }

    /// Namespaced so a self-check can never land on top of a project the user
    /// scanned.
    ///
    /// Public because verifying the scanner means really scanning something,
    /// and a real scan is really uploaded — so this project appears on the
    /// user's own dashboard alongside their work, having never been asked
    /// for. It cannot be deleted from here (`Deps` may not reach `SonarAPI`,
    /// and it should not: a dependency that could delete projects is a
    /// dependency with far too much reach), so the barrel filters it out of
    /// what it reports. Naming it here keeps the filter and the fixture from
    /// drifting apart, which a copied string literal would guarantee.
    public static let fixtureProjectKey = "oilbird-scanner-selfcheck"

    /// Why the scan failed, short enough to show and complete enough to file.
    ///
    /// Safe to quote because the token travelled by environment: the scanner
    /// echoes its arguments on failure, and there is nothing secret in them.
    private func describe(_ result: Child.Result) -> String {
        let output = result.stderr.isEmpty ? result.stdout : result.stderr
        Log.error("scanner fixture scan exited \(result.status)\n\(output)")
        // Before the output is read, because there is none. A quarantined
        // JVM is killed on exec and the branch below would report "exited 9
        // without saying why" — true, useless, and about the wrong program.
        if result.killedBySIGKILL {
            return "macOS blocked it — the quarantine attribute was not removed"
        }
        let lastLine =
            output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
        guard let lastLine else {
            return "The scanner exited \(result.status) without saying why."
        }
        return "The scanner exited \(result.status): \(lastLine)"
    }
}
