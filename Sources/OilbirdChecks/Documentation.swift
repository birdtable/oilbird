import Foundation

/// The README's pictures are real, and all of them are used.
///
/// `D-1`  Every image the README names is on disk. A broken image is the
///        first thing a reader sees and the last thing an author notices,
///        because it renders on the machine that made it.
/// `D-2`  Every captured image is named by the README. A capture nobody
///        references is a screen that moved, or one somebody meant to show
///        and forgot, and either way the zero IS the finding (DM-4).
///
/// The captures themselves come from `make screenshots`, which draws the real
/// binary on a real pseudo-terminal. This holds the wiring between the two.
struct Documentation: Check {
    let name = "docs"
    let holds = "every README image exists, is used, and fits its own canvas"

    private static let readme = "README.md"
    private static let folder = "docs/images"
    private static let image = Rx("<img src=\"(docs/images/[^\"]+)\"")
    /// The canvas a capture declares, and every run drawn on it.
    private static let canvas = Rx("<svg[^>]*\\swidth=\"([0-9.]+)\"")
    private static let run = Rx("textLength=\"([0-9.]+)\"")

    func selfTest() throws {
        guard
            Self.image.first(in: "<img src=\"docs/images/help.svg\" width=\"714\">" as NSString)?
                .group(1) == "docs/images/help.svg"
        else {
            throw SelfTest("an image reference was not read")
        }
        let svg = "<svg xmlns=\"x\" width=\"714\" height=\"40\"><text textLength=\"23423.4\">a</text>"
        guard Self.canvas.first(in: svg as NSString)?.group(1) == "714",
            Self.run.capture(in: svg as NSString) == ["23423.4"]
        else {
            throw SelfTest("a capture's canvas or its runs were not read")
        }
        // An `<img width=>` must not be mistaken for the canvas: the README
        // gives one to every picture, and reading that instead would measure
        // each capture against a number it cannot exceed.
        guard !Self.canvas.matches("<img src=\"a.svg\" width=\"714\">") else {
            throw SelfTest("an <img> width was read as an <svg> canvas")
        }
    }

    func run() throws -> Report {
        let text = try Checkout.read(Self.readme) as NSString
        let named = Set(Self.image.capture(in: text))
        guard !named.isEmpty else {
            throw Shape("the README names no images; has it changed shape?")
        }

        var report = Report(summary: "")
        for path in named.sorted() where !Checkout.exists(path) {
            report.findings.append(
                "D-1  the README shows \(path), which is not there. Run `make screenshots`")
        }

        let captured = Set(
            ((try? FileManager.default.contentsOfDirectory(
                atPath: Checkout.url(Self.folder).path)) ?? [])
                // ⚠ PNG as well as SVG: the terminal screens are drawn as SVG
                // and the app's windows are real screenshots. Holding one kind
                // left an orphaned app picture invisible to `D-2`.
                .filter { $0.hasSuffix(".svg") || $0.hasSuffix(".png") }
                .map { "\(Self.folder)/\($0)" })
        for orphan in captured.subtracting(named).sorted() {
            report.findings.append(
                "D-2  \(orphan) is captured and the README never shows it; either it is stale "
                    + "or somebody meant to use it")
        }

        // ⚠ `doctor.svg` shipped drawing a run 23,423 pixels wide on a
        // 714-pixel canvas. `screens` holds the live binary to its terminal;
        // nothing held a capture. SVG only: a PNG read as text is no canvas.
        for path in captured.sorted() where path.hasSuffix(".svg") {
            guard let svg = try? Checkout.read(path) as NSString,
                let width = Self.canvas.first(in: svg)?.group(1).flatMap(Double.init)
            else {
                report.findings.append("D-3  \(path) declares no width; it is not a capture")
                continue
            }
            let widest = Self.run.capture(in: svg).compactMap(Double.init).max() ?? 0
            if widest > width {
                report.findings.append(
                    "D-3  \(path) draws a run \(Int(widest)) wide on a \(Int(width)) canvas. "
                        + "Something ran off the edge; re-capture it and look at it")
            }
        }

        report.summary = "\(named.count) images named, \(captured.count) captured"
        return report
    }
}
