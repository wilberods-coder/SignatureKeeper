import AppKit

@main
struct IconBuilder {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let icons: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
        ]
        for (name, size) in icons {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Icon context") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let transform = AffineTransform(scale: CGFloat(size) / 1024)
            (transform as NSAffineTransform).concat()
            let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 202, yRadius: 202)
            let gradient = NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.59, blue: 0.33, alpha: 1),
                                      ending: NSColor(srgbRed: 0.26, green: 0.86, blue: 0.49, alpha: 1))!
            gradient.draw(in: tile, angle: 90)
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 276, y: 512))
            check.line(to: NSPoint(x: 448, y: 346))
            check.line(to: NSPoint(x: 751, y: 684))
            check.lineWidth = 100
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
        }
    }
}
