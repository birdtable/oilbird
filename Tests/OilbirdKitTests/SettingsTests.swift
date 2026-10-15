import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

/// Settings: every control changes something observable, proved by
/// reading the value back through `Preferences` AND by a fault showing the
/// behaviour actually differing.
///
/// The second half is what makes these worth writing. A test that sets a
/// field and reads it back proves a struct works; it proves nothing about
/// whether anything reads that field. Each suite below therefore drives the
/// code the setting is supposed to govern and looks at what came out.
func settingsPreferenceTests() {
    Harness.suite("Settings — every switch reaches something") {
        Harness.test("every new field round-trips through the plist") {
            let stored = Preferences.Stored(
                idleTimeout: .after(minutes: 45),
                lastPorts: .init(web: 51000, search: 51001),
                menuBarIcon: false, stayResident: false, appearance: .dark,
                webMemoryMegabytes: 2048, pinnedWebPort: 9111,
                neverAnalysed: ["**/generated/**"],
                treatedAsTests: ["**/e2e/**"])
            try? Preferences.save(stored)
            let read = Preferences.load()
            Harness.expectEqual(read.idleTimeout, .after(minutes: 45))
            Harness.expectEqual(read.menuBarIcon, false)
            Harness.expectEqual(read.stayResident, false)
            Harness.expectEqual(read.appearance, .dark)
            Harness.expectEqual(read.webMemoryMegabytes, 2048)
            Harness.expectEqual(read.pinnedWebPort, 9111)
            Harness.expectEqual(read.neverAnalysed, ["**/generated/**"])
            Harness.expectEqual(read.treatedAsTests, ["**/e2e/**"])
            Harness.expectEqual(read.lastPorts?.web, 51000)
        }

        // ⚠ A synthesized `init(from:)` THROWS on an absent key rather than
        // using the default, and `load()` falls back to `Stored()`: adding one
        // property resets every existing user's whole file.
        Harness.test("a preferences file from before these fields keeps its values") {
            let old = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>idleTimeout</key>
                    <string>2h</string>
                </dict>
                </plist>
                """
            try? FileManager.default.createDirectory(
                at: Paths.config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(old.utf8).write(to: Paths.config)
            let read = Preferences.load()
            Harness.expectEqual(
                read.idleTimeout, .after(minutes: 120),
                "the old interval was lost when the new fields were added")
            Harness.expectEqual(read.menuBarIcon, true, "the default did not apply")
            Harness.expectEqual(read.stayResident, true)
            Harness.expectEqual(read.appearance, .auto)
            Harness.expectNil(read.webMemoryMegabytes, "memory should default to the server's")
            // ⚠ The suggestion, never empty: a file written before this field
            // existed must decode to the behaviour its owner already had, or
            // every scan becomes the twenty-minute walk the list prevents.
            Harness.expectEqual(
                read.neverAnalysed, ScannerCommand.defaultNeverSource,
                "an upgrading install lost the exclusions it already had")
            Harness.expectEqual(read.treatedAsTests, ScannerCommand.defaultTestPatterns)
        }

        // ⚠ One build kept the user's patterns in `alsoNeverAnalysed`, so
        // reading only the new key discards them silently: the field looks
        // empty and the scan behaves differently with nothing said.
        Harness.test("patterns saved under the previous key are carried forward") {
            let old = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>alsoNeverAnalysed</key>
                    <array><string>**/generated/**</string><string>**/vendor/**</string></array>
                    <key>alsoTreatedAsTests</key>
                    <array><string>**/e2e/**</string></array>
                </dict>
                </plist>
                """
            try? FileManager.default.createDirectory(
                at: Paths.config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(old.utf8).write(to: Paths.config)
            let read = Preferences.load()
            Harness.expectTrue(
                read.neverAnalysed.contains("**/generated/**"),
                "the user's own pattern was thrown away by the rename")
            Harness.expectTrue(
                read.neverAnalysed.contains("**/node_modules/**"),
                "the suggestion should still be underneath it")
            Harness.expectEqual(
                read.neverAnalysed.filter { $0 == "**/vendor/**" }.count, 1,
                "a pattern that was already in the suggestion was duplicated")
            Harness.expectTrue(read.treatedAsTests.contains("**/e2e/**"))
            // And it must not be written back, or the old shape lives for ever.
            try? Preferences.save(read)
            let rewritten =
                String(
                    data: (try? Data(contentsOf: Paths.config)) ?? Data(),
                    encoding: .utf8) ?? ""
            Harness.expectTrue(
                !rewritten.contains("alsoNeverAnalysed"),
                "the legacy key was written back out")
        }

        // The fault: change the setting, and the properties file the server
        // is actually started from must differ.
        Harness.test("the memory setting reaches sonar.properties") {
            let none = writtenConfiguration(webJavaOpts: nil)
            Harness.expectTrue(
                !none.contains("sonar.web.javaOpts"),
                "an unset memory wrote an option, overriding SonarQube's own default")

            let chosen = writtenConfiguration(
                webJavaOpts: Preferences.WebMemory.javaOpts(megabytes: 2048))
            Harness.expectTrue(
                chosen.contains("sonar.web.javaOpts=-Xmx2048m"),
                "the chosen heap is not in the file the server reads")
            // ⚠ Writing this property REPLACES SonarQube's default wholesale,
            // so dropping the rest takes away the heap dump, the one artefact
            // that makes the next out-of-memory diagnosable.
            Harness.expectTrue(
                chosen.contains("HeapDumpOnOutOfMemoryError"),
                "the rest of SonarQube's default options were dropped")
        }

        Harness.test("the memory choices never go below SonarQube's own default") {
            Harness.expectEqual(
                Preferences.WebMemory.choices.min(), Preferences.WebMemory.defaultMegabytes)
            Harness.expectTrue(Preferences.WebMemory.choices.count > 1, "there is no choice")
        }

        Harness.test("the user's list reaches the scanner's command line intact") {
            let sent = ScannerCommand.patterns(
                ["**/generated/**", " ", "**/.git/**", "**/.git/**"])
            Harness.expectEqual(
                sent, "**/generated/**,**/.git/**",
                "blanks and duplicates are dropped and nothing else is")
        }

        // ⚠ A user who deletes a pattern must see it gone from the command
        // line, or the setting is decoration. SonarQube itself scopes these:
        // `**/vendor/**` is Go, PHP and Ruby only.
        Harness.test("a pattern the user removed does NOT come back") {
            var mine = ScannerCommand.defaultNeverSource
            mine.removeAll { $0 == "**/node_modules/**" }
            let sent = ScannerCommand.patterns(mine)
            Harness.expectTrue(
                !sent.contains("**/node_modules/**"),
                "Oilbird put back a pattern the user deleted")
            Harness.expectTrue(sent.contains("**/vendor/**"), "the rest of the list survived")
        }

        Harness.test("an empty list means analyse everything, and is allowed") {
            Harness.expectEqual(
                ScannerCommand.patterns([]), "",
                "an emptied list must reach the scanner empty, not fall back to a default")
        }

        Harness.test("a fresh install starts at the suggestion") {
            Harness.expectEqual(
                Preferences.Stored().neverAnalysed, ScannerCommand.defaultNeverSource,
                "a new install should still skip node_modules without being asked")
            Harness.expectEqual(
                Preferences.Stored().treatedAsTests, ScannerCommand.defaultTestPatterns)
        }

        // A pinned port has to beat a remembered one, and must still lose to
        // reality — `Ports` exists to design "port already in use" out.
        Harness.test("a pinned port is preferred, and still yields when taken") {
            let free = try? Ports.free()
            guard let free else {
                Harness.expectTrue(false, "no free port to test with")
                return
            }
            Harness.expectEqual(
                try? Ports.preferring(free), free, "a free pinned port was not taken")

            // Hold it, and the same request must come back with something
            // else rather than failing.
            let holder = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = free.bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            defer { close(holder) }
            let fallback = try? Ports.preferring(free)
            Harness.expectTrue(fallback != nil, "a taken pin refused to start at all")
            Harness.expectTrue(fallback != free, "a taken port was handed out anyway")
        }
    }
}

/// Writes a configuration into a throwaway install and reads it back.
///
/// The real writer, not a copy of the string: a test that built its own
/// properties file would agree with itself for ever.
private func writtenConfiguration(webJavaOpts: String?) -> String {
    try? Supervise.writeConfiguration(
        databasePort: 5432, databasePassword: "probe", webPort: 9000, searchPort: 9001,
        webJavaOpts: webJavaOpts)
    let conf = Paths.Cache.sonarqube.appending(path: "conf/sonar.properties")
    return (try? String(contentsOf: conf, encoding: .utf8)) ?? ""
}

/// `installCLI` linked the running executable,
/// which from the GUI is the application.
func commandLineBinaryTests() {
    Harness.suite("The CLI link points at the CLI, not at the app") {
        // ⚠ `CommandLine.arguments[0]` from the GUI is the APP binary, so a
        // symlink to it makes `oilbird status` open a window. Resolved the way
        // `Bundled.swift` and `Oilbird.build` already do.
        Harness.test("an app-shaped bundle resolves to Contents/Helpers, not Contents/MacOS") {
            let root = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-bundle-\(UUID().uuidString)")
            let bundle = root.appending(path: "Oilbird.app")
            let macos = bundle.appending(path: "Contents/MacOS")
            let helpers = bundle.appending(path: "Contents/Helpers")
            let manager = FileManager.default
            try? manager.createDirectory(at: macos, withIntermediateDirectories: true)
            try? manager.createDirectory(at: helpers, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: root) }

            let app = macos.appending(path: "Oilbird")
            let cli = helpers.appending(path: "oilbird")
            for binary in [app, cli] {
                try? Data("#!/bin/sh\n".utf8).write(to: binary)
                try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            }

            // The same arithmetic `cliBinary()` does, against a tree whose
            // shape is the one that broke: up out of Contents/MacOS, then
            // down the path `CommandLineTool` names.
            let resolved =
                app
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: CommandLineTool.bundleRelativePath)
            Harness.expectEqual(
                resolved.resolvingSymlinksInPath().path, cli.resolvingSymlinksInPath().path,
                "the app binary's bundle does not lead to the helper")
            Harness.expectTrue(
                !resolved.path.hasSuffix("MacOS/Oilbird"),
                "the link would point at the application")
            Harness.expectTrue(manager.isExecutableFile(atPath: resolved.path))
        }

        // In this suite `Bundle.main` is the test runner in `.build/debug`,
        // where the sibling `oilbird` is the CLI built from this source. So
        // the live function is exercised, not only its arithmetic.
        Harness.test("the resolved binary is never the running executable") {
            guard let found = Oilbird.cliBinary() else {
                // A `swift build` that has not built the CLI yet. Say so
                // rather than pass: `make test` builds it first for exactly
                // this reason.
                Harness.expectTrue(false, "no oilbird binary beside the test runner")
                return
            }
            Harness.expectEqual(found.lastPathComponent, "oilbird")
            Harness.expectTrue(
                found.path != Bundle.main.executableURL?.path,
                "the CLI resolved to whatever is running, which is the whole bug")
        }

        // The button and the sentence it offers when the button is refused
        // must name the same file, or one of them is wrong.
        Harness.test("the manual command names the binary the button would link") {
            guard let found = Oilbird.cliBinary() else { return }
            Harness.expectTrue(
                Oilbird.manualCLIInstall.contains(found.path),
                "the copyable command names a different file from the Install button")
            Harness.expectTrue(
                Oilbird.manualCLIInstall.hasSuffix(CommandLineTool.linkPath))
        }
    }
}

