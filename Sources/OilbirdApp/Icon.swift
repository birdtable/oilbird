import AppKit

/// Draws the app icon.
///
/// The binary draws its own mark, so the bundle and the running app can never
/// show different ones — the reason `make icon` runs the release binary
/// rather than reading a checked-in PNG.
///
/// The mark is one solid ink silhouette, a white dot eye, no
/// strokes on the bird. What Oilbird adds is the clicks, and they come out of
/// the beak, because that is where echolocation comes from.
enum Icon {
    /// ⚠ Locked once, drawn once, read after the unlock. It used to draw,
    /// unlock, lock and draw AGAIN through the `CGContext` it took under the
    /// first focus — a stale context, and a second pass nothing asked for.
    /// The image is the same either way, which is why nothing said so.
    static func write(to url: URL, size: CGFloat = 1024) -> Bool {
        let image = NSImage(size: NSSize(width: size, height: size))
        var drawn = false
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            draw(in: context, size: size)
            drawn = true
        }
        image.unlockFocus()

        // ⚠ Through the image, not `NSBitmapImageRep(focusedViewRect:)`:
        // that one reads whatever is focused RIGHT NOW, which is why it was
        // deprecated in 10.14 and why it has to be called before the unlock.
        guard drawn, let tiff = image.tiffRepresentation,
            let representation = NSBitmapImageRep(data: tiff),
            let data = representation.representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func draw(in context: CGContext, size: CGFloat) {
        let unit = size / 128
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            // The canvas is described top-left, Core Graphics draws bottom-left.
            CGPoint(x: x * unit, y: (128 - y) * unit)
        }

        // Paper ground with a faint vertical gradient.
        let squircle = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
            cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil)
        context.saveGState()
        context.addPath(squircle)
        context.clip()
        let colours = [
            NSColor(srgbRed: 0.957, green: 0.945, blue: 0.910, alpha: 1).cgColor,
            NSColor(srgbRed: 0.898, green: 0.882, blue: 0.839, alpha: 1).cgColor,
        ]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours as CFArray,
            locations: [0, 1])
        {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: size), end: .zero, options: [])
        }

        // The bird: overlapping solid shapes in one fill, so it reads as one
        // silhouette rather than an assembly.
        context.setFillColor(NSColor(srgbRed: 0.133, green: 0.141, blue: 0.165, alpha: 1).cgColor)
        context.saveGState()
        context.translateBy(x: 44 * unit, y: (128 - 72) * unit)
        context.rotate(by: 13 * .pi / 180)
        context.fillEllipse(
            in: CGRect(x: -24 * unit, y: -17 * unit, width: 48 * unit, height: 34 * unit))
        context.restoreGState()
        context.fillEllipse(
            in: CGRect(
                x: 50 * unit, y: (128 - 68) * unit, width: 26 * unit, height: 26 * unit))
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

        context.setFillColor(NSColor(srgbRed: 0.557, green: 0.541, blue: 0.502, alpha: 1).cgColor)
        context.saveGState()
        context.translateBy(x: 42 * unit, y: (128 - 74) * unit)
        context.rotate(by: 15 * .pi / 180)
        context.fillEllipse(
            in: CGRect(x: -15 * unit, y: -6 * unit, width: 30 * unit, height: 12 * unit))
        context.restoreGState()

        context.setFillColor(NSColor(srgbRed: 0.957, green: 0.945, blue: 0.910, alpha: 1).cgColor)
        context.fillEllipse(
            in: CGRect(
                x: 64.8 * unit, y: (128 - 54.2) * unit, width: 6.4 * unit, height: 6.4 * unit))

        // The clicks, kept inside the tile so they never crop.
        context.setStrokeColor(
            NSColor(srgbRed: 0.706, green: 0.384, blue: 0.227, alpha: 1).cgColor)
        context.setLineCap(.round)
        context.setLineWidth(4.4 * unit)
        for (radius, alpha) in [(13.0, 1.0), (22.0, 0.42)] {
            context.setAlpha(alpha)
            context.beginPath()
            let centre = point(98 - CGFloat(radius) / 2, 56)
            context.addArc(
                center: centre, radius: CGFloat(radius) * unit,
                startAngle: -.pi / 2.4, endAngle: .pi / 2.4, clockwise: false)
            context.strokePath()
        }
        context.setAlpha(1)
        context.restoreGState()
    }
}
