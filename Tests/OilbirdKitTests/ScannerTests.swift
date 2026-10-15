import Foundation
import OilbirdCore
import OilbirdModel

func scannerTests() {
    Harness.suite("Scanner — installed is not the same as verified") {
        Harness.test("the dependency answers for the scanner and installs under the cache") {
            let scanner = ScannerDependency()
            Harness.expectEqual(scanner.id, .scanner)
            // Under <cache>, never <state>: a dependency written to state would
            // make "reclaim disk space" destructive.
            Harness.expectTrue(
                Paths.install(.scanner).path.hasPrefix(Paths.cache.path),
                "the scanner would install outside the cache root")
        }

        // No PATH assumptions: detect asks the resolver, so it cannot drift
        // from the path the launcher will use, and never sees the user's PATH.
        Harness.test("detect follows the resolver rather than a path of its own") {
            let installed = Resolver.executable(.scanner) != nil
            let health = ScannerDependency().detect()
            if installed {
                Harness.expectTrue(health != .missing, "an installed scanner reported missing")
            } else {
                Harness.expectEqual(health, .missing, "an absent scanner did not report missing")
            }
        }

        // The whole point of this suite. Whatever this machine happens to
        // have installed, verify() must not answer "present" when it has not
        // run a scan — and if it cannot run one it must say so with an action.
        Harness.test("verify never reports present without having scanned anything") {
            let result = runSync { try await ScannerDependency().verify() }
            switch result {
            case .success(let health):
                if case .present = health {
                    Harness.expectTrue(false, "verify reported present with no analysis target")
                } else {
                    Harness.expectTrue(true, "verify refused to report present")
                }
            case .failure(let error):
                guard let oilbird = error as? OilbirdError else {
                    Harness.expectTrue(false, "verify threw something that was not an OilbirdError")
                    return
                }
                Harness.expectNotEmpty(oilbird.detail, "the failure had nothing to show a person")
                Harness.expectNotEmpty(oilbird.recovery.actionLabel, "the failure had no action")
            }
        }

        Harness.test("verify on an absent install is missing, and does not throw") {
            guard Resolver.executable(.scanner) == nil else {
                // Installed here, so the claim above does not apply. Assert the
                // one that does rather than skipping and printing a tick.
                Harness.expectTrue(
                    ScannerDependency().detect() != .missing,
                    "an installed scanner reported missing")
                return
            }
            let result = runSync { try await ScannerDependency().verify() }
            guard case .success(let health) = result else {
                Harness.expectTrue(false, "verify threw for an install that is merely absent")
                return
            }
            Harness.expectEqual(health, .missing)
        }

        // No dead ends, over the states that exist precisely because they have
        // no health to report. A dead end here would be invisible, because
        // nothing else reports on them.
        Harness.test("every unverifiable precondition offers an action, never a dead end") {
            Harness.expectTrue(
                !ScannerDependency.Unverifiable.allCases.isEmpty, "no preconditions are named")
            for precondition in ScannerDependency.Unverifiable.allCases {
                let error = precondition.error
                Harness.expectNotEmpty(error.detail, "\(precondition) has nothing to show a person")
                Harness.expectNotEmpty(error.recovery.actionLabel, "\(precondition) has no action")
                Harness.expectNotEmpty(error.underlying ?? "", "\(precondition) has nothing to log")
            }
        }

        // Reinstalling the scanner cannot conjure a JDK, so an answer that
        // sends the user round that loop is worse than no answer.
        Harness.test("a missing runtime asks for the runtime, not for the scanner again") {
            let recovery = ScannerDependency.Unverifiable.noRuntime.error.recovery
            Harness.expectTrue(recovery == .reinstall(.jdk), "a missing JDK did not ask for the JDK")
            Harness.expectTrue(
                recovery != .reinstall(.scanner), "a missing JDK asked for the scanner again")
        }

        // verify is a KIND, never a command. `sonar-scanner --version` would
        // pass on an install that cannot analyse a line of code — the same
        // mistake the bundled JRE was pronounced usable by.
        Harness.test("the scanner verifies by scanning a fixture, not by a version flag") {
            guard let entry = try? Manifest.bundled().entry(.scanner) else {
                Harness.expectTrue(false, "the bundled manifest has no scanner entry")
                return
            }
            Harness.expectEqual(entry.verify, .scanFixture)
        }

        Harness.test("the scanner is a checksummed zip fetched from its own origin") {
            guard let entry = try? Manifest.bundled().entry(.scanner) else {
                Harness.expectTrue(false, "the bundled manifest has no scanner entry")
                return
            }
            Harness.expectEqual(entry.archive, .zip)
            // Nothing is admitted without a size and a digest to admit it by.
            Harness.expectTrue(entry.bytes > 0, "the scanner has no expected size")
            Harness.expectEqual(entry.sha256.count, 64, "the scanner digest is not a SHA-256")
            Harness.expectTrue(entry.url.hasPrefix("https://"), "the scanner origin is not HTTPS")
            // Fetched at run time, never vendored into the repo.
            Harness.expectNotEmpty(entry.licence, "the scanner has no recorded licence")
        }
    }

    // On a machine with no scanner installed the branches above reach only the
    // absent-install path. Without a stub the dependency's actual logic would
    // be covered by "it compiles".
    Harness.suite("Scanner — the checks that need something on disk") {
        guard Stub.canStage else {
            Harness.test("a real install is present, so the stub suite stands aside") {
                // Not a skip: assert the thing that is still true and testable.
                Harness.expectTrue(
                    ScannerDependency().detect() != .missing,
                    "a real install was detected as missing")
            }
            return
        }
        defer { Stub.clear() }

        Harness.test("an install with no runtime refuses to guess, and names the JDK") {
            Stub.clear()
            Stub.stageScanner(exiting: 0)
            let result = runSync { try await ScannerDependency().verify() }
            guard case .failure(let error) = result, let oilbird = error as? OilbirdError else {
                Harness.expectTrue(false, "an installed scanner with no JDK did not refuse")
                return
            }
            Harness.expectTrue(
                oilbird.recovery == .reinstall(.jdk), "the refusal did not ask for the JDK")
            Harness.expectNotEmpty(oilbird.detail)
        }

        // The JRE mistake, in the shape it would take here: everything is on
        // disk, nothing has been run, and the tempting answer is "present".
        Harness.test("a runtime on disk is still not a scan, so it is still not present") {
            Stub.clear()
            Stub.stageScanner(exiting: 0)
            Stub.stageRuntime()
            let result = runSync { try await ScannerDependency().verify() }
            guard case .failure(let error) = result, let oilbird = error as? OilbirdError else {
                Harness.expectTrue(false, "a scanner that had scanned nothing was not refused")
                return
            }
            Harness.expectNotEmpty(oilbird.recovery.actionLabel, "the refusal offered no action")
            Harness.expectNotEmpty(oilbird.detail)
        }

        Harness.test("a scanner that cannot finish a scan is corrupt, and says why") {
            Stub.clear()
            Stub.stageScanner(exiting: 3)
            Stub.stageRuntime()
            let result = runSync { try await ScannerDependency(reportingTo: Stub.target).verify() }
            guard case .success(let health) = result, case .corrupt(let reason) = health else {
                Harness.expectTrue(false, "a failing scan did not report corrupt")
                return
            }
            Harness.expectNotEmpty(reason, "corrupt was reported with no reason")
        }

        Harness.test("a scan that finishes is what makes the scanner present") {
            Stub.clear()
            Stub.stageScanner(exiting: 0)
            Stub.stageRuntime()
            let result = runSync { try await ScannerDependency(reportingTo: Stub.target).verify() }
            guard case .success(let health) = result, case .present(let version) = health else {
                Harness.expectTrue(false, "a completed scan did not report present")
                return
            }
            Harness.expectNotEmpty(version, "present was reported with no version")
        }

        // Secrets never enter argv: the scanner echoes its arguments on
        // failure, so a token there reaches `ps` and every captured stderr. By
        // environment instead, which makes `Log.subprocess` safe verbatim.
        Harness.test("the token reaches the scanner by environment and never by argument") {
            Stub.clear()
            Stub.stageScanner(exiting: 0)
            Stub.stageRuntime()
            _ = runSync { try await ScannerDependency(reportingTo: Stub.target).verify() }
            // Read the two lines apart. Asserting over the whole probe lets a
            // token sitting in argv satisfy the environment claim — which it
            // did, until this test was broken on purpose and did not go red.
            Harness.expectEqual(
                Stub.probeLine("token="), "token=\(Stub.token)",
                "the token did not reach the child's environment")
            let argv = Stub.probeLine("argv=")
            Harness.expectNotEmpty(argv, "the scanner was launched with no arguments at all")
            Harness.expectTrue(!argv.contains(Stub.token), "the token was passed as an argument")
        }

        // ⚠ `JAVA_HOME` is NOT the mechanism: the scanner asks the server for a
        // JRE first, so asserting it passes on a machine downloading a second
        // runtime. `sonar.scanner.javaExePath` short-circuits that.
        Harness.test("the child is pinned to our JDK before it can fetch one") {
            Stub.clear()
            Stub.stageScanner(exiting: 0)
            Stub.stageRuntime()
            _ = runSync { try await ScannerDependency(reportingTo: Stub.target).verify() }
            let argv = Stub.probeLine("argv=")
            Harness.expectTrue(
                argv.contains(
                    "-Dsonar.scanner.javaExePath=\(Paths.Cache.jdk.path)/Contents/Home/bin/java"),
                "nothing pinned the runtime before provisioning could happen")
            Harness.expectTrue(
                argv.contains("-Dsonar.scanner.skipJreProvisioning=true"),
                "the JRE download was not also refused outright")
        }

        // ⚠ With `sonar.sources=.` alone a repository holding
        // `node_modules` runs twenty minutes without passing
        // `Preprocessed 0 files`, and test code is judged as production.
        Harness.test("the scanner is told what is not source and what is test") {
            Stub.clear()
            Stub.stageScanner(exiting: 0)
            Stub.stageRuntime()
            _ = runSync { try await ScannerDependency(reportingTo: Stub.target).verify() }
            let argv = Stub.probeLine("argv=")
            Harness.expectTrue(
                argv.contains("-Dsonar.exclusions="),
                "the scanner was given no exclusions, so it walks node_modules")
            Harness.expectTrue(
                argv.contains("-Dsonar.test.inclusions="),
                "nothing distinguishes test code from production code")
        }

        // ⚠ What the flags CARRY lives in preferences, because a constant
        // nobody can remove is not a default. `SettingsTests` asserts that
        // deleting from it is obeyed.
        Harness.test("the suggested scope still covers what made a scan fail") {
            let sent = ScannerCommand.patterns(ScannerCommand.defaultNeverSource)
            for never in ["node_modules", "vendor", "target", "__pycache__"] {
                Harness.expectTrue(sent.contains(never), "\(never) left the suggestion")
            }
            // Patterns, not directories: a `.spec.ts` beside its source is
            // the layout that produced the observed failure.
            Harness.expectTrue(
                ScannerCommand.patterns(ScannerCommand.defaultTestPatterns)
                    .contains("*.spec.*"),
                "co-located tests would be scored as production")
        }

        // The three other ways out of the container, asserted together
        // because they are one property: nothing the scanner writes or
        // fetches may land outside Oilbird's own directories.
        Harness.test("the scanner is given nowhere outside the container to write") {
            Stub.clear()
            Stub.stageScanner(exiting: 0)
            Stub.stageRuntime()
            _ = runSync { try await ScannerDependency(reportingTo: Stub.target).verify() }
            let argv = Stub.probeLine("argv=")
            Harness.expectTrue(
                argv.contains("-Dsonar.userHome=\(Paths.Cache.scannerHome.path)"),
                "the plugin cache was left pointing at ~/.sonar")
            Harness.expectTrue(
                argv.contains("-Dsonar.working.directory=\(Paths.Cache.scannerWork.path)"),
                "the working directory was left inside the analysed project")
            Harness.expectTrue(
                argv.contains("-Dsonar.scanner.engineJarPath=\(Paths.Cache.sonarqube.path)"),
                "the engine was not taken from the SonarQube already on disk")
        }

        // Three places name this project and they are one constant: inline the
        // string in any of them and the self-check leaves a project on the
        // user's dashboard every run, with nothing else noticing.
        Harness.test("the fixture is scanned under the key that cleans it up") {
            Stub.clear()
            Stub.stageScanner(exiting: 0)
            Stub.stageRuntime()
            _ = runSync { try await ScannerDependency(reportingTo: Stub.target).verify() }
            let argv = Stub.probeLine("argv=")
            Harness.expectNotEmpty(argv, "the scanner was launched with no arguments")
            Harness.expectTrue(
                argv.contains("-Dsonar.projectKey=\(ScannerDependency.fixtureProjectKey)"),
                "the fixture is scanned under a key nothing cleans up")
        }

        Harness.test("the fixture is built for the scan and does not outlive it") {
            Stub.clear()
            Stub.stageScanner(exiting: 0)
            Stub.stageRuntime()
            _ = runSync { try await ScannerDependency(reportingTo: Stub.target).verify() }
            let probe = Stub.probeContents()
            Harness.expectTrue(
                probe.contains("sources=1"), "the scanner was pointed at an empty fixture")
            Harness.expectTrue(
                !FileManager.default.fileExists(atPath: Stub.fixture.path),
                "the fixture survived the check")
        }
    }
}

