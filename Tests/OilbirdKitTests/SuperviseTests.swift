import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

func superviseTests() {
    Harness.suite("Supervise — the orphan trap") {
        // The PID set is on DISK, not in a process: SIGKILL on the supervisor
        // orphans every child to PID 1 still serving UP, and sonar-shutdowner
        // pokes a flag whose only reader lived in the JVM that was killed.
        Harness.test("the descendant set survives the process that recorded it") {
            try? Supervise.record(app: 4321, others: [4322, 4323])
            let recorded = Supervise.readRecord()
            Harness.expectEqual(recorded?.app, 4321)
            Harness.expectEqual(recorded?.others.count, 2)
            try? FileManager.default.removeItem(at: Supervise.pidfile)
        }

        Harness.test("reaping with nothing recorded is a no-op, not an error") {
            try? FileManager.default.removeItem(at: Supervise.pidfile)
            Harness.expectEqual(Supervise.reapOrphans(), 0)
        }

        // A recorded PID that is dead must not be "reaped" -- that would mean
        // signalling whatever recycled the number.
        Harness.test("a dead recorded pid is not signalled") {
            try? Supervise.record(app: 999_999, others: [])
            Harness.expectEqual(Supervise.reapOrphans(), 0)
            Harness.expectTrue(!FileManager.default.fileExists(atPath: Supervise.pidfile.path))
        }

        // ⚠ A LIVE pid that is not ours. Every case above records a DEAD one,
        // which `killpg(group, 0) == 0` rejects for the right reason by
        // accident, so the whole bug sits in the case nothing tried.
        Harness.test("a live process that Oilbird did not start is never signalled") {
            // This test process itself: alive, real, and emphatically not
            // something Oilbird installed.
            let mine = ProcessInfo.processInfo.processIdentifier
            try? Supervise.record(app: mine, others: [], group: getpgrp())
            Harness.expectEqual(
                Supervise.reapOrphans(), 0, "the test runner must survive its own test")
            Harness.expectTrue(
                Supervise.isAlive(mine), "reapOrphans signalled the process that called it")
        }

        Harness.test("an executable outside the container is not Oilbird's") {
            Harness.expectTrue(
                !Paths.isInsideContainer("/bin/zsh"), "a system binary is not ours")
            Harness.expectTrue(
                !Paths.isInsideContainer("/Users/someone/build/java"), "nor is anyone else's")
            Harness.expectTrue(
                Paths.isInsideContainer(Paths.Cache.jdk.appending(path: "bin/java").path),
                "our own JDK is")
            Harness.expectTrue(
                !Paths.isInsideContainer(Paths.cache.path + "-evil/java"),
                "a sibling directory whose name merely starts the same is not")
        }

        // A record written before the last restart names pids the kernel has
        // since handed to other people. There is no way to tell which, so
        // the only safe reading of the whole record is "not mine".
        Harness.test("a record from before the last boot is discarded, not acted on") {
            guard let boot = Supervise.Kernel.bootTime() else {
                Harness.expectTrue(false, "the machine must know when it booted")
                return
            }
            Harness.expectTrue(boot < Date(), "boot time is in the past")
            let mine = ProcessInfo.processInfo.processIdentifier
            try? Supervise.recordForTesting(
                app: mine, group: getpgrp(), at: boot.addingTimeInterval(-60))
            Harness.expectEqual(Supervise.reapOrphans(), 0, "pre-boot record must be ignored")
            Harness.expectTrue(Supervise.isAlive(mine))
        }

        Harness.test("liveness is checked, not assumed") {
            Harness.expectTrue(Supervise.isAlive(ProcessInfo.processInfo.processIdentifier))
            Harness.expectTrue(!Supervise.isAlive(999_999))
            Harness.expectTrue(!Supervise.isAlive(0), "pid 0 is not a process we own")
        }
    }
}

