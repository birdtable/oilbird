import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

/// "Could not check" is not "checked, and broken".
///
/// This suite exists because the distinction was lost between
/// `ScannerDependency.verify()`, which draws it carefully, and the two callers
/// that flattened it. `doctor` wrote `.corrupt(reason: "verify threw")` and
/// told a user with four correct artefacts that their scanner was damaged;
/// `install` read the same throw as a failed install and exited 1 with nothing
/// left to do. Every claim below is one of those two bugs, pinned.
func diagnosisTests() {
    Harness.suite("Diagnosis — a check that could not run is not a failure") {
        // The states are reachable without staging anything, so assert the
        // arithmetic first: needsInstall is about what is on disk, and a
        // blocked check must not add work.
        Harness.test("only what is absent or broken creates work for install") {
            let blocked = ScannerDependency.Unverifiable.noServer.error
            let cases: [(Oilbird.Outcome, Bool)] = [
                (.checked(.present(version: "1")), false),
                (.checked(.missing), true),
                (.checked(.corrupt(reason: "torn")), true),
                // On disk, waiting on a server. Downloading it again cannot
                // make a server appear, so there is nothing to install.
                (.unverifiable(blocked: blocked, onDisk: .present(version: "1")), false),
                // Not on disk AND unverifiable: the download is still owed.
                (.unverifiable(blocked: blocked, onDisk: .missing), true),
            ]
            for (outcome, expected) in cases {
                Harness.expectEqual(
                    Oilbird.Diagnosis(id: .scanner, outcome: outcome).needsInstall, expected,
                    "\(outcome) misjudged whether install has work to do")
            }
        }

        // The way out survives the trip to the client. The old path threw the
        // recovery away and substituted a bare string, which is how
        // "Reinstall" came to be offered for a scanner that was not damaged.
        Harness.test("a blocked check keeps the reason and the action it arrived with") {
            for precondition in ScannerDependency.Unverifiable.allCases {
                let error = precondition.error
                Harness.expectEqual(
                    error.cause, .notCheckable,
                    "\(precondition) is indistinguishable from a real failure")
                Harness.expectNotEmpty(error.detail)
                Harness.expectNotEmpty(error.recovery.actionLabel)
            }
        }

        // The scanner cannot be checked without a server to report to, so on
        // any machine where one is not running the answer must be `waiting`
        // and not `corrupt` — whatever else is installed.
        guard DiagnosisStub.canStage else {
            Harness.test("a real install is present, so the stub suite stands aside") {
                Harness.expectTrue(
                    ScannerDependency().detect() != .missing,
                    "a real install was detected as missing")
            }
            return
        }
        defer { DiagnosisStub.clear() }

        Harness.test("an installed scanner with no server is waiting, never corrupt") {
            DiagnosisStub.clear()
            DiagnosisStub.stage()
            let report = runSync { await Oilbird.doctor() }
            guard case .success(let diagnoses) = report,
                let scanner = diagnoses.first(where: { $0.id == .scanner })
            else {
                Harness.expectTrue(false, "doctor did not report on the scanner")
                return
            }
            guard case .unverifiable(let blocked, let onDisk) = scanner.outcome else {
                Harness.expectTrue(
                    false, "an uncheckable scanner was reported as \(scanner.outcome)")
                return
            }
            Harness.expectEqual(blocked.cause, .notCheckable)
            Harness.expectTrue(onDisk != .missing, "an installed scanner was reported as absent")
            // The bug in one line: this is what sent `install` to exit 1 and
            // the app to the first-run window on every launch.
            Harness.expectTrue(!scanner.needsInstall, "a waiting scanner asked to be downloaded")
        }

        // Choosing between the first-run and main windows must not run
        // `doctor`: the scanner's `verify()` analyses a real fixture and needs
        // a running server to answer what listing a directory answers.

        // Asserted as "survey launches NO child process": the stub scanner
        // records every launch to a probe file, so if survey runs it the file
        // appears.
        Harness.test("the cheap survey answers without running anything") {
            DiagnosisStub.clear()
            DiagnosisStub.stage()
            // ⚠ The server state is STAGED, or the scanner has no analysis
            // target, `verify()` throws before launching anything, and the
            // assertion below is true whatever `survey` does.
            DiagnosisStub.stageServerState()

            let report = Oilbird.survey()
            Harness.expectEqual(report.count, 4, "survey did not report on every dependency")
            Harness.expectTrue(
                !DiagnosisStub.scannerWasLaunched,
                "survey ran the scanner to answer a question detect() answers")
            guard let scanner = report.first(where: { $0.id == .scanner }) else {
                Harness.expectTrue(false, "survey did not report on the scanner")
                return
            }
            Harness.expectTrue(!scanner.needsInstall, "an installed scanner was asked for again")
        }

        // The other half of the pair: with the same state staged the EXPENSIVE
        // question really does launch the scanner, or "survey launched
        // nothing" is satisfied by a machine that can launch nothing.
        Harness.test("the expensive question really is the expensive one") {
            DiagnosisStub.clear()
            DiagnosisStub.stage()
            DiagnosisStub.stageServerState()
            _ = runSync { await Oilbird.doctor() }
            Harness.expectTrue(
                DiagnosisStub.scannerWasLaunched,
                "doctor did not run the scanner, so this suite proves nothing")
        }

        // The counterpart, so the claim above cannot be satisfied by a survey
        // that reports nothing: an absent scanner must still be asked for.
        Harness.test("the cheap survey still notices what is absent") {
            DiagnosisStub.clear()
            let report = Oilbird.survey()
            Harness.expectTrue(
                report.contains { $0.id == .scanner && $0.needsInstall },
                "survey missed an absent scanner")
        }

        // Made to fail on purpose (E5): with nothing on disk the same path must
        // still ask for the download. A `needsInstall` that answered false
        // everywhere would pass the test above and never install anything.
        Harness.test("an absent scanner still asks to be installed") {
            DiagnosisStub.clear()
            let report = runSync { await Oilbird.doctor() }
            guard case .success(let diagnoses) = report,
                let scanner = diagnoses.first(where: { $0.id == .scanner })
            else {
                Harness.expectTrue(false, "doctor did not report on the scanner")
                return
            }
            Harness.expectTrue(scanner.needsInstall, "an absent scanner was not asked for")
        }
    }
}

