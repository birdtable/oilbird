import Foundation
import OilbirdModel

/// How the scanner is launched — in one place, because there are two callers.
///
/// `Scan.run` analyses the user's project and `ScannerDependency.verify()`
/// analyses a fixture, and each built its own command line. That was tolerable
/// while it was two flags and a `JAVA_HOME`. It is now six flags, four of
/// which exist to stop the scanner downloading things and writing places,
/// and every one of them has to be on both paths or the containment has a
/// hole exactly where nobody is looking.
///
/// It is its own domain so that both callers can reach it: `Scan` and `Deps`
/// cannot see each other, by design, and neither should gain the right to.
public enum ScannerCommand {
    public struct Launch: Sendable {
        public let executable: URL
        public let argv: [String]
        /// Where the scanner writes `report-task.txt` — the receipt naming
        /// the analysis it uploaded and where to read it.
        public let workingDirectory: URL
    }

    /// Everything needed to run the scanner entirely from Oilbird's container.
    ///
    /// The four containment flags, and why each is load-bearing:
    ///
    /// - **`javaExePath`** is the one that matters. The scanner asks the
    ///   server for a JRE and runs the analysis on that, and it does so
    ///   *before* consulting `JAVA_HOME` — which is why setting `JAVA_HOME`
    ///   alone, as this code did, still pulled a 197 MB second JRE of a
    ///   different version to the pinned one and analysed on it.
    /// - **`skipJreProvisioning`** is belt to that braces, and is **not a
    ///   substitute**: on its own it skips the download, falls past
    ///   `JAVA_HOME` to `PATH`, finds the macOS stub and dies with "Unable to
    ///   locate a Java Runtime" — the precise failure this product exists to
    ///   prevent. Measured. The order matters and only `javaExePath` fixes it.
    /// - **`engineJarPath`** points at the analysis engine inside the
    ///   SonarQube we already downloaded and checksummed, instead of letting
    ///   the scanner fetch a second 50 MB copy of it from that same server.
    /// - **`userHome`** and **`working.directory`** move the plugin cache out
    ///   of `~/.sonar` and the per-run working files out of `.scannerwork`
    ///   inside the analysed directory. Without the second, Oilbird writes
    ///   into the user's repository — which it promised it does not.
    /// Directories that are never source code.
    ///
    /// ⚠ Oilbird passed `sonar.sources=.` and no exclusions at
    /// all, so a repository containing `node_modules` — 14,138 files under
    /// 303 MB, against 35.8k lines of actual source — ran for **twenty
    /// minutes and four seconds**, never got past `Preprocessed 0 files`,
    /// and failed with no cause shown.
    ///
    /// ⚠ **A DEFAULT, not a rule, and it used to be a rule.** These were
    /// hardcoded constants the user could add to and never remove, applied
    /// to every project in every language. The claim justifying that —
    /// "these directories are never source in any project" — does not
    /// survive contact with SonarQube's own behaviour: the server ships
    /// `sonar.go.exclusions` and `sonar.php.exclusions` and
    /// `sonar.ruby.exclusions` as `**/vendor/**` and applies them to *those
    /// languages only*, because `vendor/` is a Go, PHP and Ruby convention
    /// and means nothing in a Java or JavaScript project. Every one of the
    /// server's 208 settings definitions is a value the user can change.
    /// Ours was the one list nobody could argue with.
    ///
    /// So this is now the value the preference starts at, and the user may
    /// edit or empty it. The choice of a fixed list over inference
    /// stands: Oilbird still does not guess. It
    /// suggests, visibly, once.
    public static let defaultNeverSource = [
        "**/node_modules/**", "**/bower_components/**", "**/vendor/**",
        "**/dist/**", "**/build/**", "**/.build/**", "**/out/**", "**/target/**",
        "**/__pycache__/**", "**/.venv/**", "**/venv/**", "**/.tox/**",
        "**/coverage/**", "**/.git/**", "**/*.min.js", "**/*.bundle.js",
    ]

    /// What is test code rather than production code.
    ///
    /// ⚠ Patterns, not `sonar.tests` directories, because both
    /// layouts are common and it was the second that bit: on a real project
    /// the single most severe finding — its only BLOCKER — was an
    /// incomplete `expect()` in `checkout.spec.ts`, scored as
    /// production code because nothing said otherwise.
    ///
    /// A default the user owns, for the same reason as `defaultNeverSource`.
    public static let defaultTestPatterns = [
        "**/test/**", "**/tests/**", "**/spec/**", "**/__tests__/**",
        "**/*.test.*", "**/*.spec.*", "**/*_test.*", "**/*Test.*", "**/test_*.py",
    ]