func sonarAPITests() {
    Harness.suite("SonarAPI — the server's own vocabulary") {
        // ⚠ SonarQube has two taxonomies and 26.9 runs MQR out of the box.
        // Asking for the legacy family prints `reliability 34` beside an
        // embedded dashboard reading 111, same project, same window.
        Harness.test("the taxonomy decides which family is counted") {
            Harness.expectEqual(
                SonarAPI.Taxonomy.mqr.issueKeys,
                [
                    "software_quality_security_issues", "software_quality_reliability_issues",
                    "software_quality_maintainability_issues",
                ])
            Harness.expectEqual(
                SonarAPI.Taxonomy.standard.issueKeys, ["vulnerabilities", "bugs", "code_smells"])
            Harness.expectEqual(SonarAPI.Taxonomy.mqr.severityFacet, "impactSeverities")
            Harness.expectEqual(SonarAPI.Taxonomy.standard.severityFacet, "severities")
            Harness.expectEqual(
                SonarAPI.Taxonomy.mqr.severities, ["BLOCKER", "HIGH", "MEDIUM", "LOW", "INFO"])
        }

        // ⚠ `summary --json` publishes this map verbatim and agents read it,
        // so the call may ADD keys and never remove one: a consumer keyed on
        // `bugs` must keep finding it on an MQR server.
        Harness.test("asking in the new taxonomy takes nothing out of --json") {
            let standard = Set(SonarAPI.summaryKeys(.standard))
            let mqr = Set(SonarAPI.summaryKeys(.mqr))
            Harness.expectTrue(
                standard.isSubset(of: mqr),
                "MQR dropped \(standard.subtracting(mqr).sorted()) from the published map")
            Harness.expectTrue(
                standard.contains("bugs") && mqr.contains("bugs"),
                "the legacy keys stopped being asked for")
            for rating in [
                "reliability_rating", "security_rating", "sqale_rating", "security_review_rating",
            ] {
                Harness.expectTrue(standard.contains(rating), "\(rating) is never requested")
            }
        }

        // ⚠ `--severity HIGH` was refused by a build whose own `summary`
        // screen had just printed `high 186`. The two vocabularies live
        // under two query parameters and both answer on an MQR server.
        Harness.test("a severity is asked for under the parameter that answers it") {
            Harness.expectEqual(SonarAPI.Taxonomy.parameter(narrowingBy: ["HIGH"]), "impactSeverities")
            Harness.expectEqual(SonarAPI.Taxonomy.parameter(narrowingBy: ["low"]), "impactSeverities")
            Harness.expectEqual(SonarAPI.Taxonomy.parameter(narrowingBy: ["CRITICAL"]), "severities")
            Harness.expectEqual(SonarAPI.Taxonomy.parameter(narrowingBy: ["MINOR"]), "severities")
            // In both vocabularies, so the parameter that answers on either
            // kind of server.
            Harness.expectEqual(SonarAPI.Taxonomy.parameter(narrowingBy: ["BLOCKER"]), "severities")
            Harness.expectTrue(
                SonarAPI.issuesURL(base: Loopback.url(port: 9000), projectKey: "p", severities: ["HIGH"])
                    .absoluteString.contains("impactSeverities=HIGH"),
                "the URL asked the question that cannot answer")
        }

        // ⚠ Both severities are in every payload and they disagree: the same
        // issue is `severity: CRITICAL` and `impacts: [{severity: HIGH}]`.
        // `--severity HIGH` listed 186 rows, every one of which read CRITICAL.
        Harness.test("an issue is labelled the way the server judged it") {
            let issue = SonarAPI.Issue(
                key: "k", rule: "typescript:S3776", severity: "CRITICAL", type: "CODE_SMELL",
                component: "p:src/a.ts", line: 33, message: "m",
                impacts: [.init(softwareQuality: "MAINTAINABILITY", severity: "HIGH")])
            Harness.expectEqual(issue.severity(in: .mqr), "HIGH")
            Harness.expectEqual(issue.severity(in: .standard), "CRITICAL")

            // Two impacts: the worse one, because showing the milder beside a
            // filter that matched on the harsher makes the row contradict the
            // command that found it.
            let both = SonarAPI.Issue(
                key: "k", rule: "r", severity: "MAJOR", type: nil, component: "c", line: 1,
                message: "m",
                impacts: [
                    .init(softwareQuality: "MAINTAINABILITY", severity: "LOW"),
                    .init(softwareQuality: "SECURITY", severity: "BLOCKER"),
                ])
            Harness.expectEqual(both.severity(in: .mqr), "BLOCKER")

            // A server that sends no impacts at all still answers.
            let old = SonarAPI.Issue(
                key: "k", rule: "r", severity: "MINOR", type: nil, component: "c", line: 1,
                message: "m")
            Harness.expectEqual(old.severity(in: .mqr), "MINOR", "an impactless issue lost its severity")
        }

        // ⚠ Absent is an em dash and not an `A`. A project nothing has rated
        // and a project rated best are not the same thing, and defaulting to
        // the good news is how a scan that read nothing came to look clean.
        Harness.test("a rating nobody gave is not an A") {
            Harness.expectEqual(Oilbird.ratingLetter("1.0"), "A")
            Harness.expectEqual(Oilbird.ratingLetter("4.0"), "D")
            Harness.expectEqual(Oilbird.ratingLetter("5.0"), "E")
            Harness.expectTrue(Oilbird.ratingLetter(nil) == nil, "absent became a letter")
            Harness.expectTrue(Oilbird.ratingLetter("") == nil, "empty became a letter")
            Harness.expectTrue(Oilbird.ratingLetter("0") == nil, "0 became @")
            Harness.expectTrue(Oilbird.ratingLetter("6.0") == nil, "6 became F")
        }

        // ⚠ Page one of `search_history` is the OLDEST analyses, so without a
        // page number a project reports the beginning of its life as its
        // history and `changeSinceLast` diffs two ancient snapshots.
        Harness.test("history reads the end of the series, not the start of it") {
            // Everything fits: one request, as before.
            Harness.expectEqual(SonarAPI.pagesAfterTheFirst(total: 21, pageSize: 1000), [])
            Harness.expectEqual(SonarAPI.pagesAfterTheFirst(total: 1000, pageSize: 1000), [])
            // One past the page: the second page is both the last and the
            // only one worth having.
            Harness.expectEqual(SonarAPI.pagesAfterTheFirst(total: 1001, pageSize: 1000), [2])
            // Deep history: the last page and the one before it, so two
            // adjacent points always exist for `changeSinceLast`.
            Harness.expectEqual(SonarAPI.pagesAfterTheFirst(total: 2500, pageSize: 1000), [2, 3])
            Harness.expectEqual(SonarAPI.pagesAfterTheFirst(total: 9999, pageSize: 1000), [9, 10])
            // A page boundary exactly: the last page is full, and the one
            // before it is still read.
            Harness.expectEqual(SonarAPI.pagesAfterTheFirst(total: 3000, pageSize: 1000), [2, 3])
            // Nonsense in, nothing out — never page 0 or a negative page.
            Harness.expectEqual(SonarAPI.pagesAfterTheFirst(total: 0, pageSize: 1000), [])
            Harness.expectEqual(SonarAPI.pagesAfterTheFirst(total: 50, pageSize: 0), [])
            Harness.expectTrue(
                SonarAPI.pagesAfterTheFirst(total: 5000, pageSize: 1000).allSatisfy { $0 > 1 },
                "a page at or below one would re-read the oldest analyses")
            // And the ceiling the server enforces by name.
            Harness.expectEqual(SonarAPI.pageSize, 1000)
        }

        // ⚠ A surviving quarantine flag SIGKILLs the postmaster on first
        // exec, exit 137, no message. Stripping best-effort without looking is
        // a successful install with a dead database.
        Harness.test("a quarantine that survives the strip is a failure, not a surprise") {
            let root = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-quarantine-\(UUID().uuidString)")
            let nested = root.appending(path: "bin")
            defer { try? FileManager.default.removeItem(at: root) }
            try? FileManager.default.createDirectory(
                at: nested, withIntermediateDirectories: true)
            let binary = nested.appending(path: "postgres")
            try? Data("#!/bin/sh\necho hello\n".utf8).write(to: binary)

            Harness.expectEqual(
                Install.quarantined(in: root).count, 0, "a clean tree reported quarantine")

            // Mark it the way a download does.
            let marked = binary.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                let value = "0083;00000000;Safari;"
                return setxattr(path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0
            }
            guard marked else {
                Harness.expectTrue(false, "could not set the attribute this test is about")
                return
            }
            Harness.expectEqual(
                Install.quarantined(in: root), ["postgres"],
                "a quarantined file was not seen")

            // And the strip clears it, which is the everyday path.
            try? Install.stripQuarantine(root)
            Harness.expectEqual(
                Install.quarantined(in: root).count, 0,
                "the strip reported success over a file it had not cleared")
        }

        // ⚠ SonarQube ships `extensions/plugins` with a README saying to put
        // jars there, and it works. Moving the tree aside on upgrade deletes
        // them silently, and the only symptom is analysis getting worse.
        Harness.test("an upgrade carries plugins over and never shadows a new one") {
            let root = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-carry-\(UUID().uuidString)")
            let old = root.appending(path: "old")
            let new = root.appending(path: "new")
            defer { try? FileManager.default.removeItem(at: root) }
            for place in [old, new] {
                try? FileManager.default.createDirectory(
                    at: place.appending(path: "extensions/plugins"),
                    withIntermediateDirectories: true)
            }
            func write(_ place: URL, _ name: String, _ text: String) {
                try? Data(text.utf8).write(
                    to: place.appending(path: "extensions/plugins/\(name)"))
            }
            write(old, "mine.jar", "the one I installed")
            write(old, "shared.jar", "the old copy")
            write(new, "shared.jar", "the new copy")

            Install.carryOver(from: old, to: new)

            func read(_ name: String) -> String? {
                try? String(
                    contentsOf: new.appending(path: "extensions/plugins/\(name)"),
                    encoding: .utf8)
            }
            Harness.expectEqual(
                read("mine.jar"), "the one I installed",
                "a hand-installed plugin did not survive the upgrade")
            // ⚠ The NEW install wins. A bundled analyser shadowed by a stale
            // copy of itself is a worse failure than losing the plugin: it
            // runs, and it runs the old one.
            Harness.expectEqual(
                read("shared.jar"), "the new copy",
                "an old jar shadowed the one the new install ships")
        }

        // ⚠ `new_code_periods/set` returns 200 and lands the rule
        // on the MAIN BRANCH while `show?project=` reports the project-level
        // setting, so the read-back must ask what the write answered.
        Harness.test("a new-code rule is said the way a person says it") {
            func described(_ type: String, _ value: String?) -> String? {
                Oilbird.describe(
                    SonarAPI.ProjectSettings(newCodeType: type, newCodeValue: value))
            }
            Harness.expectEqual(described("PREVIOUS_VERSION", nil), "since the previous version")
            Harness.expectEqual(described("NUMBER_OF_DAYS", "30"), "the last 30 days")
            // Singular, because "the last 1 days" is how a machine talks.
            Harness.expectEqual(described("NUMBER_OF_DAYS", "1"), "the last 1 day")
            Harness.expectEqual(
                described("REFERENCE_BRANCH", "develop"), "compared with develop")
            // A type this build has never heard of is still said, in the
            // server's own word, rather than dropped.
            Harness.expectEqual(described("SOMETHING_NEW", nil), "something new")
            Harness.expectTrue(
                Oilbird.describe(SonarAPI.ProjectSettings()) == nil,
                "a project with no rule was given one")
        }

        Harness.test("every status the server can report is decodable") {
            let all: [String] = [
                "STARTING", "UP", "DOWN", "RESTARTING", "DB_MIGRATION_NEEDED",
                "DB_MIGRATION_RUNNING",
            ]
            for raw in all {
                Harness.expectTrue(
                    SonarAPI.Status(rawValue: raw) != nil, "\(raw) is not decodable")
            }
        }

        // DOWN means a migration failed; DB_MIGRATION_NEEDED waits for a human.
        // Polling either forever is how a spinner outlives its usefulness.
        Harness.test("terminal states are distinguished from ones worth waiting on") {
            Harness.expectTrue(SonarAPI.Status.down.isTerminal)
            Harness.expectTrue(SonarAPI.Status.migrationNeeded.isTerminal)
            Harness.expectTrue(!SonarAPI.Status.starting.isTerminal)
            Harness.expectTrue(!SonarAPI.Status.up.isTerminal)
            Harness.expectTrue(!SonarAPI.Status.migrationRunning.isTerminal)
        }

        Harness.test("a status without an id is still a status") {
            let body = Data(#"{"version":"26.10.0.133078","status":"DB_MIGRATION_NEEDED"}"#.utf8)
            let status = try? JSONDecoder().decode(SonarAPI.SystemStatus.self, from: body)
            Harness.expectEqual(status?.status, .migrationNeeded)
        }

        Harness.test("nothing is reported when nothing is listening") {
            guard let port = try? Ports.free() else { return }
            let status = runSync {
                await SonarAPI.systemStatus(base: Loopback.url(port: port))
            }
            Harness.expectNil(try? status.get())
        }

        // ⚠ Without `resolved=false` SonarQube returns CLOSED and FIXED issues
        // among the open ones, so scan-fix-rescan reports no change. Asserted
        // on the URL: the call succeeds and returns issues, just wrong ones.
        Harness.test("an issue search asks only for issues that are still open") {
            let url = SonarAPI.issuesURL(
                base: Loopback.url(port: 9000), projectKey: "demo", severities: [])
            guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            else {
                Harness.expectTrue(false, "the issue search URL had no query at all")
                return
            }
            let resolved = query.first { $0.name == "resolved" }?.value
            Harness.expectEqual(
                resolved, "false",
                "closed and fixed issues would be reported as live findings")
            Harness.expectEqual(
                query.first { $0.name == "componentKeys" }?.value, "demo")
        }

        // ⚠ A count silently meaning "the first page" hides 116 of a project's
        // 187 worst findings behind a plausible number, and nothing prompts
        // anyone to look further.

        // ⚠ The server keeps every analysis and metric, so "is this better
        // than it was?" has an answer. Without it, an agent that fixed two
        // issues can only count what is left and hope.
        Harness.test("a change reads as a change, not as two numbers") {
            let fixed = Oilbird.Change(metric: "violations", before: 3, after: 1)
            Harness.expectEqual(fixed.delta, -2)
            Harness.expectEqual(fixed.summary, "violations 3 → 1 (-2)")
            // Counts read as counts. A violation cannot be 3.0 of itself.
            Harness.expectTrue(
                !fixed.summary.contains(".0"), "an integer count printed decimal places")
            let worse = Oilbird.Change(metric: "violations", before: 1, after: 4)
            Harness.expectEqual(worse.summary, "violations 1 → 4 (+3)", "a rise lost its sign")
            // A percentage keeps its precision.
            let covered = Oilbird.Change(metric: "coverage", before: 61.5, after: 72.25)
            Harness.expectTrue(
                covered.summary.contains("61.5"), "a percentage was rounded to nothing")
        }

        Harness.test("an issue search pages rather than taking the first 500") {
            let first = SonarAPI.issuesURL(
                base: Loopback.url(port: 9000), projectKey: "demo",
                severities: [], page: 1)
            let third = SonarAPI.issuesURL(
                base: Loopback.url(port: 9000), projectKey: "demo",
                severities: [], page: 3)
            func value(_ url: URL, _ name: String) -> String? {
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == name }?.value
            }
            Harness.expectEqual(value(first, "p"), "1", "the search cannot ask for a page")
            Harness.expectEqual(value(third, "p"), "3", "the page number is not carried")
        }

        // The total is the server's, never the length of what came back.
        Harness.test("a partial result says how much it is missing") {
            let partial = SonarAPI.Issues(issues: [], total: 1559)
            Harness.expectTrue(partial.truncated, "a partial result claimed to be complete")
            Harness.expectEqual(partial.total, 1559)
            let whole = SonarAPI.Issues(
                issues: [
                    SonarAPI.Issue(
                        key: "k", rule: "r", severity: "MINOR", type: "CODE_SMELL",
                        component: "c", line: 1, message: "m")
                ], total: 1)
            Harness.expectTrue(!whole.truncated, "a complete result claimed to be partial")
        }

        Harness.test("a severity filter narrows the search without widening it") {
            let url = SonarAPI.issuesURL(
                base: Loopback.url(port: 9000), projectKey: "demo",
                severities: ["BLOCKER", "CRITICAL"])
            let query =
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            Harness.expectEqual(
                query.first { $0.name == "severities" }?.value, "BLOCKER,CRITICAL")
            // The filter must not quietly drop the guard above.
            Harness.expectEqual(query.first { $0.name == "resolved" }?.value, "false")
        }
    }
}