/// A scanner and a runtime on disk, and deliberately no server — the state in
/// which the check cannot be performed. It refuses to stage over a real
/// install, for the reason `ScannerTests` gives.
private enum DiagnosisStub {
    static var scannerRoot: URL { Paths.install(.scanner) }
    static var runtimeRoot: URL { Paths.Cache.jdk }
    /// Only the engine directory, never the whole SonarQube install: other
    /// suites create that legitimately and clearing it would break them.
    static var engineRoot: URL { Paths.Cache.sonarqube.appending(path: "lib/scanner") }

    static var canStage: Bool {
        !FileManager.default.fileExists(atPath: scannerRoot.path)
            && !FileManager.default.fileExists(atPath: runtimeRoot.path)
    }

    /// Records every launch, so a test can assert that nothing ran.
    static var probe: URL { Paths.cache.appending(path: "diagnosis-stub-probe.txt") }
    static var scannerWasLaunched: Bool {
        FileManager.default.fileExists(atPath: probe.path)
    }

    /// A running server and a token, so `Oilbird.analysisTarget()` is not nil
    /// and the scanner's `verify()` reaches the point of launching a child.
    /// Both are read from the sandboxed container, never the real one.
    static func stageServerState() {
        try? FileManager.default.createDirectory(
            at: Paths.State.run, withIntermediateDirectories: true)
        try? Data(#"{"webPort":1,"databasePort":2}"#.utf8)
            .write(to: Paths.State.run.appending(path: "running.json"))
        try? Secrets.save(
            Secrets.Stored(
                databasePassword: "stub-not-a-real-secret-db",
                adminPassword: "stub-not-a-real-secret-admin",
                analysisToken: "stub-not-a-real-token"))
    }

    static func clearServerState() {
        try? FileManager.default.removeItem(at: Paths.State.run.appending(path: "running.json"))
        try? FileManager.default.removeItem(at: Paths.State.credentials)
    }

    /// An installed scanner as Oilbird now defines one: the CLI jar, the
    /// engine inside SonarQube, and a JDK. The JDK is the recorder, because
    /// it is the process actually launched — `bin/sonar-scanner` is no longer
    /// run at all.
    static func stage() {
        write("not a real jar\n", to: pinnedScannerJar())
        write(
            "not a real jar\n",
            to: engineRoot.appending(path: "sonar-scanner-engine-community-13.7.jar"))
        write(
            "#!/bin/sh\necho launched > \"\(probe.path)\"\nexit 0\n",
            to: runtimeRoot.appending(path: "Contents/Home/bin/java"))
    }

    static func clear() {
        for url in [scannerRoot, runtimeRoot, probe, engineRoot] {
            try? FileManager.default.removeItem(at: url)
        }
        clearServerState()
    }

    private static func write(_ contents: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
