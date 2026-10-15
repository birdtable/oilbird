import Foundation
import OilbirdCore
import OilbirdModel

private func fixture(_ files: [String]) -> URL {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "oilbird-project-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for file in files { try? Data("x".utf8).write(to: root.appending(path: file)) }
    return root
}

func projectTests() {
    Harness.suite("Project — what is this, and what should analyse it") {
        Harness.test("each marker file picks its toolchain") {
            let cases: [(String, Project.Toolchain)] = [
                ("pom.xml", .maven), ("build.gradle", .gradle), ("package.json", .node),
                ("pyproject.toml", .python), ("go.mod", .go),
            ]
            for (marker, expected) in cases {
                let root = fixture([marker])
                defer { try? FileManager.default.removeItem(at: root) }
                Harness.expectEqual(Project.infer(at: root).toolchain, expected, "for \(marker)")
            }
        }

        Harness.test("a directory with no marker is still scannable") {
            let root = fixture(["README.md"])
            defer { try? FileManager.default.removeItem(at: root) }
            Harness.expectEqual(Project.infer(at: root).toolchain, .other)
        }

        Harness.test("Maven wins over Node when both are present") {
            let root = fixture(["pom.xml", "package.json"])
            defer { try? FileManager.default.removeItem(at: root) }
            Harness.expectEqual(Project.infer(at: root).toolchain, .maven)
        }

        // Two checkouts of one repository are two projects. Sharing a key means
        // silently overwriting each other's history, which is the one thing a
        // server is kept for.
        Harness.test("two checkouts of the same name get different keys") {
            let one = fixture([]), two = fixture([])
            defer {
                try? FileManager.default.removeItem(at: one)
                try? FileManager.default.removeItem(at: two)
            }
            Harness.expectTrue(
                Project.key(for: one) != Project.key(for: two), "keys collided across checkouts")
        }

        Harness.test("a key is stable for the same path") {
            let root = fixture([])
            defer { try? FileManager.default.removeItem(at: root) }
            Harness.expectEqual(Project.key(for: root), Project.key(for: root))
        }

        Harness.test("a project's own properties file is noticed") {
            let root = fixture(["sonar-project.properties"])
            defer { try? FileManager.default.removeItem(at: root) }
            Harness.expectTrue(Project.infer(at: root).hasOwnProperties)
        }

        Harness.test("each scriptable toolchain names its coverage report") {
            for marker in ["package.json", "pyproject.toml", "go.mod"] {
                let root = fixture([marker])
                defer { try? FileManager.default.removeItem(at: root) }
                Harness.expectNotEmpty(
                    Project.infer(at: root).coverageProperty ?? "", "for \(marker)")
            }
        }
    }
}

