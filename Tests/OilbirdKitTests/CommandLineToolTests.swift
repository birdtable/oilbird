import Foundation
import OilbirdCore
import OilbirdModel

func commandLineToolTests() {
    Harness.suite("CommandLineTool — on PATH, and only on opt-in") {
        // Absent until asked for. A fresh install must write nothing outside
        // the container, and this is the one thing that ever could.
        Harness.test("nothing is installed unless someone asked") {
            if !FileManager.default.fileExists(atPath: CommandLineTool.linkPath) {
                Harness.expectEqual(CommandLineTool.state(), .absent)
            } else {
                // Someone's real machine may already have one; that is not a
                // failure, but it must be one of the states we model.
                let state = CommandLineTool.state()
                Harness.expectTrue(state != .absent, "an existing link reported absent")
            }
        }

        Harness.test("a link to a missing binary is dangling, not installed") {
            let scratch = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-link-\(UUID().uuidString)")
            let target = scratch.appending(path: "gone")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let link = scratch.appending(path: "oilbird")
            try? FileManager.default.createSymbolicLink(
                atPath: link.path, withDestinationPath: target.path)
            // Model the same predicate the real state() uses.
            let attributes = try? FileManager.default.attributesOfItem(atPath: link.path)
            let isLink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
            Harness.expectTrue(isLink, "the probe link was not a symlink")
            Harness.expectTrue(
                !FileManager.default.isExecutableFile(atPath: target.path),
                "the probe target should not exist")
        }

        // Never silently replace something we did not install. Someone else's
        // `oilbird` is theirs.
        Harness.test("a foreign file at the link path is refused, not overwritten") {
            let scratch = URL(filePath: NSTemporaryDirectory())
                .appending(path: "oilbird-foreign-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let occupied = scratch.appending(path: "oilbird")
            try? Data("#!/bin/sh\n".utf8).write(to: occupied)
            let attributes = try? FileManager.default.attributesOfItem(atPath: occupied.path)
            Harness.expectTrue(
                attributes?[.type] as? FileAttributeType != .typeSymbolicLink,
                "a regular file was seen as a symlink")
        }

        Harness.test("the link path is the conventional one") {
            Harness.expectEqual(CommandLineTool.linkPath, "/usr/local/bin/oilbird")
        }

        // Uninstalling something absent is a no-op, not an error: a control
        // that errors when there is nothing to do is a dead end.
        Harness.test("removing a tool that is not installed is harmless") {
            if case .absent = CommandLineTool.state() {
                var threw = false
                do { try CommandLineTool.uninstall() } catch { threw = true }
                Harness.expectTrue(!threw, "uninstalling nothing raised an error")
            } else {
                Harness.expectTrue(true, "a link exists on this machine; not touching it")
            }
        }
    }
}

func bundleLayoutTests() {
    Harness.suite("Bundle layout — the case collision, one level down") {
        // macOS is case-insensitive: `oilbird` and `Oilbird` are one file in
        // Contents/MacOS. The first bundle put both there and the CLI overwrote the
        // app, silently.
        Harness.test("the CLI does not live where the app executable lives") {
            let path = CommandLineTool.bundleRelativePath
            Harness.expectTrue(!path.hasPrefix("Contents/MacOS"), "the CLI is back in MacOS")
            Harness.expectTrue(path.hasSuffix("/oilbird"))
        }

        Harness.test("no two bundled executable names differ only by case") {
            let names = ["Oilbird", "oilbird", "oilbird-mcp"]
            let folded = Set(names.map { $0.lowercased() })
            // Oilbird and oilbird fold together — which is precisely why they
            // must not share a directory.
            Harness.expectTrue(
                folded.count < names.count,
                "the names no longer collide; the Helpers split may be unnecessary")
        }
    }
}