/// A stub install, so the branches that need one can run with no network, no
/// JDK and no server.
///
/// It refuses to stage over a real install. Deleting someone's 11 MiB download
/// — or their 191 MiB JDK — to exercise a shell script would be a poor trade,
/// and the suite asserts a weaker claim instead when that is the situation.
/// Internal rather than private: the Versions pane's fallback needs a
/// staged install to prove it reads one, and staging one correctly is
/// this type's whole job. A second copy would be a second thing to keep
/// true.
enum Stub {
    static let token = "stub-token-not-a-real-secret"

    static var scannerRoot: URL { Paths.install(.scanner) }
    static var runtimeRoot: URL { Paths.Cache.jdk }
    /// Only the engine directory, never the whole SonarQube install: other
    /// suites create that legitimately and clearing it would break them.
    static var engineRoot: URL { Paths.Cache.sonarqube.appending(path: "lib/scanner") }
    static var fixture: URL { Paths.install(.scanner).appendingPathExtension("fixture") }
    static var probe: URL { Paths.cache.appending(path: "scanner-stub-probe.txt") }

    static var canStage: Bool {
        !FileManager.default.fileExists(atPath: scannerRoot.path)
            && !FileManager.default.fileExists(atPath: runtimeRoot.path)
        // The engine is staged under the SonarQube install now, so a real
        // one must not be stood on either.
    }

