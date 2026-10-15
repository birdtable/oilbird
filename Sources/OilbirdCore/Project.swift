import Foundation
import OilbirdModel

/// What kind of project is this, and what should analyse it?
public enum Project {
    public enum Toolchain: String, Sendable {
        case maven, gradle, node, python, go, other
    }

    public struct Inferred: Sendable {
        public let path: URL
        public let key: String
        /// What a person calls this project.
        ///
        /// Separate from `key` on purpose. The key carries a hash of the
        /// absolute path so two checkouts of one repository cannot overwrite
        /// each other's history — necessary, and unreadable: the project list
        /// said `web-app-deaa`, `payments-service-4a30`,
        /// `storefront-wt-filters-inline-9af0`. Identity and label are
        /// different things, and only the label should be legible.
        public let name: String
        public let toolchain: Toolchain
        /// Set when the project already has one. Oilbird respects it untouched
        /// and never writes into a repository it is scanning.
        public let hasOwnProperties: Bool
        /// The coverage report the toolchain conventionally produces, if any.
        public let coverageProperty: String?
    }

    /// First match wins, in this order.
    public static func infer(at path: URL) -> Inferred {
        let manager = FileManager.default
        func has(_ name: String) -> Bool {
            manager.fileExists(atPath: path.appending(path: name).path)
        }

        let toolchain: Toolchain
        let coverage: String?
        switch true {
        case has("pom.xml"):
            toolchain = .maven
            coverage = nil  // the plugin finds JaCoCo itself
        case has("build.gradle") || has("build.gradle.kts"):
            toolchain = .gradle
            coverage = nil
        case has("package.json"):
            toolchain = .node
            coverage = "sonar.javascript.lcov.reportPaths=coverage/lcov.info"
        case has("pyproject.toml") || has("setup.py"):
            toolchain = .python
            coverage = "sonar.python.coverage.reportPaths=coverage.xml"
        case has("go.mod"):
            toolchain = .go
            coverage = "sonar.go.coverage.reportPaths=coverage.out"
        default:
            toolchain = .other
            coverage = nil
        }

        return Inferred(
            path: path, key: key(for: path), name: name(for: path), toolchain: toolchain,
            hasOwnProperties: has("sonar-project.properties"), coverageProperty: coverage)
    }

    /// The directory name, as the user wrote it.
    ///
    /// No hash and no sanitising: SonarQube accepts spaces and punctuation in
    /// a name, and the folder is what the person calls this thing. Two
    /// checkouts of one repository therefore share a name and differ by key,
    /// which is an honest picture of what is on the disk.
    public static func name(for path: URL) -> String {
        let folder = path.lastPathComponent
        return folder.isEmpty ? "project" : folder
    }

    /// The directory name, reduced to what SonarQube accepts — plus a hash of
    /// the absolute path.
    ///
    /// Two checkouts of the same repository are two projects. Without the hash
    /// they would share a key and silently overwrite each other's history,
    /// which is the one thing a server is kept for.
    ///
    /// ⚠ **The hash is 32 bits because 16 was not enough.** `% 0xFFFF` gives
    /// 65,535 buckets, which is small enough to hit by accident:
    /// `/tmp/c1002/svc` and `/tmp/c2740/svc` both produced `svc-f168`. Since
    /// the readable label is now the bare folder name, the second scan looked
    /// exactly like a re-scan of the first, and `history` duly reported
    /// `critical_violations 1 → 0 (-1)` — a fix that never happened, on a
    /// project that was really two projects. Widening costs four characters
    /// in a string nobody types.
    public static func key(for path: URL) -> String {
        var hash: UInt64 = 5381
        for byte in path.path.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return "\(readable(path.lastPathComponent))-\(String(hash % 0xFFFF_FFFF, radix: 16))"
    }

    /// A folder name reduced to characters SonarQube will accept in a key.
    ///
    /// ⚠ **ASCII, not `isLetter`.** Swift's `isLetter` is Unicode-aware and
    /// SonarQube's key rule is not: it takes ASCII alphanumerics plus `-_.:`
    /// and nothing else. So `é ü ñ 日本` passed the old filter, went into the
    /// key, and the server refused the analysis — after the scanner had run
    /// for twenty-five seconds, with the reason only in the log.
    /// `oilbird scan ~/src/café-service` could not succeed on any machine,
    /// and the only recourse was renaming the checkout. The user had done
    /// nothing wrong: Oilbird generated the invalid input itself.
    ///
    /// Transliterated BEFORE it is filtered, which is the difference between
    /// `cafe-service` and `caf-service`. Dropping the letter is the easy
    /// version and it quietly mangles the name of somebody's project;
    /// carrying it across is one line more, and `münchen-api` and `北京`
    /// come out as `munchen-api` and `bei-jing` rather than as wreckage.
    ///
    /// Leading separators are trimmed: a key beginning `-` or `.` is legal,
    /// ugly, and reads as a mistake — a `.dotfiles` checkout would otherwise
    /// key as `-dotfiles-…`. A name with nothing left after all of this —
    /// `---`, or a lone emoji — falls back to `project`, and the hash still
    /// keeps it distinct from every other one.
    static func readable(_ folder: String) -> String {
        let latin = folder.applyingTransform(.toLatin, reverse: false) ?? folder
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        let filtered =
            plain
            .replacingOccurrences(of: " ", with: "-")
            .filter { character in
                guard character.isASCII else { return false }
                return character.isLetter || character.isNumber
                    || character == "-" || character == "_" || character == "."
            }
        let trimmed = String(filtered.drop { $0 == "-" || $0 == "." || $0 == "_" })
        return trimmed.isEmpty ? "project" : trimmed
    }
}
