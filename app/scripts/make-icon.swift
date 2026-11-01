// Renders the app icon (AppIcon.icns) with AppKit: a rounded tile with an aurora gradient
// (pink → violet → blue → teal), a soft centre glow and white sparkles. Run by build-app.sh:
//   swift scripts/make-icon.swift <output.icns>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.icns")
let iconset = output.deletingLastPathComponent().appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

/// A template symbol drawn white, in its own transparent image (so the tint only hits the glyph).
func color(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func whiteGlyph(_ name: String, pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }
    return NSImage(size: glyph.size, flipped: false) { rect in
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.setFill()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func render(_ px: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        // Standard macOS icon shape: the tile fills ~80% of the canvas, the rest is transparent margin.
        let tile = rect.insetBy(dx: px * 0.1, dy: px * 0.1)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)
        NSGradient(colors: [color(0xF857A6), color(0x7B5CFF), color(0x1FB6FF), color(0x2EE6C5)])!
            .draw(in: path, angle: 45)
        path.addClip()
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        NSGradient(starting: NSColor.white.withAlphaComponent(0.35), ending: .clear)!
            .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: tile.width * 0.45, options: [])
        guard let glyph = whiteGlyph("sparkles", pointSize: tile.width * 0.5) else { return false }
        let glyphRect = NSRect(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2,
                               width: glyph.size.width, height: glyph.size.height)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = px * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -px * 0.015)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(CGFloat(size)).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(CGFloat(size * 2)).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
guard task.terminationStatus == 0 else { exit(1) }
print("Wrote \(output.path)")
