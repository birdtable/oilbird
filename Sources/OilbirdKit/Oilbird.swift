import Foundation
import OilbirdCore
import OilbirdModel

/// The one facade every client calls.
///
/// The GUI, the CLI and the MCP server each map their own vocabulary onto this
/// and add nothing. A behaviour reachable from one client and not the others is
/// a defect — which is also why the wording of a failure lives here and not in
/// three places that would drift.
public enum Oilbird {
    public typealias Error = OilbirdError
    public typealias DependencyID = OilbirdModel.DependencyID
    public typealias DependencyHealth = OilbirdModel.DependencyHealth

    /// Every managed dependency, in install order.
    ///
    /// ⚠ All four. `Scan.run` has launched `sonar-scanner` since the scan
    /// pipeline landed, while this list carried only three — so `install`
    /// provisioned everything except the one thing `scan` needs, and the
    /// clean-machine gate would have failed at its last step for a reason
    /// nothing pointed at. A conformance that exists but is not enumerated is
    /// not installed.
    ///
    /// Built per call rather than stored, because the scanner's `verify()`
    /// takes a target it cannot discover for itself: the port is assigned by
    /// the OS at start and the token is a credential its domain must not read
    /// (`ScannerDependency.AnalysisTarget`). A stored list could only ever
    /// construct `ScannerDependency()` with no target — which is to say the
    /// scanner could never be checked, on any machine, in any state. The
    /// injection point has to be here, where the running state and the secrets
    /// are already known.
    public static var dependencies: [any ManagedDependency] {
        [
            SonarQubeDependency(), JDKDependency(), PostgresDependency(),
            ScannerDependency(reportingTo: analysisTarget()),
        ]
    }

    /// The recorded server to point a fixture scan at, or `nil` when none is
    /// recorded.
    static func analysisTarget() -> ScannerDependency.AnalysisTarget? {
        guard let running = status(), let token = Secrets.load()?.analysisToken else { return nil }
        return .init(host: base(running.webPort), token: token)
    }

    /// The same, but only if the server ANSWERS.
    ///
    /// ⚠ Recorded is not running — "presence on disk is not presence", one
    /// layer up from where it usually applies. A hard-killed engine leaves its record behind,
    /// `analysisTarget()` hands the scanner a port nothing is listening on,
    /// and `doctor` then reports `FAIL scanner` over a connection refused —
    /// blaming the one dependency in the list that was fine. `status` gets
    /// this right and says NOT ANSWERING; this is what lets `doctor` say the
    /// same thing in its own words.
    static func liveAnalysisTarget() async -> ScannerDependency.AnalysisTarget? {
        guard let target = analysisTarget(), await isAnswering() else { return nil }
        return target
    }

    /// The dependencies, with the scanner pointed at a server that answers.
    ///
    /// `dependencies` is synchronous and can only ask what is RECORDED, which
    /// is the right question for `survey()`: it calls `detect()` and needs no
    /// server at all. `doctor` runs `verify()`, and there the difference
    /// between recorded and answering is the whole diagnosis.
    static func probedDependencies() async -> [any ManagedDependency] {
        [
            SonarQubeDependency(), JDKDependency(), PostgresDependency(),
            ScannerDependency(reportingTo: await liveAnalysisTarget()),
        ]
    }

    // MARK: doctor

    public struct Diagnosis: Sendable {
        public let id: DependencyID
        public let outcome: Outcome

        public init(id: DependencyID, outcome: Outcome) {
            self.id = id
            self.outcome = outcome
        }

        /// Whether `install` still has work to do here.
        ///
        /// A check that could not run creates no work: the scanner is on disk,
        /// and fetching it a second time would not make a server appear. This
        /// is deliberately a weaker question than "does it work?" — the caller
        /// that needs that one reads the outcome.
        public var needsInstall: Bool {
            switch outcome {
            case .checked(let health), .unverifiable(_, let health):
                if case .present = health { return false }
                return true
            }
        }
    }

    /// What a check produced — which is not always a health.
    ///
    /// `DependencyHealth` has three cases and none of them means *unknown*;
    /// `ScannerDependency.Unverifiable` carries the full argument for why a
    /// fourth would be wrong. This is where that distinction survives the trip
    /// to a client. The first version of `doctor` flattened it — `(try? await
    /// verify()) ?? .corrupt(reason: "verify threw")` — which is the same lie
    /// one layer up, and it reported a perfectly good scanner as damaged.
    ///
    /// It is a wrapper rather than an extra health case for the reason that
    /// rules out the extra case: every client switches exhaustively over
    /// `DependencyHealth` and would have swallowed a new one, whereas a new
    /// shape here refuses to compile until each of them has answered the
    /// question.
    public enum Outcome: Sendable {
        /// The workload ran. This is what it found.
        case checked(DependencyHealth)

        /// The workload could not be run yet. `blocked` says why and, being an
        /// `OilbirdError`, carries an action. `onDisk` is the weaker
        /// claim `detect()` can still make: enough to answer "is there
        /// anything left to download?", never enough to answer "does it work?".
        case unverifiable(blocked: OilbirdError, onDisk: DependencyHealth)
    }

