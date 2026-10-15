import Foundation

/// The files Oilbird ships with itself: `manifest.json` and the pinned
/// SonarQube token vocabulary.
///
/// ⚠ **`Bundle.module` cannot be used directly: a build that uses it cannot
/// launch anywhere but where it was built.** SwiftPM generates an accessor that looks in
/// exactly two places: `Bundle.main.bundleURL/Oilbird_OilbirdCore.bundle`,
/// and — baked in as an absolute string — the `.build` directory of the
/// machine that compiled it. For a `.app` the first is the bundle ROOT,
/// where nothing may live: `codesign` refuses with "unsealed contents
/// present in the bundle root". So the resource bundle cannot go where the
/// accessor looks, the accessor falls through to the build machine's
/// `.build` path, and every build works on the machine that made it and dies
/// on launch everywhere else — `Swift.fatalError`, before a window. Only a
/// clean machine shows it.
///
/// The same fault reached the CLI, which is worse: `cli-install` symlinks
/// it onto the user's `PATH`, where it has no `.app` around it at all.
///
/// So resources are found relative to the RUNNING EXECUTABLE, which is the
/// one thing true in every shape Oilbird takes — app binary in
/// `Contents/MacOS`, helper in `Contents/Helpers`, symlink in
/// `/usr/local/bin`, and `swift run` out of `.build`.
enum Bundled {
    /// Searched in order; the first that has the file wins.
    ///
    /// `Bundle.module` is LAST and reached only when nothing shipped is
    /// present, which is the test and `swift run` case. It must stay last:
    /// evaluating it when the bundle is absent is a `fatalError`, not an
    /// optional, so it cannot be probed and recovered from.
    static func url(named name: String, extension ext: String) -> URL? {
        let file = "\(name).\(ext)"
        let manager = FileManager.default
        var candidates: [URL] = []
        // ⚠ Symlinks resolved. `cli-install` puts a symlink on the PATH, and
        // unresolved it makes the executable look like it lives in
        // /usr/local/bin — two directories from anything Oilbird shipped.
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let directory = executable.deletingLastPathComponent()
            // Contents/MacOS/Oilbird and Contents/Helpers/oilbird are both
            // one level below Contents, so both reach the same Resources.
            candidates.append(
                directory.deletingLastPathComponent().appending(path: "Resources"))
            candidates.append(directory)
        }
        if let resources = Bundle.main.resourceURL { candidates.append(resources) }
        for base in candidates where manager.fileExists(atPath: base.appending(path: file).path) {
            return base.appending(path: file)
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
