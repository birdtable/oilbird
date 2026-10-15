import Foundation
import OilbirdModel

/// Puts Oilbird's own CLI on the user's `PATH`, on opt-in.
///
/// Distinct from the rule that Oilbird never touches the user's dependencies,
/// which stops it adopting or mutating **third-party** dependencies — no
/// Homebrew, no writing into a cluster it did not create. Installing an
/// artefact it ships itself is the `code`/`docker`/`gh` pattern, and a tool
/// you can only invoke by its full path inside an app bundle is not
/// installed, merely present.
///
/// Absent until asked for, and removable from the same place that offered it.
public enum CommandLineTool {
    /// The conventional home for user-installed CLIs on macOS.
    public static let linkPath = "/usr/local/bin/oilbird"

    /// Where the CLI lives inside the bundle.
    ///
    /// ⚠ `Contents/Helpers`, never `Contents/MacOS`. macOS is case-insensitive,
    /// so `oilbird` and the app's own `Oilbird` are one file in `MacOS` — the
    /// first build put both there and the CLI silently overwrote the app.
    public static let bundleRelativePath = "Contents/Helpers/oilbird"

    public enum State: Sendable, Equatable {
        case absent
        case installed(target: String)
        /// A link pointing at a binary that is gone — the app was moved or
        /// deleted. Detected and offered for repair rather than failing
        /// opaquely when someone types `oilbird`.
        case dangling(target: String)
        /// Something else owns the name. Never silently replaced.
        case foreign
    }

    public static func state() -> State {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: linkPath) else {
            return .absent
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
            let target = try? manager.destinationOfSymbolicLink(atPath: linkPath)
        else {
            return .foreign
        }
        return manager.isExecutableFile(atPath: target)
            ? .installed(target: target) : .dangling(target: target)
    }

    /// - Parameter binary: the `oilbird` executable to point at.
    public static func install(binary: URL) throws {
        let manager = FileManager.default
        switch state() {
        case .installed(let target) where target == binary.path:
            return
        case .foreign:
            throw OilbirdError(
                .verifyFailed,
                "Something else is already installed as “oilbird”.",
                recovery: .reportIssue("Remove it yourself first"),
                underlying: "\(linkPath) exists and is not our symlink")
        case .installed, .dangling:
            try? manager.removeItem(atPath: linkPath)
        case .absent:
            break
        }

        let directory = (linkPath as NSString).deletingLastPathComponent
        if !manager.fileExists(atPath: directory) {
            // Creating /usr/local/bin needs privileges Oilbird does not have
            // and must not ask for. Say what to run rather than escalating.
            throw OilbirdError(
                .verifyFailed,
                "\(directory) does not exist yet.",
                recovery: .reportIssue("Create it, then try again"),
                underlying: "mkdir -p \(directory) needs an administrator")
        }
        do {
            try manager.createSymbolicLink(atPath: linkPath, withDestinationPath: binary.path)
        } catch {
            throw OilbirdError(
                .verifyFailed,
                "Oilbird could not write to \(directory).",
                recovery: .reportIssue("It may need an administrator"),
                underlying: "symlink failed: \(error)")
        }
        Log.info("installed the command line tool at \(linkPath)")
    }

    /// Reversible from the same surface that offered it, and only ever removes
    /// a link that is ours.
    public static func uninstall() throws {
        switch state() {
        case .absent:
            return
        case .foreign:
            throw OilbirdError(
                .verifyFailed, "That “oilbird” was not installed by Oilbird.",
                recovery: .reportIssue("Remove it yourself"),
                underlying: "\(linkPath) is not our symlink")
        case .installed, .dangling:
            try FileManager.default.removeItem(atPath: linkPath)
            Log.info("removed the command line tool")
        }
    }
}
