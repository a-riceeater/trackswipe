// Renders TrackEdge's app icon into TrackEdge/Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/generate_icons.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let setURL = root.appendingPathComponent("TrackEdge/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: setURL, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with soft shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    let tile = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.42, green: 0.27, blue: 0.94, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    let gradient = NSGradient(colors: [NSColor(srgbRed: 0.56, green: 0.43, blue: 1.0, alpha: 1),
                                       NSColor(srgbRed: 0.33, green: 0.19, blue: 0.86, alpha: 1)])!
    gradient.draw(in: tile, angle: -60)

    // Trackpad outline.
    let padW = body.width * 0.64, padH = body.width * 0.46
    let pad = NSRect(x: body.midX - padW / 2, y: body.midY - padH / 2, width: padW, height: padH)
    let padPath = NSBezierPath(roundedRect: pad, xRadius: padW * 0.11, yRadius: padW * 0.11)
    NSColor.white.withAlphaComponent(0.16).setFill()
    padPath.fill()
    padPath.lineWidth = max(1, body.width * 0.035)
    NSColor.white.withAlphaComponent(0.95).setStroke()
    padPath.stroke()
    // Highlighted right edge bar + left edge hint.
    let barW = max(1, body.width * 0.055), barH = padH * 0.62
    let bar = NSBezierPath(roundedRect: NSRect(x: pad.maxX - barW - padW * 0.08, y: pad.midY - barH / 2, width: barW, height: barH),
                           xRadius: barW / 2, yRadius: barW / 2)
    NSColor.white.setFill()
    bar.fill()
    let hint = NSBezierPath(roundedRect: NSRect(x: pad.minX + padW * 0.08, y: pad.midY - barH * 0.3, width: barW, height: barH * 0.6),
                            xRadius: barW / 2, yRadius: barW / 2)
    NSColor.white.withAlphaComponent(0.45).setFill()
    hint.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(px).write(to: setURL.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: setURL.appendingPathComponent("Contents.json"))
let catalog = setURL.deletingLastPathComponent().appendingPathComponent("Contents.json")
try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!.write(to: catalog)
print("Wrote \(images.count) icons to \(setURL.path)")
