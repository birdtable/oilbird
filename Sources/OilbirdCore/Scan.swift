import Foundation
import OilbirdModel

/// Runs one analysis.
public enum Scan {
    public struct Result: Sendable {
        public let key: String
        /// Where a person can read this analysis.
        ///
        /// The scanner writes it into the working directory and it was
        /// thrown away; a client that had just run a scan could not hand
        /// anyone a link to the thing it had produced. The port is assigned
        /// at start, so it cannot be constructed ahead of time either.
        public let dashboard: URL?
        public let toolchain: Project.Toolchain
        /// True when the analysis ran without coverage because the project's
        /// own build toolchain was unavailable.
        public let degraded: Bool
        public let degradedReason: String?
        /// What the analysis actually read.
        ///
        /// ⚠ Oilbird ran the scanner and never asked this, so a scan that
        /// read NOTHING was reported exactly like a scan of clean code.
        /// `Result` carried no count, the CLI printed none, and `measure()`
        /// prints a row only when the key is present — so a missing `ncloc`
        /// was an absence rather than a message. Reproduced five ways: a
        /// dot-prefixed directory, an empty one, a docs-only one, a
        /// tests-only repository, and one whose single file exceeded the
        /// scanner's 20 MB ceiling. All: `gate OK`, exit 0.
        public let filesAnalysed: Int
        public let linesAnalysed: Int
        /// True when the analysis read no source at all. Not an error — the
        /// scanner did its job — but it is never a pass either.
        public var readNothing: Bool { linesAnalysed == 0 }

        /// Public so the suite can build one. The memberwise initializer a
        /// struct gets for free is internal, and a result type nothing
        /// outside the module can construct cannot be asserted against.
        public init(
            key: String, dashboard: URL?, toolchain: Project.Toolchain, degraded: Bool,
            degradedReason: String?, filesAnalysed: Int, linesAnalysed: Int
        ) {
            self.key = key
            self.dashboard = dashboard
            self.toolchain = toolchain
            self.degraded = degraded
            self.degradedReason = degradedReason
            self.filesAnalysed = filesAnalysed
            self.linesAnalysed = linesAnalysed
        }
    }