    /// The cheap question: is anything still to be downloaded?
    ///
    /// `doctor` answers "does it work?" and pays for it — for the scanner
    /// that means really scanning a fixture, which takes seconds, uploads a
    /// project to the user's own server and needs the server running. The app
    /// asked it on every single launch, to decide between the first-run
    /// window and the main window: a full analysis run, every time the icon
    /// was clicked, to answer a question `detect()` answers by listing a
    /// directory.
    ///
    /// It is a separate function and not a flag on `doctor`, because the two
    /// answer different questions and only the name keeps that straight. Nothing
    /// counts until `verify()` passes, and this does not weaken that: nothing
    /// here reports `.present` as a verified claim — `Diagnosis.needsInstall`
    /// is explicitly the weaker question, and a caller wanting the strong one
    /// still has exactly one way to ask.
    public static func survey() -> [Diagnosis] {
        dependencies.map { Diagnosis(id: $0.id, outcome: .checked($0.detect())) }
    }

    /// Runs `verify()`, not `detect()` — presence on disk is not presence.
    public static func doctor() async -> [Diagnosis] {
        await doctor(reporting: { _, _ in })
    }

    /// The same report, delivered a row at a time.
    ///
    /// ⚠ **`doctor` was silent for 7.45 seconds and then printed all four rows
    /// at once.** Measured on a real machine, and it is the worst kind
    /// of silence: every row runs the thing it names — the JDK boots
    /// Elasticsearch, PostgreSQL runs `initdb` and a round trip, the scanner
    /// analyses a real fixture — so the wait is real work and there was no way
    /// to tell it from a hang. A tool that looks hung gets killed.
    ///
    /// `onStart` fires before a check begins and `onResult` when it lands, so
    /// a client can say which dependency it is waiting on and then replace
    /// that with the answer. **The rows arriving is the progress**; nothing
    /// here counts anything, because there is nothing to count.
    ///
    /// ⚠ A separate function rather than a defaulted parameter on `doctor()`.
    /// A default argument changes the mangled symbol of the function it is
    /// added to, and `swift build` does not reliably rebuild the test target
    /// after that — which surfaces as a linker error against a name that is
    /// plainly right in the source.
    /// ⚠ The callback is `async`, and deliberately NOT `@MainActor`.
    ///
    /// It exists to draw, and drawing is a main-actor concern, so isolating
    /// it to the main actor looked right and deadlocked the suite: the
    /// harness calls `runSync { await Oilbird.doctor() }`, which blocks the
    /// main thread on a dispatch group, and a `@MainActor` callback can never
    /// run while that thread is blocked. It hung in `__ulock_wait` with no
    /// error at all.
    ///
    /// `async` gives a caller that draws the hop it needs — `await
    /// MainActor.run { … }` inside its own closure — while the no-op default
    /// touches no actor and cannot deadlock anything.
    public static func doctor(
        reporting progress: @Sendable (DependencyID, Diagnosis?) async -> Void
    ) async -> [Diagnosis] {
        var report: [Diagnosis] = []
        for dependency in await probedDependencies() {
            await progress(dependency.id, nil)
            let diagnosis = Diagnosis(id: dependency.id, outcome: await check(dependency))
            await progress(dependency.id, diagnosis)
            report.append(diagnosis)
        }
        return report
    }

    /// `verify()` with its two failure modes told apart.
    ///
    /// Only `.notCheckable` becomes `.unverifiable`. Anything else `verify()`
    /// throws is a real failure of a real check — a child that would not launch
    /// is not the same as a check that was never attempted, and collapsing them
    /// would hide the first behind the second.
    static func check(_ dependency: any ManagedDependency) async -> Outcome {
        let outcome: Outcome
        do {
            outcome = .checked(try await dependency.verify())
        } catch let error as OilbirdError where error.cause == .notCheckable {
            outcome = .unverifiable(blocked: error, onDisk: dependency.detect())
        } catch let error as OilbirdError {
            outcome = .checked(.corrupt(reason: error.detail))
        } catch {
            outcome = .checked(.corrupt(reason: "The check for this could not be completed."))
        }
        await tidyAfter(dependency)
        return outcome
    }

    /// Removes what a check left behind on the server.
    ///
    /// The scanner's is the only check that leaves anything: it verifies by
    /// really analysing a fixture, and a real analysis is really uploaded.
    /// Filtering the fixture out of `projects()` hid it from the CLI and from
    /// agents, and not at all from the dashboard the app itself displays —
    /// where it sat beside the user's own work.
    ///
    /// ⚠ Awaited, not fired off in a `defer`. The first version launched a
    /// detached `Task`, which for the CLI means the process reaches `exit`
    /// while the delete is still in flight — the same mistake as the log line
    /// queued behind an exit, in a place where it would have looked like a
    /// flaky server rather than a bug.
    static func tidyAfter(_ dependency: any ManagedDependency) async {
        guard dependency.id == .scanner, let target = analysisTarget() else { return }
        let gone = await SonarAPI.deleteProject(
            base: target.host, token: target.token,
            key: ScannerDependency.fixtureProjectKey)
        if !gone { Log.warn("the scanner self-check could not remove its fixture project") }
    }

