import AppKit

/// Oilbird's own mark, drawn as a view so it can move.
///
/// The same geometry `Icon` renders into the app icon, so the spinner, the
/// menu bar and the tile are one drawing rather than three that drift. A
/// system progress spinner said "something is happening" in a vocabulary
/// belonging to no app in particular; this says it in ours.
final class BirdView: NSView {
    /// Sonar arcs ping outward from the beak while this is true.
    var isCalling = false {
        didSet {
            guard isCalling != oldValue else { return }
            if isCalling { start() } else { stop() }
        }
    }

    private var phase: CGFloat = 0
    private var timer: Timer?

    /// The clicks, as drawn in `Icon`: radius, and how far along the ping
    /// each one starts. A third is added here that the static mark does not
    /// have — one arc pulsing reads as a glitch, three read as a sweep.
    private static let arcs: [(radius: CGFloat, offset: CGFloat)] = [
        (13, 0), (22, 0.22), (31, 0.44),
    ]

    /// ⚠ `isolated deinit`, because the timer it invalidates is main-actor
    /// state and a plain `deinit` is nonisolated. Dropping the invalidate
    /// instead would leave a 20 fps timer holding a weak reference and firing
    /// into nothing for the life of the process.
    isolated deinit { timer?.invalidate() }

    private func start() {
        // 20 fps. A sonar sweep is slow by nature and this is a background
        // reassurance, not an animation anyone should watch — spending a
        // display link on it would be the wrong trade.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.phase += 1.0 / 20 / 1.9
                if self.phase > 1 { self.phase -= 1 }
                self.needsDisplay = true
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height)
        let unit = side / 128
        context.saveGState()
        context.translateBy(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)

        // Described top-left like the canvas in `Icon`; Core Graphics draws
        // bottom-left.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * unit, y: (128 - y) * unit)
        }

        context.setFillColor(Theme.Colour.primaryText.cgColor)
        context.saveGState()
        context.translateBy(x: 44 * unit, y: (128 - 72) * unit)
        context.rotate(by: 13 * .pi / 180)
        context.fillEllipse(
            in: CGRect(x: -24 * unit, y: -17 * unit, width: 48 * unit, height: 34 * unit))
        context.restoreGState()
        context.fillEllipse(
            in: CGRect(x: 50 * unit, y: (128 - 68) * unit, width: 26 * unit, height: 26 * unit))
        context.beginPath()
        context.move(to: point(26, 64))
        context.addLine(to: point(4, 92))
        context.addLine(to: point(32, 77))
        context.fillPath()
        context.beginPath()
        context.move(to: point(74, 50))
        context.addLine(to: point(92, 56))
        context.addLine(to: point(74, 62))
        context.fillPath()

        context.setFillColor(Theme.Colour.tertiaryText.cgColor)
        context.saveGState()
        context.translateBy(x: 42 * unit, y: (128 - 74) * unit)
        context.rotate(by: 15 * .pi / 180)
        context.fillEllipse(
            in: CGRect(x: -15 * unit, y: -6 * unit, width: 30 * unit, height: 12 * unit))
        context.restoreGState()

        context.setFillColor(Theme.Colour.surface.cgColor)
        context.fillEllipse(
            in: CGRect(x: 64.8 * unit, y: (128 - 54.2) * unit, width: 6.4 * unit, height: 6.4 * unit))

        context.setStrokeColor(Theme.Colour.accent.cgColor)
        context.setLineCap(.round)
        context.setLineWidth(4.4 * unit)
        for (radius, offset) in Self.arcs {
            // At rest the mark is the icon: the near arc solid, the next
            // faint, and nothing moving.
            let alpha: CGFloat
            let travel: CGFloat
            if isCalling {
                var local = phase - offset
                if local < 0 { local += 1 }
                // Fade in fast, out slowly — a ping leaving, not a blink.
                alpha = local < 0.22 ? local / 0.22 : max(0, 1 - (local - 0.22) / 0.78)
                travel = -3 + local * 7
            } else {
                alpha = radius <= 13 ? 1 : (radius <= 22 ? 0.42 : 0)
                travel = 0
            }
            guard alpha > 0.01 else { continue }
            context.setAlpha(alpha)
            context.beginPath()
            let centre = point(98 - radius / 2 + travel, 56)
            context.addArc(
                center: centre, radius: radius * unit,
                startAngle: -.pi / 2.4, endAngle: .pi / 2.4, clockwise: false)
            context.strokePath()
        }
        context.setAlpha(1)
        context.restoreGState()
    }
}