    /// Analyses a directory.
    ///
    /// ⚠ **A degraded scan is reported as degraded.** For a JVM project the
    /// build plugin beats the scanner CLI — it resolves the reactor, the
    /// compiled classes and the JaCoCo report, none of which the CLI finds
    /// unaided. But the plugin runs under the *project's* toolchain, not
    /// Oilbird's: our JDK is deliberately not on the user's `PATH`, and the
    /// project may need a specific one. A common setup shows the failure
    /// exactly — Maven installed, `java` only the macOS stub.
    ///
    /// So the CLI is used and the result says so. Presenting a coverage-less
    /// scan as a normal one would make Oilbird lie about code quality, which is
    /// the one thing it must not do.
    /// - Parameters:
    ///   - alsoExcluding: the user's own never-analyse globs. Injected
    ///     because this domain may not see `Prefs`; Kit reads them.
    ///   - alsoTests: the same, for what is scored as test code.
    public static func run(
        path: URL, token: String, serverPort: UInt16,
        alsoExcluding: [String] = [], alsoTests: [String] = [],
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Result {
        try await run(
            path: path, token: token, serverPort: serverPort, called: nil,
            alsoExcluding: alsoExcluding, alsoTests: alsoTests, onLine: onLine)
    }

    /// The same, under a name the user chose.
    ///
    /// ⚠ A separate function rather than a defaulted parameter, for the
    /// reason `ensureRunning(onPhase:)` carries — and this one bit at the
    /// LINKER once already, so it is not a theoretical hazard here.
    ///
    /// ⚠ `called` is the only way a project's name can be changed at all.
    /// Counted from `api/webservices/list` with internals included,
    /// `api/projects` has `create`, `delete`, `bulk_delete`, `update_key`
    /// and `update_visibility` — and nothing that renames. An analysis
    /// carrying `sonar.projectName` is it.
    public static func run(
        path: URL, token: String, serverPort: UInt16, called: String?,
        alsoExcluding: [String] = [], alsoTests: [String] = [],
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Result {
        let project = Project.infer(at: path)
        let degradedReason = degradation(for: project)
        Log.phase("scan \(project.key) (\(project.toolchain.rawValue))")

        // Oilbird never writes into a repository it scans, and a project's own
        // properties file is respected untouched.

        // ⚠ Enforced by `ScannerCommand`, not by this sentence: the scanner
        // writes `.scannerwork` into whatever it analyses unless redirected,
        // along with three other ways out of the container.
        var extra: [String] = []
        if !project.hasOwnProperties {
            extra.append("-Dsonar.projectKey=\(project.key)")
            // ⚠ Without this SonarQube names a project after its key, hash and
            // all, and no endpoint renames one. The scanner is the only thing
            // that sets it, so here or never.
            extra.append("-Dsonar.projectName=\(called ?? project.name)")
            // ⚠ `PREVIOUS_VERSION` needs VERSIONS: without one SonarQube dates
            // the baseline from the first analysis, so "new code" is everything
            // for ever.

            // A distinct version per analysis makes new code mean "what
            // changed since you last scanned", which is the question someone
            // has in front of their own repository.

            // ⚠ The timestamp, not the git SHA: `git` is not on a clean Mac and
            // invoking it raises the Command Line Tools installer, a dead end
            // from a runtime we did not install.
            extra.append("-Dsonar.projectVersion=\(Scan.versionStamp())")
            extra.append("-Dsonar.sources=.")
            if let coverage = project.coverageProperty { extra.append("-D\(coverage)") }
        }
        let launch = try ScannerCommand.launch(
            hostPort: serverPort, projectKey: project.key,
            alsoExcluding: alsoExcluding, alsoTests: alsoTests, extra: extra)

        // The token goes in the ENVIRONMENT, never argv: the scanner echoes its
        // arguments on failure, and argv is visible in `ps`. That ordering is
        // what makes it safe to log the command line verbatim.
        let environment = Resolver.childEnvironment(adding: ["SONAR_TOKEN": token])

        // ⚠ `onLine` goes to `Child.run`, never to the buffer after: splitting
        // `result.stdout` replays the log in a tight loop once the scanner has
        // exited, so every surface describes a finished scan.
        let result = try await Child.run(
            launch.executable, launch.argv, environment: environment,
            currentDirectory: path, onLine: onLine)

        guard result.status == 0 else {
            throw OilbirdError(
                .verifyFailed, "The scan did not finish.",
                recovery: .retry("Show log"),
                underlying: "sonar-scanner exited \(result.status): "
                    + Secrets.redact(String(result.stderr.suffix(2000))))
        }
        // The scanner reports what it uploaded, in the working directory
        // Oilbird chose. Both of these were sitting on disk unread.
        let receipt = report(in: launch.workingDirectory)
        let base = Loopback.url(port: serverPort)
        if let task = receipt["ceTaskId"] {
            try await SonarAPI.awaitAnalysis(base: base, token: token, task: task)
        }
        // ⚠ After `awaitAnalysis`, never before: the measures do not exist
        // until the compute engine finishes, and asking early returns zero for
        // every project, condemning healthy scans.
        let size = await SonarAPI.analysedSize(base: base, token: token, projectKey: project.key)
        return Result(
            key: project.key,
            dashboard: receipt["dashboardUrl"].flatMap(URL.init(string:)),
            toolchain: project.toolchain,
            degraded: degradedReason != nil, degradedReason: degradedReason,
            filesAnalysed: size.files, linesAnalysed: size.lines)
    }

    /// The version this analysis is recorded under.
    ///
    /// Sortable, second-resolution, and no separators SonarQube's version
    /// ordering could read as something else. Second resolution because two
    /// scans a minute apart must be two versions: sharing one would make the
    /// later analysis add nothing to "new code" and quietly report a clean
    /// gate for work that was never looked at.
    public static func versionStamp(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: now)
    }

    /// `report-task.txt`, the receipt the scanner leaves behind.
    ///
    /// Plain `key=value` lines. Absent or unreadable is not a failure — the
    /// scan itself succeeded, and the only cost is that the caller waits no
    /// longer and gets no link.
    public static func report(in directory: URL) -> [String: String] {
        guard
            let text = try? String(
                contentsOf: directory.appending(path: "report-task.txt"), encoding: .utf8)
        else { return [:] }
        return Dictionary(
            text.split(separator: "\n").compactMap { line -> (String, String)? in
                guard let split = line.firstIndex(of: "=") else { return nil }
                return (String(line[line.startIndex..<split]), String(line[line.index(after: split)...]))
            }, uniquingKeysWith: { first, _ in first })
    }

    /// Why this scan will be worse than it could be, or `nil` if it will not.
    public static func degradation(for project: Project.Inferred) -> String? {
        switch project.toolchain {
        case .maven, .gradle:
            // Oilbird does not install a toolchain for someone else's project.
            // Provisioning its own runtime is the product; provisioning the
            // user's build environment is not.
            let builder = project.toolchain == .maven ? "Maven" : "Gradle"
            return
                "This is a \(builder) project. Oilbird analysed the source only, because "
                + "running the \(builder) plugin needs the project's own build toolchain. "
                + "Test coverage and compiled-class findings are missing."
        case .node, .python, .go, .other:
            return nil
        }
    }
}
