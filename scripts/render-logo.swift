import AppKit

@main
struct RenderLogo {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: render-logo <output-directory>")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for size in [16, 32, 128, 256, 512] {
            try png(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
            try png(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
        try png(size: 1024).write(to: output.appendingPathComponent("logo.png"))
        try png(size: 512).write(to: output.appendingPathComponent("logo-preview.png"))

        let vector = LogoView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        try vector.dataWithPDF(inside: vector.bounds).write(to: output.appendingPathComponent("logo.pdf"))
        print("Logo PNG, vector PDF, and iconset: \(output.path)")
    }

    private static func png(size: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                           bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(size))
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        BrandArtwork.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}

private final class LogoView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { BrandArtwork.draw(in: bounds) }
}