func scanDegradationTests() {
    Harness.suite("Scan — a degraded scan says so") {
        // Presenting a coverage-less scan as a normal one would make Oilbird
        // lie about code quality, which is the one thing it must not do.
        Harness.test("a JVM project is reported as degraded, with a reason") {
            for marker in ["pom.xml", "build.gradle"] {
                let root = fixture([marker])
                defer { try? FileManager.default.removeItem(at: root) }
                let reason = Scan.degradation(for: Project.infer(at: root))
                Harness.expectNotEmpty(reason ?? "", "no reason given for \(marker)")
                Harness.expectTrue(
                    reason?.contains("coverage") == true, "the reason does not say what is lost")
            }
        }

        Harness.test("a scriptable project is not degraded") {
            for marker in ["package.json", "go.mod", "pyproject.toml"] {
                let root = fixture([marker])
                defer { try? FileManager.default.removeItem(at: root) }
                Harness.expectNil(
                    Scan.degradation(for: Project.infer(at: root)), "\(marker) reported degraded")
            }
        }

        // The scanner's receipt names the analysis and where to read it: the
        // task id closes the compute-engine race, and the URL cannot be built
        // ahead of time because the port is assigned at start.
        Harness.test("the scanner's receipt is read, not ignored") {
            let directory = Paths.Cache.scratch.appending(path: "receipt-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let receipt = """
                projectKey=demo
                serverUrl=http://127.0.0.1:9000
                dashboardUrl=http://127.0.0.1:9000/dashboard?id=demo
                ceTaskId=70276023-4cbe-4f46-8203-464f016d09d0
                """
            try? Data(receipt.utf8).write(to: directory.appending(path: "report-task.txt"))

            let read = Scan.report(in: directory)
            Harness.expectEqual(read["ceTaskId"], "70276023-4cbe-4f46-8203-464f016d09d0")
            Harness.expectEqual(read["dashboardUrl"], "http://127.0.0.1:9000/dashboard?id=demo")
            // A value containing '=' must survive: a dashboard URL always
            // has one, and splitting on every '=' would truncate it to
            // ".../dashboard?id".
            Harness.expectTrue(
                read["dashboardUrl"]?.contains("?id=demo") == true,
                "the URL was cut at its first '='")
        }

        // Absent is not a failure. The scan itself succeeded; the only cost
        // is that the caller waits no longer and gets no link.
        Harness.test("a missing receipt is survivable") {
            let empty = Paths.Cache.scratch.appending(path: "no-receipt-\(UUID().uuidString)")
            Harness.expectTrue(
                Scan.report(in: empty).isEmpty, "a missing receipt produced something")
        }
    }
}

func scanVersionTests() {
    Harness.suite("Scan — every analysis is its own version") {
        // Without a distinct version per analysis, `PREVIOUS_VERSION` has no
        // baseline to find and SonarQube dates new code from the project's
        // creation — so "new code" is the whole codebase, for ever.
        Harness.test("two analyses a second apart are two versions") {
            let first = Date(timeIntervalSince1970: 1_757_500_000)
            Harness.expectTrue(
                Scan.versionStamp(first) != Scan.versionStamp(first.addingTimeInterval(1)),
                "one second apart should be two versions")
        }
        Harness.test("the stamp sorts in the order the scans happened") {
            let early = Scan.versionStamp(Date(timeIntervalSince1970: 1_757_500_000))
            let late = Scan.versionStamp(Date(timeIntervalSince1970: 1_757_600_000))
            Harness.expectTrue(early < late, "\(early) should sort before \(late)")
        }
        // A version string SonarQube cannot store is a scan that fails at the
        // very end, after all the work.
        Harness.test("the stamp has no character that needs escaping") {
            let stamp = Scan.versionStamp()
            let allowed = CharacterSet(charactersIn: "0123456789-TZ")
            Harness.expectTrue(
                stamp.unicodeScalars.allSatisfy(allowed.contains),
                "unexpected characters in \(stamp)")
        }
    }
}

func projectKeyTests() {
    Harness.suite("Project.key — what SonarQube will actually accept") {
        // ⚠ Swift's isLetter is Unicode-aware and SonarQube's key rule is
        // not. Every one of these produced a key the server refused, after
        // the scanner had already run for twenty-five seconds.
        Harness.test("a key is ASCII, whatever the folder is called") {
            let legal = CharacterSet(
                charactersIn:
                    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
            for folder in [
                "café-service", "münchen-api", "日本-service", "señor-svc", "Ärger",
                "🐦-svc", "my project", "---", ".dotfiles", "北京",
            ] {
                let key = Project.key(for: URL(filePath: "/tmp/probe/\(folder)"))
                Harness.expectTrue(
                    key.unicodeScalars.allSatisfy(legal.contains),
                    "key for '\(folder)' is '\(key)', which SonarQube would refuse")
                Harness.expectTrue(
                    !(key.first.map { $0 == "-" || $0 == "." || $0 == "_" } ?? true),
                    "key for '\(folder)' starts with a separator: '\(key)'")
            }
        }
        // Two transforms, pinned separately: without `stripDiacritics`, `café`
        // keys as `caf`; without `toLatin`, every non-Latin project collapses
        // to "project".
        Harness.test("an accent is carried across, not thrown away") {
            Harness.expectTrue(
                Project.key(for: URL(filePath: "/tmp/probe/café-service")).hasPrefix("cafe-"),
                "café should read as cafe, got "
                    + Project.key(for: URL(filePath: "/tmp/probe/café-service")))
            Harness.expectTrue(
                Project.key(for: URL(filePath: "/tmp/probe/münchen-api")).hasPrefix("munchen-"),
                "münchen should read as munchen")
        }
        Harness.test("a name in another script keeps an identity of its own") {
            let key = Project.key(for: URL(filePath: "/tmp/probe/北京"))
            Harness.expectTrue(
                !key.hasPrefix("project-"),
                "北京 collapsed to the generic fallback: \(key)")
            Harness.expectTrue(key.hasPrefix("bei-jing-"), "expected bei-jing, got \(key)")
        }
        // ⚠ 16 bits is 65,535 buckets: two different `svc` folders keyed the
        // same, so the second scan looked like a re-scan of the first and
        // history reported a critical issue fixed that never was.
        Harness.test("two directories with one basename are two projects") {
            let first = Project.key(for: URL(filePath: "/tmp/c1002/svc"))
            let second = Project.key(for: URL(filePath: "/tmp/c2740/svc"))
            Harness.expectTrue(first != second, "\(first) collided with \(second)")
        }
        Harness.test("the same directory always keys the same") {
            Harness.expectEqual(
                Project.key(for: URL(filePath: "/tmp/c1002/svc")),
                Project.key(for: URL(filePath: "/tmp/c1002/svc")))
        }
    }
}