    // MARK: install

    public static func install(
        only wanted: Set<DependencyID>? = nil,
        progress: @Sendable (DependencyID, Int64, Int64) -> Void = { _, _, _ in }
    ) async throws {
        try Owner.acquire()
        defer { Owner.release() }
        Supervise.reapOrphans()

        for dependency in dependencies where wanted?.contains(dependency.id) ?? true {
            let id = dependency.id
            // Cheap before, expensive after. Asking the strong question first
            // runs a full fixture analysis to conclude there is nothing to
            // download.
            if case .present = dependency.detect() { continue }
            try await dependency.install { done, total in progress(id, done, total) }

            // ⚠ Checked AFTER installing, and for "nothing left to install"
            // rather than "verified": the scanner cannot be verified until the
            // server is up, so the stronger question fails a correct install.
            let outcome = await check(dependency)
            guard !Diagnosis(id: id, outcome: outcome).needsInstall else {
                throw OilbirdError(
                    .verifyFailed,
                    "\(id.rawValue) downloaded but does not work.",
                    recovery: .reinstall(id),
                    underlying: "post-install check: \(outcome)")
            }
        }
    }

    // MARK: failures

    /// Writes a failure's diagnosis to the log.
    ///
    /// `OilbirdError.underlying` is documented "Log only, never shown", and
    /// until this existed nothing wrote it anywhere. Every failure assembled
    /// its exit code, its response body and its paths into a string that was
    /// then dropped on the floor — which is how "change_password returned 400"
    /// reached a person with SonarQube's own explanation of the 400 discarded
    /// three lines earlier, and no way to get it back short of a rebuild.
    ///
    /// It lives on the barrel because a client may reference nothing else, and
    /// `Log` sits below `Model` in the dependency order — it cannot be handed
    /// an `OilbirdError` to format. Clients call this and then say their piece.
    public static func record(_ error: Swift.Error) {
        if let oilbird = error as? OilbirdError {
            Log.error(
                "\(oilbird.cause.rawValue): \(oilbird.detail) "
                    + "[\(oilbird.underlying ?? "no further detail")]")
        } else {
            Log.error("unexpected failure: \(String(describing: error))")
        }
        // Every caller of this is on its way to `exit`, and the log is written
        // on a queue. Without this the line above is dropped along with the
        // thread that would have written it.
        Log.flush()
    }

    // MARK: scan