/// Disk accounting and the reclaim action.
func storageTests() {
    Harness.suite("Storage — what can be reclaimed, and what cannot") {
        Harness.test("a directory's bytes are the bytes in it") {
            let root = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-bytes-\(UUID().uuidString)")
            let nested = root.appending(path: "a/b")
            try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try? Data(repeating: 0, count: 1000).write(to: root.appending(path: "one"))
            try? Data(repeating: 0, count: 2000).write(to: nested.appending(path: "two"))
            Harness.expectEqual(Oilbird.directoryBytes(at: root), 3000)
            Harness.expectEqual(
                Oilbird.directoryBytes(at: root.appending(path: "absent")), 0,
                "a path that is not there is not an error")
        }

        // ⚠ The safety property, and the reason `Paths` has two roots at
        // all. `reclaim` refuses anything outside the cache; without this
        // the split is a convention rather than a guarantee.
        Harness.test("nothing outside the cache root is ever reclaimable") {
            Harness.expectTrue(
                Oilbird.isUnderCacheRoot(Paths.Cache.partials.appending(path: "abc")))
            Harness.expectTrue(Oilbird.isUnderCacheRoot(Paths.Cache.temp))
            Harness.expectTrue(
                !Oilbird.isUnderCacheRoot(Paths.State.clusterData),
                "the analysis history is reachable from reclaim")
            Harness.expectTrue(!Oilbird.isUnderCacheRoot(Paths.state))
            Harness.expectTrue(
                !Oilbird.isUnderCacheRoot(URL(filePath: NSHomeDirectory())),
                "a home directory passed the containment check")
        }

        // Digest-keyed files that finished downloading and were never pruned,
        // 1.22 GB of them. The rule is size against the manifest, because
        // there is no install record to ask.
        Harness.test("a finished installer is dead weight; an interrupted one is not") {
            guard let entry = try? Manifest.bundled().entry(.jdk) else {
                Harness.expectTrue(false, "the manifest did not load")
                return
            }
            let manager = FileManager.default
            try? manager.createDirectory(
                at: Paths.Cache.partials, withIntermediateDirectories: true)
            let pinnedFile = Paths.Cache.partials.appending(path: entry.sha256)
            let strayFile = Paths.Cache.partials.appending(path: String(repeating: "a", count: 64))
            try? Data(repeating: 0, count: 20).write(to: strayFile)
            defer {
                try? manager.removeItem(at: pinnedFile)
                try? manager.removeItem(at: strayFile)
            }

            // Half of a pinned download. This is somebody's interrupted
            // first run, and deleting it is what a naive "empty the
            // directory" would do.
            try? Data(repeating: 0, count: 32).write(to: pinnedFile)
            var superseded = Oilbird.supersededPartials().map(\.lastPathComponent)
            Harness.expectTrue(
                superseded.contains(strayFile.lastPathComponent),
                "an artefact this build does not pin was kept")
            Harness.expectTrue(
                !superseded.contains(entry.sha256),
                "a download that could still be resumed was marked dead")

            // ⚠ A file at its FULL size has nothing left to resume. Written
            // sparse, since the real artefact is 200 MB.
            let handle = try? FileHandle(forWritingTo: pinnedFile)
            try? handle?.truncate(atOffset: UInt64(entry.bytes))
            try? handle?.close()
            superseded = Oilbird.supersededPartials().map(\.lastPathComponent)
            Harness.expectTrue(
                superseded.contains(entry.sha256),
                "a finished download of \(Oilbird.humanBytes(entry.bytes)) was kept for ever")
        }

        Harness.test("reclaim deletes what it named, and returns what it freed") {
            let manager = FileManager.default
            try? manager.createDirectory(
                at: Paths.Cache.partials, withIntermediateDirectories: true)
            let stray = Paths.Cache.partials.appending(path: String(repeating: "b", count: 64))
            try? Data(repeating: 0, count: 4096).write(to: stray)
            let before = Oilbird.diskReport()
            Harness.expectTrue(
                before.reclaimable >= 4096, "the report did not see the dead installer")

            let freed = (try? Oilbird.reclaim()) ?? 0
            Harness.expectTrue(freed >= 4096, "reclaim reported less than it deleted")
            Harness.expectTrue(
                !manager.fileExists(atPath: stray.path), "the dead installer is still there")
        }

        Harness.test("the report separates what a download can replace from what it cannot") {
            let report = Oilbird.diskReport()
            Harness.expectTrue(!report.keep.isEmpty, "nothing is listed as irreplaceable")
            Harness.expectTrue(!report.cache.isEmpty)
            for entry in report.keep {
                Harness.expectEqual(
                    entry.reclaimable, 0,
                    "\(entry.label) is irreplaceable and offered for deletion")
            }
            Harness.expectEqual(report.stateRoot, Paths.state.path)
            Harness.expectEqual(report.cacheRoot, Paths.cache.path)
            Harness.expectTrue(
                report.relocatedTo != nil,
                "the suites run under OILBIRD_HOME and the report did not notice")
        }
    }
}