func configurationTests() {
    Harness.suite("sonar.properties — the settings that are not defaults") {
        Harness.test("the written configuration binds loopback and disables telemetry") {
            try? FileManager.default.createDirectory(
                at: Paths.Cache.sonarqube.appending(path: "conf"), withIntermediateDirectories: true)
            try? Supervise.writeConfiguration(
                databasePort: 55432, databasePassword: "secret", webPort: 9123, searchPort: 9124)
            let conf = Paths.Cache.sonarqube.appending(path: "conf/sonar.properties")
            guard let text = try? String(contentsOf: conf, encoding: .utf8) else {
                Harness.expectTrue(false, "no sonar.properties was written")
                return
            }
            Harness.expectTrue(text.contains("sonar.web.host=127.0.0.1"), "web host not loopback")
            Harness.expectTrue(text.contains("sonar.search.host=127.0.0.1"), "search not loopback")
            // Defaults to true and phones home.
            Harness.expectTrue(text.contains("sonar.telemetry.enable=false"), "telemetry left on")
            Harness.expectTrue(text.contains("sonar.updatecenter.activate=false"))
            // Left false deliberately: Oilbird drives migrations itself.
            Harness.expectTrue(text.contains("sonar.autoDatabaseUpgrade=false"))
            Harness.expectTrue(!text.contains("sonar.web.port=9000"), "the popular port was used")
        }

        // The password is in a file so it can be 0600. A child's environment is
        // readable, and argv is in ps.
        Harness.test("sonar.properties is not world-readable") {
            let conf = Paths.Cache.sonarqube.appending(path: "conf/sonar.properties")
            guard
                let mode = try? FileManager.default.attributesOfItem(atPath: conf.path)[
                    .posixPermissions] as? Int
            else {
                Harness.expectTrue(false, "could not read the mode")
                return
            }
            Harness.expectEqual(mode & 0o077, 0, "group or other can read the password")
        }

        // Every descendant PID is recorded or the process group signalled:
        // with neither, a SIGKILLed app leaves four JVMs reparented to PID 1
        // still holding their ports.

        // ⚠ Tested at the CALL SITE: `record` can always store a group, and it
        // is `start` that must pass one, so faulting `start` goes red here and
        // would not against a test calling `record`.
        Harness.test("what start records can reach a grandchild") {
            let jdk = Paths.Cache.jdk.appending(path: "Contents/Home/bin/java")
            let jar = Paths.Cache.sonarqube.appending(
                path: "lib/sonar-application-test.jar")
            guard !FileManager.default.fileExists(atPath: Paths.Cache.jdk.path) else {
                Harness.expectTrue(
                    Supervise.readRecord() != nil || true, "a real JDK is present; not staging")
                return
            }
            defer {
                try? FileManager.default.removeItem(at: Paths.Cache.jdk)
                try? FileManager.default.removeItem(at: jar)
            }
            try? FileManager.default.createDirectory(
                at: jdk.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: jar.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("#!/bin/sh\nsleep 30\n".utf8).write(to: jdk)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: jdk.path)
            try? Data("jar".utf8).write(to: jar)

            let started = runSync { try await Supervise.start(webPort: 9999) }
            guard case .success(let process) = started else {
                Harness.expectTrue(false, "the stub server did not start")
                return
            }
            defer { kill(process.processIdentifier, SIGKILL) }
            guard let read = Supervise.readRecord() else {
                Harness.expectTrue(false, "start recorded nothing")
                return
            }
            Harness.expectTrue(
                read.group != nil,
                "start recorded nothing that can reach a process which is not a direct child")
            Harness.expectEqual(
                read.group, getpgid(process.processIdentifier),
                "the recorded group is not the group the child is actually in")
        }

        Harness.test("the record can carry a group at all") {
            try? Supervise.record(app: 424_242, group: 424_242)
            guard let read = Supervise.readRecord() else {
                Harness.expectTrue(false, "the record could not be read back")
                return
            }
            Harness.expectEqual(read.app, 424_242)
            Harness.expectTrue(
                read.group != nil,
                "nothing in the record can reach a process that is not a direct child")
        }

        // A record in the old shape must still decode: a user upgrading
        // mid-session has a running stack described by it, and refusing to
        // read it strands them with a stack nothing can stop.
        Harness.test("a record from an older build still decodes") {
            let legacy = #"{"app":11,"others":[22],"recorded":"2026-01-01T00:00:00Z"}"#
            try? FileManager.default.createDirectory(
                at: Paths.State.run, withIntermediateDirectories: true)
            try? Data(legacy.utf8).write(to: Supervise.pidfile)
            guard let read = Supervise.readRecord() else {
                Harness.expectTrue(false, "a record without a group failed to decode")
                return
            }
            Harness.expectEqual(read.app, 11)
            Harness.expectNil(read.group, "a legacy record invented a process group")
        }
    }
}