    public static func scan(
        path: URL, onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Scan.Result {
        try await scan(path: path, onPhase: { _ in }, onLine: onLine)
    }

    /// The same, reporting the engine start it may have to do first.
    ///
    /// ⚠ A separate function rather than a defaulted parameter, for the
    /// reason `ensureRunning(onPhase:)` carries — and the start is reported
    /// from HERE rather than before the call, because the recording below
    /// has to exist before the engine is touched. A CLI that started the
    /// engine first and then called this exited on the engine's error with
    /// nothing written, and `--detach`'s parent waited out its whole
    /// hundred-attempt loop for a child that had already gone.
    public static func scan(
        path: URL,
        onPhase: @escaping @Sendable (Phase) -> Void,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Scan.Result {
        // ⚠ Held for the whole scan. A large analysis outlasts the idle
        // interval, and without this the watchdog stops the engine underneath
        // it: the server appears to crash mid-analysis, occasionally.
        let attachment = Idle.Attachment(reason: "scan \(path.lastPathComponent)")
        defer { withExtendedLifetime(attachment) {} }
        // ⚠ Recorded in the FACADE, so every client does it without
        // remembering to. That is why a scan started in the window can be
        // followed from a terminal.
        let key = Project.infer(at: path).key
        let recording = Scans.begin(key: key, path: path)
        defer { recording?.close() }
        do {
            // Attach FIRST, then start. Taken the other way round, the engine
            // could be stopped by the watchdog between coming up and this scan
            // reaching it.
            let running = try await ensureRunning(onPhase: onPhase)
            // The client never sees the token. Through `workingToken`, so a
            // scan started after the user revoked it mints a new one rather
            // than failing at the end of a long analysis with a bare 401.
            let token = try await workingToken(on: running)
            // One analysis per project: SonarQube refuses two and refuses them
            // BOTH. The user's exclusions are read here and not by `Scan`,
            // which may not see `Prefs`.
            let preferences = Preferences.load()
            // ⚠ Merged HERE because `-Dsonar.exclusions` overrides what
            // `api/settings/set` wrote: otherwise an exclusion is accepted,
            // shown on screen, and ignored by the thing that analyses.
            let (running2, token2) = try await connected()
            let ownExclusions = await SonarAPI.projectSettings(
                base: base(running2.webPort), token: token2, key: key
            ).exclusions
            let result = try await Owner.serialised(named: key) {
                try await Scan.run(
                    path: path, token: token, serverPort: running.webPort,
                    called: preferences.projectNames?[key],
                    alsoExcluding: preferences.neverAnalysed + ownExclusions,
                    alsoTests: preferences.treatedAsTests,
                    onLine: { line in
                        recording?.write(line)
                        onLine(line)
                    })
            }
            if recording != nil { Scans.finish(key: key, outcome: await outcome(of: result)) }
            return result
        } catch let error as OilbirdError {
            if recording != nil { Scans.finish(key: key, outcome: .failed(error.detail)) }
            throw error
        } catch {
            if recording != nil {
                Scans.finish(key: key, outcome: .failed("The scan did not finish."))
            }
            throw error
        }
    }

    /// What to write down about a scan that finished.
    ///
    /// The gate is asked once, here, at the only moment it is cheap: the
    /// engine is up and the analysis has just been processed. `oilbird scans`
    /// reads this from disk afterwards, because answering "did that pass?"
    /// must not start 1.6 GB of engine. Best-effort — a verdict
    /// we could not fetch is recorded as absent, never as a pass.
    static func outcome(of result: Scan.Result) async -> Scans.Outcome {
        guard !result.readNothing else { return .readNothing }
        let gate = try? await qualityGate(projectKey: result.key)
        return .completed(
            Scans.Finished(
                files: result.filesAnalysed, lines: result.linesAnalysed,
                degraded: result.degraded, gate: gate?.gate.rawValue,
                judgedNothing: gate?.judgedNothing ?? false))
    }

    /// What this build of Oilbird pins, and which build it is.
    ///
    /// ⚠ The one answer to "which SonarQube am I running?". `Manifest` is
    /// referenced by no file under `Sources/OilbirdApp`, and the standard
    /// About panel cannot show the `OilbirdBuild` stamp the Makefile writes,
    /// so it displays "Oilbird 0.1.0 (1)" and nothing else; `doctor` speaks
    /// only for dependencies it has already installed.
    ///
    /// This is the PINNED side only: what this build intends to run. What
    /// is actually installed is `doctor`'s question, and `doctor` does not
    /// yet answer it honestly for every dependency — the scanner row
    /// reports the pinned version whatever jar is on disk. Keeping the two
    /// apart in the output is the point, not a limitation of it: "pinned"
    /// and "installed" differing is exactly the thing a person asking this
    /// question is trying to find out.
    public struct Pinned: Sendable {
        public let id: String
        public let version: String
        public let licence: String
        /// What a first run will move for this dependency, as the manifest
        /// records it.
        ///
        /// ⚠ Carried here so the setup window can stop keeping its own copy.
        /// It held four literals — 946_639_592 and three more — beside a
        /// comment about telling the user the truth, which is a size string
        /// outside the manifest — a dependency's version facts live in the
        /// manifest and nowhere else. A bump would have left the disclosure the
        /// user consents to describing the previous release.
        public let bytes: Int64
    }

    /// In `DependencyID` order, which is the order they are installed in.
    ///
    /// `entry()` rather than the dictionary, so a manifest missing an entry
    /// throws with the list of what it does have instead of quietly
    /// reporting three dependencies where there should be four.
    public static func pinned() throws -> [Pinned] {
        let manifest = try Manifest.bundled()
        return try DependencyID.allCases.map { id in
            let entry = try manifest.entry(id)
            return Pinned(
                id: id.rawValue, version: entry.version, licence: entry.licence,
                bytes: entry.bytes)
        }
    }

    /// Everything a first run downloads, added up.
    ///
    /// The number the user is shown before the first byte is fetched.
    public static func firstRunBytes() throws -> Int64 {
        try pinned().reduce(0) { $0 + $1.bytes }
    }

    /// A byte count as a person reads it.
    ///
    /// ⚠ **Decimal, and the unit in the label is the unit in the sum.** This
    /// divided by 1024 twice and then wrote "GB", so the 1,220,217,353 bytes
    /// of a first run were disclosed as "1.14 GB" — 7% short of what the
    /// download actually moves, in the one sentence the user reads *before*
    /// consenting to it. Decimal rather than relabelling to GiB
    /// because that is what Finder shows for free space, what the
    /// publishers' own pages say, and therefore what the number is being
    /// compared against.
    public static func humanBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let megabytes = Double(bytes) / 1_000_000
        return megabytes >= 1000
            ? String(format: "%.2f GB", megabytes / 1000)
            : String(format: "%.0f MB", megabytes)
    }

    /// The build of Oilbird itself: version, and the commit it came from.
    ///
    /// The commit is `nil` when Oilbird is running from `swift run` rather
    /// than a bundle, which is honest — there is no stamp to read, and a
    /// made-up one would be worse than none in a bug report.
    public static var build: (version: String, commit: String?) {
        // ⚠ Key by key, never `??` on the dictionaries: a bare executable's
        // `Bundle.main` is NOT nil, so the fallback never fires and the stamp
        // stays missing.
        let main = Bundle.main.infoDictionary ?? [:]
        let beside = bundledInfo() ?? [:]
        func read(_ key: String) -> String? {
            (main[key] as? String) ?? (beside[key] as? String)
        }
        return (read("CFBundleShortVersionString") ?? "0.1.0", read("OilbirdBuild"))
    }

    /// `Contents/Info.plist`, found from the executable rather than asked of
    /// `Bundle.main`. Symlinks resolved, or a `cli-install`ed Oilbird looks
    /// like it lives in `/usr/local/bin`.
    private static func bundledInfo() -> [String: Any]? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let plist =
            executable
            .deletingLastPathComponent()  // Contents/MacOS or Contents/Helpers
            .deletingLastPathComponent()  // Contents
            .appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
    }