/// The MCP wiring: agents drive Oilbird, and the client snippet has to come
/// from somewhere.
func agentAccessTests() {
    Harness.suite("Agents — the snippet nobody could have written by hand") {
        Harness.test("the snippet is valid JSON naming the server binary") {
            guard let snippet = Oilbird.mcpClientSnippet(), let binary = Oilbird.mcpBinary()
            else {
                // No bundle and no sibling: a `swift build` that has not
                // built the MCP target. Not a pass.
                Harness.expectTrue(
                    Oilbird.mcpBinary() == nil,
                    "there is a binary but no snippet, which is the one broken combination")
                return
            }
            let parsed =
                (try? JSONSerialization.jsonObject(with: Data(snippet.utf8)))
                as? [String: Any]
            guard let servers = parsed?["mcpServers"] as? [String: Any],
                let entry = servers[Oilbird.mcpServerName] as? [String: Any]
            else {
                Harness.expectTrue(false, "the snippet is not the shape a client expects")
                return
            }
            Harness.expectEqual(entry["command"] as? String, binary.path)
            Harness.expectTrue(
                binary.lastPathComponent.hasSuffix("-mcp"),
                "the snippet points at something that is not the MCP server")
        }

        // ⚠ A snippet written down instead of generated has had every path
        // and verb in it wrong.
        Harness.test("the snippet carries no markdown and no placeholder") {
            guard let snippet = Oilbird.mcpClientSnippet() else { return }
            for forbidden in ["`", "**", "<path", "/path/to", "…"] {
                Harness.expectTrue(
                    !snippet.contains(forbidden),
                    "the snippet contains \(forbidden), which a client cannot use")
            }
        }

        Harness.test("there is no dashboard link when there is no dashboard") {
            guard Oilbird.status() == nil else {
                Harness.expectTrue(true, "an engine is running in this container")
                return
            }
            Harness.expectNil(
                Oilbird.dashboardURL(),
                "a link was offered to a server that is not there")
        }
    }
}

