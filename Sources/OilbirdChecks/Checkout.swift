import Foundation

/// The working copy the gates read.
///
/// ⚠ Every gate reads the repository as TEXT and links against none of it.
/// That is deliberate and it is why `Gates` may reference no domain: a gate
/// that imported the code it checks could be made green by that code, and
/// the import matrix would be holding a rule written by its own subject.
enum Checkout {
    /// The directory holding `Package.swift` and `domains.yaml`, found by
    /// walking up from wherever the gate was run.
    ///
    /// ⚠ Not `#filePath`. That bakes the absolute path of the machine that
    /// COMPILED the binary into it, so a checkout built once and run from a
    /// second clone would quietly read the first one's sources.
    static let root: URL = {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            let manifest = directory.appending(path: "Package.swift")
            let map = directory.appending(path: "domains.yaml")
            if FileManager.default.fileExists(atPath: manifest.path),
                FileManager.default.fileExists(atPath: map.path)
            {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        fatalError(
            "checks: no Package.swift and domains.yaml above "
                + FileManager.default.currentDirectoryPath)
    }()

    static func url(_ relative: String) -> URL { root.appending(path: relative) }

    static func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relative).path)
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return there && directory.boolValue
    }

    /// A file, or a `Shape` naming it.
    ///
    /// ⚠ Unreadable is a failure and never a skip. A checker that dies on its
    /// input is indistinguishable from a green one at the exit code alone,
    /// which is `DM-0`'s whole point.
    static func read(_ relative: String) throws -> String {
        guard let text = try? String(contentsOf: url(relative), encoding: .utf8) else {
            throw Shape("could not read \(relative)")
        }
        return text
    }

    /// Every `.swift` file under a repository-relative directory, as
    /// repository-relative paths, sorted. Sorted so a finding list is stable
    /// between runs and a diff of two runs is about the code.
    static func swiftFiles(under relative: String) -> [String] {
        let base = url(relative)
        guard
            let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil)
        else { return [] }
        var found: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            found.append(file.path.replacingOccurrences(of: root.path + "/", with: ""))
        }
        return found.sorted()
    }

    /// A file under `Sources/OilbirdCore`, named by its stem.
    ///
    /// ⚠ Assembled rather than written out. Twenty of the domains in
    /// `domains.yaml` are named after their file, so the literal
    /// `"Sources/OilbirdCore/Tint.swift"` contains `Tint.` — and `DM-1`
    /// matches a domain reference by exactly that. Spelling these out would
    /// make the gates target reference half the domains it checks.
    static func core(_ stem: String) -> String { "Sources/OilbirdCore/\(stem).swift" }
}