    /// A browser session for the embedded dashboard.
    ///
    /// The app asks for this and gets cookies; the password never crosses
    /// the boundary. `Secrets` holds the credential, this mints a session
    /// from it, and the view renders — which is the same shape as `scan`
    /// taking the analysis token and returning results.
    ///
    /// Empty means the engine is not running or the sign-in was refused. The
    /// caller shows its paused or error state rather than a login form the
    /// user cannot fill in.
    public static func webSession() async -> [HTTPCookie] {
        guard let running = status(), let password = Secrets.load()?.adminPassword else {
            return []
        }
        return await SonarAPI.login(base: base(running.webPort), password: password)
    }

    // MARK: reading results

    // Each of these takes the token from Secrets and never returns it. A client
    // asks a question and gets data.

    public static func issues(projectKey: String, severities: [String] = []) async throws
        -> SonarAPI.Issues
    {
        let attachment = Idle.Attachment(reason: "issues")
        defer { withExtendedLifetime(attachment) {} }
        let (running, token) = try await connected()
        let found = try await SonarAPI.issues(
            base: base(running.webPort), token: token, projectKey: projectKey,
            severities: severities)
        // Empty is ambiguous, and only then is it worth a second call: a
        // project with no issues and a project that does not exist looked
        // identical, so a typo read as a clean bill of health.
        if found.issues.isEmpty,
            await !SonarAPI.projectExists(
                base: base(running.webPort), token: token, projectKey: projectKey)
        {
            throw OilbirdError(
                .verifyFailed, "There is no project called '\(projectKey)'.",
                recovery: .chooseAlternative("List projects"),
                underlying: "api/components/show found no \(projectKey)")
        }
        // ⚠ Asked AFTER the issues: an extra round trip on a much-used verb,
        // buying only each row's label, which is worth it but not before we
        // know there is anything to label.
        guard !found.issues.isEmpty else { return found }
        return SonarAPI.Issues(
            issues: found.issues, total: found.total,
            taxonomy: await SonarAPI.taxonomy(base: base(running.webPort), token: token))
    }

    public static func qualityGate(projectKey: String) async throws -> SonarAPI.GateResult {
        let attachment = Idle.Attachment(reason: "gate")
        defer { withExtendedLifetime(attachment) {} }
        let (running, token) = try await connected()
        var result = try await SonarAPI.qualityGate(
            base: base(running.webPort), token: token, projectKey: projectKey)
        // The verdict and "was there anything to judge?" come from two
        // endpoints and only the facade can ask both, so no surface can
        // forget one.
        result.linesAnalysed = await SonarAPI.analysedSize(
            base: base(running.webPort), token: token, projectKey: projectKey
        ).lines
        return result
    }

    public static func projects() async throws -> [SonarAPI.Project] {
        let attachment = Idle.Attachment(reason: "projects")
        defer { withExtendedLifetime(attachment) {} }
        let (running, token) = try await connected()
        // Belt to `check`'s braces: the self-check deletes its fixture, but a
        // delete can fail and there is a window before it. Neither is a reason
        // to show a project the user did not scan.
        return try await SonarAPI.projects(base: base(running.webPort), token: token)
            .filter { $0.key != ScannerDependency.fixtureProjectKey }
    }

    // MARK: the log

    /// Where the log lives, so a client can name it.
    public static var logPath: String { Paths.Cache.log.path }

    /// The tail of the log.
    ///
    /// Re-exported because "Show log" is the recovery on half of Oilbird's
    /// failures and there was no way to show it — an action that names a
    /// command which does not exist is a dead end.
    public static func recentLog(lines: Int = 80) -> String {
        guard let text = try? String(contentsOf: Paths.Cache.log, encoding: .utf8) else {
            return ""
        }
        // ⚠ No `max(1, …)`: it makes `log 0` and `log -5` print ONE line,
        // which reads as a very quiet log rather than a refused argument. Zero
        // lines is a coherent request; a negative one the caller refuses.
        return text.split(separator: "\n").suffix(max(0, lines)).joined(separator: "\n")
    }