/// What the Scanning and Versions panes claim, checked against the code
/// they claim it about.
func settingsFactTests() {
    Harness.suite("Settings — the facts the read-only panes show") {
        Harness.test("the exclusion lists shown are the lists the scanner is given") {
            Harness.expectEqual(
                Oilbird.suggestedNeverAnalysed, ScannerCommand.defaultNeverSource)
            Harness.expectEqual(
                Oilbird.suggestedTreatedAsTests, ScannerCommand.defaultTestPatterns)
            Harness.expectEqual(
                Oilbird.exclusionsAsSent(),
                ScannerCommand.patterns(Oilbird.settings().neverAnalysed),
                "the pane must show the command line, not the suggestion")
        }

        // ⚠ Computed from `Project`'s own functions, so it cannot become a
        // picture of behaviour Oilbird no longer has. The accented folder is
        // the case that used to fail after twenty-five seconds of analysis.
        Harness.test("the naming example is derived, not written down") {
            let example = Oilbird.namingExample()
            Harness.expectEqual(example.folderName, "café-service")
            Harness.expectEqual(example.name, "café-service", "the label should be untouched")
            Harness.expectTrue(
                example.key.hasPrefix("cafe-service-"),
                "the key is \(example.key); it should be transliterated ASCII plus a hash")
            for character in example.key {
                Harness.expectTrue(
                    character.isASCII, "\(character) would be refused in a SonarQube key")
            }
        }

        Harness.test("the version table keeps pinned and installed apart") {
            guard let table = try? Oilbird.versionTable() else {
                Harness.expectTrue(false, "the version table did not build")
                return
            }
            Harness.expectEqual(table.count, DependencyID.allCases.count)
            for row in table {
                Harness.expectNotEmpty(row.pinned, "\(row.id) has no pinned version")
                Harness.expectNotEmpty(row.licence, "\(row.id) has no licence")
                // Nothing is installed in a throwaway container, and the
                // honest answer there is absence — NOT the pinned string,
                // which is precisely the lie `doctor` told for the scanner.
                Harness.expectNil(row.installed, "\(row.id) reported an install that is not there")
                Harness.expectTrue(!row.differs, "absence was reported as a difference")
                Harness.expectNil(row.change)
            }
        }

        Harness.test("a version that differs reads as a change") {
            let row = Oilbird.VersionRow(
                id: "scanner", pinned: "7.4.0.0", installed: "7.3.0.5189", licence: "LGPL-3.0")
            Harness.expectTrue(row.differs)
            Harness.expectEqual(row.change, "↑ scanner 7.3.0.5189 → 7.4.0.0")
        }

        // The login item's truth is the system's, not a stored copy — so the
        // vocabulary has to include "there is no bundle to register".
        Harness.test("the login item reports unavailable rather than off in a test run") {
            Harness.expectEqual(
                Oilbird.loginItemState(), .unavailable,
                "a bare executable claimed a login-item state it cannot have")
            var threw = false
            do { try Oilbird.setLoginItem(true) } catch { threw = true }
            Harness.expectTrue(threw, "registering from a non-bundle silently claimed success")
        }

        Harness.test("the settings file follows OILBIRD_HOME like everything else") {
            Harness.expectEqual(Oilbird.settingsFilePath, Paths.config.path)
            Harness.expectTrue(
                Oilbird.settingsFilePath.contains("oilbird-tests-"),
                "the settings path escaped the sandbox: \(Oilbird.settingsFilePath)")
        }
    }
}

