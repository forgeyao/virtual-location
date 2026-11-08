import AppKit

/// Shared vector artwork for the sidebar, Dock, and exported brand assets.
enum BrandArtwork {
    private static let canvasSize: CGFloat = 1024

    static func image(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(in: rect)
            return true
        }
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.scaleX(by: 18 / 640, yBy: 18 / 640)
            transform.translateX(by: -192, yBy: -224)
            transform.concat()
            drawMark(color: .black, shadow: false)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "虚拟定位"
        return image
    }

    static func draw(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / canvasSize, yBy: rect.height / canvasSize)
        transform.concat()
        let shadowScale = min(rect.width, rect.height) / canvasSize

        // Resolve the same system teal used by the primary button in Aqua.
        // A fixed appearance keeps the installed app icon stable across themes.
        var teal = NSColor.systemTeal
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            teal = NSColor.systemTeal.usingColorSpace(.sRGB) ?? .systemTeal
        }
        let light = teal.blended(withFraction: 0.28, of: .white) ?? teal
        let deep = teal.blended(withFraction: 0.23, of: .black) ?? teal
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                                xRadius: 204, yRadius: 204)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 22 * shadowScale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * shadowScale)
        shadow.set()
        deep.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [light, teal, deep])?.draw(in: tile, angle: 55)
        NSColor.white.withAlphaComponent(0.24).setStroke()
        tile.lineWidth = 2
        tile.stroke()
        drawMark(color: .white, shadow: true, shadowScale: shadowScale)
    }

    private static func drawMark(color: NSColor, shadow: Bool, shadowScale: CGFloat = 1) {
        // A quiet landing orbit anchors the lifted navigation arrow.
        let farOrbit = NSBezierPath()
        farOrbit.move(to: NSPoint(x: 282, y: 710))
        farOrbit.curve(to: NSPoint(x: 742, y: 710),
                       controlPoint1: NSPoint(x: 282, y: 612),
                       controlPoint2: NSPoint(x: 742, y: 612))
        farOrbit.lineWidth = 24
        farOrbit.lineCapStyle = .round
        color.withAlphaComponent(0.30).setStroke()
        farOrbit.stroke()

        let nearOrbit = NSBezierPath()
        nearOrbit.move(to: NSPoint(x: 282, y: 710))
        nearOrbit.curve(to: NSPoint(x: 742, y: 710),
                        controlPoint1: NSPoint(x: 282, y: 808),
                        controlPoint2: NSPoint(x: 742, y: 808))
        nearOrbit.lineWidth = 24
        nearOrbit.lineCapStyle = .round
        color.withAlphaComponent(0.78).setStroke()
        nearOrbit.stroke()

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 728, y: 276))
        arrow.curve(to: NSPoint(x: 752, y: 300),
                    controlPoint1: NSPoint(x: 752, y: 266),
                    controlPoint2: NSPoint(x: 762, y: 276))
        arrow.line(to: NSPoint(x: 581, y: 686))
        arrow.curve(to: NSPoint(x: 548, y: 685),
                    controlPoint1: NSPoint(x: 572, y: 708),
                    controlPoint2: NSPoint(x: 557, y: 708))
        arrow.line(to: NSPoint(x: 496, y: 542))
        arrow.curve(to: NSPoint(x: 482, y: 528),
                    controlPoint1: NSPoint(x: 493, y: 534),
                    controlPoint2: NSPoint(x: 490, y: 531))
        arrow.line(to: NSPoint(x: 339, y: 476))
        arrow.curve(to: NSPoint(x: 338, y: 443),
                    controlPoint1: NSPoint(x: 316, y: 467),
                    controlPoint2: NSPoint(x: 316, y: 452))
        arrow.close()

        NSGraphicsContext.saveGraphicsState()
        if shadow {
            let lift = NSShadow()
            lift.shadowColor = NSColor(srgbRed: 0.02, green: 0.25, blue: 0.29, alpha: 0.18)
            lift.shadowBlurRadius = 16 * shadowScale
            lift.shadowOffset = NSSize(width: 0, height: -10 * shadowScale)
            lift.set()
        }
        color.setFill()
        arrow.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