    /// Removes a project and everything analysed under it.
    ///
    /// A scan of a throwaway directory left a project on the dashboard for
    /// ever: no verb removed one, and the REST API rightly refuses a caller
    /// that does not hold the credential — which no client does, by design.
    /// So the barrel, which holds it, has to offer this.
    @discardableResult
    public static func forget(projectKey: String) async throws -> Bool {
        let (running, token) = try await connected()
        let gone = await SonarAPI.deleteProject(
            base: base(running.webPort), token: token, key: projectKey)
        // What was recorded goes with the project it describes: a scan listed
        // for a project that no longer exists is a row whose every next step
        // is a dead end.
        if gone { Scans.forget(key: projectKey) }
        return gone
    }

    /// Everything worth knowing about a project, in three requests.
    ///
    /// The question a developer actually asks is *"how is this code, and
    /// what should I fix first?"* — and answering it used to mean pulling
    /// every issue and aggregating them by hand. The server has already
    /// done the aggregation.
    public struct Summary: Sendable {
        public let project: String
        public let gate: SonarAPI.GateResult
        public let measures: [String: String]
        public let severities: [String: Int]
        public let types: [String: Int]
        public let total: Int
        /// Which taxonomy the numbers above are counted in. Carried rather
        /// than re-derived: a screen that asked again could print a heading
        /// from one answer over figures from another.
        public let taxonomy: SonarAPI.Taxonomy

        /// Public because the suite imports this the way a client does —
        /// no `@testable` anywhere in `Tests` — so a screen that takes a
        /// `Summary` is untestable without it.
        public init(
            project: String, gate: SonarAPI.GateResult, measures: [String: String],
            severities: [String: Int], types: [String: Int], total: Int,
            taxonomy: SonarAPI.Taxonomy = .standard
        ) {
            self.project = project
            self.gate = gate
            self.measures = measures
            self.severities = severities
            self.types = types
            self.total = total
            self.taxonomy = taxonomy
        }
    }

    /// What happened when we tried to open a file where the reader edits.
    public enum Edited: Sendable, Equatable {
        case opened
        case noEditor
        case notFound(String)
    }

    /// Open one file at one line in `$EDITOR`.
    ///
    /// ⚠ `$EDITOR` and nothing else. Guessing an editor is guessing about
    /// somebody's machine, and the way that fails is a program they did not
    /// ask for opening on top of the terminal they were reading. Unset is a
    /// sentence, not a default.
    ///
    /// ⚠ The child inherits this terminal exactly as it was found — the
    /// browser hands back cooked mode before calling — because an editor
    /// given a terminal in cbreak mode paints over a screen it did not draw
    /// and cannot read its own keys.
    public static func edit(file: String, line: Int?) async -> Edited {
        let environment = ProcessInfo.processInfo.environment
        guard let editor = environment["EDITOR"],
            !editor.trimmingCharacters(
                in: .whitespaces
            ).isEmpty
        else { return .noEditor }
        var argv = editor.split(separator: " ").map(String.init)
        let named = argv.removeFirst()
        // `+N file` is what vi, vim, nano, emacs, helix and micro all take.
        if let line { argv.append("+\(line)") }
        argv.append(file)
        // ⚠ Through `env`, the one place that does NOT resolve an absolute
        // path first. A RUNTIME we did not install is never launched by name;
        // `$EDITOR` is the program this person named.
        let binary = named.contains("/") ? URL(filePath: named) : URL(filePath: "/usr/bin/env")
        let arguments = named.contains("/") ? argv : [named] + argv
        guard (try? Child.inheritingTerminal(binary, arguments)) != nil else {
            return .notFound(named)
        }
        return .opened
    }

    /// When the engine stops itself, as a person would say it.
    ///
    /// ⚠ In Kit because BOTH surfaces say it. Phrased in each surface, the
    /// CLI's "after 30 minutes unused" and the menu bar's "stops 30m unused"
    /// are one fact with two phrasings — the drift the `parity` check
    /// catches where a script can see it and nothing catches where only a
    /// person can.
    public static func idlePhrase() -> String {
        switch idleTimeout() {
        case .never: "only when you ask"
        case .after(let minutes) where minutes.isMultiple(of: 60):
            "after \(minutes / 60) hour\(minutes == 60 ? "" : "s") unused"
        case .after(let minutes): "after \(minutes) minutes unused"
        }
    }

    /// The one line the menu bar leads with.
    ///
    /// ⚠ **The word alone was not worth a line.** It read `Paused`, and a
    /// person opens this menu to find out what Oilbird is COSTING them —
    /// whether it is holding 1.6 GB, and when it will stop. The state was
    /// already on the icon, dimmed; repeating it and nothing else made the
    /// first row of the menu the least informative thing in it.
    ///
    /// Paused says nothing more because there is nothing more: no port, no
    /// memory, and an idle rule that has already fired.
    public static func menuHeading(for state: EngineState) -> String {
        guard case .running = state else { return state.heading }
        let facts = [
            engineDetail()?.residentBytes.map(humanBytes),
            "stops " + idlePhrase(),
        ].compactMap { $0 }
        return ([state.heading] + facts).joined(separator: "  ·  ")
    }