    /// - Parameters:
    ///   - alsoExcluding: the never-analyse globs, WHOLE. Not an addition
    ///     to a built-in list any more — the user owns the list, and
    ///     `defaultNeverSource` is only where it starts. An empty array
    ///     means analyse everything, which is now a thing a person is
    ///     allowed to ask for.
    ///   - alsoTests: the same, for `sonar.test.inclusions`.
    ///
    /// Both are injected because this domain may not see `Prefs`, which is
    /// the same reason the analysis target arrives from outside.
    public static func launch(
        hostPort: UInt16, projectKey: String,
        alsoExcluding: [String] = [], alsoTests: [String] = [],
        extra: [String] = []
    ) throws -> Launch {
        guard let java = Resolver.executable(.java) else {
            throw OilbirdError(
                .verifyFailed, "Java is not installed.",
                recovery: .reinstall(.jdk), underlying: "no java in the container")
        }
        guard let jar = Resolver.scannerJar() else {
            throw OilbirdError(
                .verifyFailed, "The scanner is not installed.",
                recovery: .reinstall(.scanner),
                underlying: "no sonar-scanner-cli jar under \(Paths.Cache.scanner.path)")
        }
        // The engine lives inside SonarQube, so a missing one means that
        // install is wrong — reinstalling the scanner would not help, and
        // saying so would send the user round a loop, a dead end.
        guard let engine = Resolver.scannerEngine() else {
            throw OilbirdError(
                .verifyFailed, "Oilbird cannot find its analysis engine.",
                recovery: .reinstall(.sonarqube),
                underlying: "no unique sonar-scanner-engine jar in the SonarQube install")
        }

        let work = Paths.Cache.scannerWork.appending(path: projectKey)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: Paths.Cache.scannerHome, withIntermediateDirectories: true)

        return Launch(
            executable: java,
            argv: [
                "-Djava.awt.headless=true",
                "-classpath", jar.path,
                "org.sonarsource.scanner.cli.Main",
                "-Dsonar.host.url=http://127.0.0.1:\(hostPort)",
                "-Dsonar.scanner.javaExePath=\(java.path)",
                "-Dsonar.scanner.skipJreProvisioning=true",
                "-Dsonar.scanner.engineJarPath=\(engine.path)",
                "-Dsonar.userHome=\(Paths.Cache.scannerHome.path)",
                "-Dsonar.working.directory=\(work.path)",
                "-Dsonar.exclusions=\(patterns(alsoExcluding))",
                "-Dsonar.test.inclusions=\(patterns(alsoTests))",
            ] + extra,
            workingDirectory: work)
    }

    ///
    /// Blank entries are dropped and a pattern already built in is not
    /// repeated: the user types these into a text field, so "a, ,b" and a
    /// duplicate of something already excluded are both ordinary things to
    /// arrive here, and neither belongs on a command line.
    /// One comma-separated glob list, cleaned but not added to.
    ///
    /// Blanks and duplicates are dropped because a text field collects
    /// both; nothing else is. In particular no pattern is ever put back:
    /// if the user removed `**/node_modules/**`, they meant it.
    public static func patterns(_ globs: [String]) -> String {
        var seen = Set<String>()
        var all: [String] = []
        for pattern in globs {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            all.append(trimmed)
        }
        return all.joined(separator: ",")
    }

    /// A witness for "did this scan write outside the container?".
    ///
    /// Presence is not proof, applied to the containment itself. The flags above are properties
    /// of a third-party tool that Oilbird pins but does not control, and if a
    /// future version drops one the failure is silent: the scanner resumes
    /// downloading a JRE and an engine into the user's home, and every test
    /// still passes.
    ///
    /// ⚠ It compares before against after rather than testing for existence.
    /// `~/.sonar` is not Oilbird's to interpret — a developer who runs
    /// SonarScanner for other work has one, and reporting their directory as
    /// our containment breach would be a false accusation that makes the
    /// self-check useless exactly on the machines most likely to have one.
    /// What matters is whether *this* run touched it.
    public struct Containment: Sendable, Equatable {
        let existed: Bool
        let modified: Date?

        /// The user's `~/.sonar` — where the scanner keeps its cache and puts
        /// a downloaded JRE unless told otherwise.
        static var watched: URL {
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".sonar")
        }

        public static func witness() -> Containment {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: watched.path)
            return Containment(
                existed: attributes != nil,
                modified: attributes?[.modificationDate] as? Date)
        }

        /// What escaped since this witness was taken, as something a person
        /// can read. Empty means nothing did.
        public func escapedSince() -> [String] {
            let now = Containment.witness()
            if !existed && now.existed { return ["\(Containment.watched.path) (created)"] }
            if existed, now.existed, let before = modified, let after = now.modified,
                after > before
            {
                return ["\(Containment.watched.path) (written to)"]
            }
            return []
        }
    }
}