    static var target: ScannerDependency.AnalysisTarget {
        ScannerDependency.AnalysisTarget(host: Loopback.url(port: 9999), token: token)
    }

    /// The scanner install: the CLI jar, and the engine that lives inside
    /// SonarQube.
    ///
    /// ⚠ Contents are irrelevant and existence is not. Oilbird no longer runs
    /// `bin/sonar-scanner` — it runs our own JDK with the CLI jar on the
    /// classpath, so the jar is what `detect()` looks for and what
    /// `ScannerCommand` puts in the argv. The engine is staged too because
    /// `launch` refuses without it, which is the point: an install missing
    /// the engine would otherwise silently start downloading one.
    ///
    /// `exiting:` is honoured by the runtime stub, since the runtime is now
    /// the process that actually runs.
    static func stageScanner(exiting status: Int32) {
        write("not a real jar\n", to: pinnedScannerJar())
        write(
            "not a real jar\n",
            to: engineRoot.appending(path: "sonar-scanner-engine-community-13.7.jar"))
        exitStatus = status
    }

    nonisolated(unsafe) static var exitStatus: Int32 = 0

    /// The JDK — and now the thing that is really launched, so this is what
    /// records the invocation.
    static func stageRuntime() {
        let script = """
            #!/bin/sh
            {
              echo "token=${SONAR_TOKEN:-unset}"
              echo "argv=$*"
              echo "sources=$(ls -1 | wc -l | tr -d ' ')"
            } > "\(probe.path)"
            exit \(exitStatus)
            """
        write(script, to: runtimeRoot.appending(path: "Contents/Home/bin/java"))
    }

    static func probeContents() -> String {
        (try? String(contentsOf: probe, encoding: .utf8)) ?? ""
    }

    /// One recorded line, so a claim about the environment cannot be satisfied
    /// by something that is actually sitting in the argument list.
    static func probeLine(_ prefix: String) -> String {
        probeContents()
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix(prefix) } ?? ""
    }

    static func clear() {
        for url in [scannerRoot, runtimeRoot, fixture, probe, engineRoot] {
            try? FileManager.default.removeItem(at: url)
        }
        exitStatus = 0
    }

    private static func write(_ contents: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