    /// Where a plugin jar goes, in the form a person reads.
    ///
    /// SonarQube ships this directory with its own README saying to put jars
    /// there. Oilbird now carries whatever is in it across an upgrade, which
    /// it did not before — see `Install.carried`.
    public static var pluginFolder: String {
        displayPath(Paths.Cache.sonarqube.appending(path: "extensions/plugins").path)
    }

    /// The severity words each kind of server uses, named for a client
    /// that cannot see `SonarAPI` — `domains.yaml` lets `MCPClient`
    /// reference `Kit` and nothing else.
    ///
    /// ⚠ Both, because a client has to be able to SAY both. SonarQube
    /// refuses an unknown severity by naming the legal ones, and under MQR
    /// it names the LEGACY five — so an agent that sent `SEVERE` was told
    /// to use `CRITICAL` when the word this server actually uses is `HIGH`.
    /// Everything Oilbird can configure about one project.
    public struct Configuration: Sendable, Equatable {
        public let project: String
        /// Applied by the next scan, not now — SonarQube has no rename.
        public let chosenName: String?
        public let tags: [String]
        public let newCode: String?
        public let newCodeInherited: Bool
        public let exclusions: [String]
        /// What the main branch is called. Community Build has exactly one,
        /// so this is a label rather than a choice.
        public let branch: String?
    }

    // MARK: preferences

    public typealias IdleTimeout = Preferences.IdleTimeout

    public static func idleTimeout() -> IdleTimeout { Preferences.load().idleTimeout }

    public static func setIdleTimeout(_ timeout: IdleTimeout) throws {
        var stored = Preferences.load()
        stored.idleTimeout = timeout
        try Preferences.save(stored)
    }

    /// Whether the services should stop now, given when they were last used.
    /// No client owns the lifetime, so no client decides this alone.
    public static func shouldStopWhenIdle(since lastUse: Date) -> Bool {
        Preferences.shouldStopWhenIdle(since: lastUse)
    }

    public typealias Settings = Preferences.Stored
    public typealias WebMemory = Preferences.WebMemory
    public typealias Appearance = Preferences.Appearance

    /// Where the choices are written.
    ///
    /// A plist under the config root rather than `UserDefaults`, so it
    /// follows `OILBIRD_HOME` like everything else — and so there is a file
    /// to show someone when a setting is not doing what they expect.
    public static var settingsFilePath: String { Paths.config.path }

    /// Everything the user has chosen, in one read.
    ///
    /// The settings window draws eleven controls; asking for each field
    /// separately would be eleven plist reads to build one pane, and any
    /// two of them could disagree about a file being rewritten underneath.
    public static func settings() -> Settings { Preferences.load() }

    /// Changes one or more choices and writes them back.
    ///
    /// Read-modify-write in one place, because the alternative — a setter
    /// per field, each loading and saving the whole struct — loses whatever
    /// another surface wrote between the load and the save. `up()` writes
    /// `lastPorts` from a background task while this window is open, which
    /// is exactly that race.
    public static func updateSettings(_ change: (inout Settings) -> Void) throws {
        var stored = Preferences.load()
        change(&stored)
        try Preferences.save(stored)
    }

    // MARK: the SonarQube tint

    /// The stylesheet Oilbird paints over SonarQube's dashboard, as a script
    /// ready to inject.
    ///
    /// Re-exported here rather than reached directly, because a client sees the
    /// barrel and never a core submodule — the boundary gate caught the first
    /// attempt to shortcut it. The palette and the escaping live in the core
    /// where they are tested; the client only decides when to inject.
    public static var tintScript: String { Tint.script }

    /// The narrowest the window may be before the embedded dashboard is
    /// simply cut off.
    ///
    /// Taken from SonarQube's own lowest media-query breakpoint rather than
    /// chosen: below it the UI does not reflow, it clips. Falls back to a
    /// value that is still above the old 900 if the vocabulary cannot be
    /// read, because guessing narrow is the failure this exists to prevent.
    /// What the window has to add to the content's own width.
    ///
    /// The container is 1280 wide; the page puts padding either side of it
    /// and macOS puts a scrollbar down the right. A window of exactly 1280
    /// therefore still scrolls horizontally.
    static let dashboardChrome: CGFloat = 64

    public static var minimumWindowWidth: CGFloat {
        let content = Tint.vocabulary()?.minimumViewport ?? 0
        return (content > 0 ? content : 1280) + dashboardChrome
    }

    // MARK: the command line tool

    public typealias CLIState = CommandLineTool.State

    public static func cliState() -> CLIState { CommandLineTool.state() }