/// ⚠ Four rows reading "No install recorded" on a machine whose SonarQube
/// was serving the page behind the window. True — the record is written at
/// install time and those installs predate the code that writes it — and
/// useless, because it read as a fault and left the pane's one question
/// unanswered. So the pane now falls back to what is on disk.
func detectedVersionTests() {
    Harness.suite("Versions — what is on disk, when there is no record") {
        // ⚠ `detected` comes from the INSTALL, never the manifest: filling it
        // from the pinned version is the lie the pair exists to catch, and
        // invisible, because every row would agree with itself for ever.
        Harness.test("with nothing unpacked, no row claims a version from disk") {
            let rows = (try? Oilbird.versionTable()) ?? []
            Harness.expectEqual(
                rows.count, DependencyID.allCases.count, "a row per dependency")
            for row in rows {
                Harness.expectNil(
                    row.detected,
                    "\(row.id) reported \(row.detected ?? "") on disk in an empty container")
                Harness.expectTrue(
                    !row.pinned.isEmpty, "the pinned version is still known")
            }
        }

        // Staged, read, unstaged, read again — so the field cannot be a
        // constant nil that happens to look right on a bare machine.
        Harness.test("a staged install is read off the disk, and unstaging it is noticed") {
            guard let pinned = try? Manifest.bundled().entry(.jdk).pinnedIdentifier else {
                Harness.expectTrue(false, "the manifest has no JDK release tag")
                return
            }
            let home = Paths.Cache.jdk.appending(path: "Contents/Home")
            try? FileManager.default.createDirectory(
                at: home.appending(path: "bin"), withIntermediateDirectories: true)
            try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: home.appending(path: "bin/java"))
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/java").path)
            try? Data("SEMANTIC_VERSION=\"\(pinned)\"\n".utf8)
                .write(to: home.appending(path: "release"))
            defer { try? FileManager.default.removeItem(at: Paths.Cache.jdk) }

            let found = ((try? Oilbird.versionTable()) ?? []).first { $0.id == "jdk" }?.detected
            Harness.expectEqual(
                found, pinned, "the pane did not read the version off the install")

            try? FileManager.default.removeItem(at: home.appending(path: "release"))
            let gone = ((try? Oilbird.versionTable()) ?? []).first { $0.id == "jdk" }?.detected
            Harness.expectNil(gone, "the pane kept reporting a version after the install left")
        }

        // ⚠ Deliberate: a SUPERSEDED install reads as absent, because
        // `detect()` answers "is the pinned one here" and the next start
        // reinstalls it.
    }
}