    /// Points the link at the CLI shipped beside whatever is running, so a
    /// development build and an installed app each install themselves rather
    /// than each other.
    ///
    /// ⚠ **It used to link `CommandLine.arguments[0]`, and from the GUI that
    /// is `Contents/MacOS/Oilbird` — the application.** So on any Mac where
    /// the write succeeded, Settings ▸ Install produced an `oilbird` that
    /// opened a window instead of answering `oilbird status`: worse than the
    /// EACCES failure beside it, because it looked like it had worked.
    /// `cliBinary()` is the same resolution `Bundled.swift` and
    /// `Oilbird.build` use, and `manualCLIInstall` now quotes it too, so the
    /// button and the command it offers as a fallback cannot name different
    /// files.
    public static func installCLI() throws {
        guard let binary = cliBinary() else {
            throw OilbirdError(
                .verifyFailed,
                "Oilbird cannot find its own command line tool.",
                recovery: .reportIssue("Reinstall Oilbird"),
                underlying:
                    "no \(CommandLineTool.bundleRelativePath) beside "
                    + (Bundle.main.executableURL?.path ?? "the running executable"))
        }
        try CommandLineTool.install(binary: binary)
    }

    public static func uninstallCLI() throws { try CommandLineTool.uninstall() }

    /// The one line a user can run when Oilbird is not allowed to write the
    /// link itself.
    ///
    /// `/usr/local/bin` is `root:wheel` on a stock Mac, and Oilbird neither
    /// has those rights nor asks for them: the link is an opt-in, not a
    /// request for root. Refusing without saying what would work is a
    /// dead end, so the surface that offered Install offers this
    /// instead.
    ///
    /// ⚠ Names the CLI inside the bundle rather than the running
    /// executable. From the GUI `CommandLine.arguments[0]` is the app
    /// itself, and a link to that would make `oilbird status` open a window.
    ///
    /// The same `cliBinary()` the button uses, so the line a user pastes
    /// into a terminal and the link Oilbird would have written are the same
    /// file. It fell back to `Bundle.main.bundleURL`, which for a `swift
    /// run` build is the build directory and produced a command naming a
    /// path that does not exist.
    ///
    /// ⚠ Absolute, like the MCP snippet and for the same reason: this is a
    /// line to paste, not a line to read. It is also *quoted*, and a tilde
    /// inside double quotes is a tilde — the shell would make a link to a
    /// directory literally called `~`. `displayPath` belongs on what a
    /// person reads, never on what a machine is handed.
    public static var manualCLIInstall: String {
        let binary =
            cliBinary()?.path
            ?? Bundle.main.bundleURL.appending(path: CommandLineTool.bundleRelativePath).path
        return "sudo ln -s \"\(binary)\" \(CommandLineTool.linkPath)"
    }

    /// Everything that reads from the engine goes through here, so the
    /// attachment covers every client without any of them remembering to
    /// take one — a rule enforced in three clients is a rule that will be
    /// right in two.
    /// ⚠ **It STARTS the engine, and for six verbs it did not.** `--help`
    /// promised that reading from Oilbird starts it if it is paused, `scan`
    /// did, every MCP tool did, and `issues`, `gate`, `summary`, `history`,
    /// `projects` and `forget` answered "Oilbird is not running." instead —
    /// so the product's most-read screen was false for six of the seven verbs
    /// under the heading it was written about. Fixed HERE rather than in the
    /// callers for the reason above: seven remembering is six.
    ///
    /// Cheap when it is already up — `ensureRunning` short-circuits on a
    /// probe — so this does not put a start on the path of a read that did
    /// not need one, and it leaves idle cost where it was: `status`, `doctor`
    /// and `version` do not come through here and still never start anything.
    static func connected() async throws -> (Running, String) {
        let running = try await ensureRunning()
        return (running, try await workingToken(on: running))
    }

    /// Oilbird's token, minted again if the server no longer accepts it.
    ///
    /// ⚠ The user can revoke this token from the dashboard — it is listed on
    /// their own account page, under their own name, with a revoke button
    /// next to it. Nothing there says the desktop app is holding it. When
    /// that happened, every read, every scan and every agent tool failed at
    /// once with `HTTP 401` and an empty body, and there was no way back
    /// short of deleting `credentials.json`: the stored token was dead and
    /// nothing ever replaced it.
    ///
    /// Oilbird holds the admin password, so it can always mint another. It
    /// should, silently — a credential the app issued to itself is the app's
    /// to maintain, not a thing to hand back to the user as an error.
    ///
    /// Checked on every call rather than cached: `authentication/validate`
    /// is one unauthenticated round trip to a server on loopback that this
    /// function has just probed anyway, and a cache would be wrong for
    /// exactly the case this exists for — a long-lived MCP server that
    /// verified the token once at launch and then watched it be revoked.
    static func workingToken(on running: Running) async throws -> String {
        guard var secrets = Secrets.load() else {
            throw OilbirdError(
                .verifyFailed, "Oilbird has no analysis token yet.",
                recovery: .retry("Start it"), underlying: "no credentials stored")
        }
        let base = base(running.webPort)
        if let token = secrets.analysisToken,
            await SonarAPI.accepts(base: base, token: token)
        {
            return token
        }
        let fresh = try await Provisioning.mintToken(base: base, admin: secrets.adminPassword)
        secrets.analysisToken = fresh
        try Secrets.save(secrets)
        Log.warn("analysis token was rejected by the server; minted a replacement")
        return fresh
    }

    static func base(_ port: UInt16) -> URL { Loopback.url(port: port) }
}
