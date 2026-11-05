// Renders the DMG window background at 1x and 2x.
// Usage: swift scripts/dmg_background.swift <output-dir>
// Layout contract (points, top-left origin) shared with scripts/make_dmg.sh:
//   window content 640×400 · app icon centre (170, 200) · Applications centre (470, 200) · icon size 112
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size = NSSize(width: 640, height: 400)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // Flip to top-left origin so coordinates match Finder icon positions.
    ctx.cgContext.translateBy(x: 0, y: size.height)
    ctx.cgContext.scaleBy(x: 1, y: -1)

    // Soft blush wash.
    NSGradient(colors: [color(0xFFFAFA), color(0xFAEDEE)])!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color c: NSColor, y: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                     .foregroundColor: c, .paragraphStyle: style]
        NSAttributedString(string: string, attributes: attrs).draw(in: NSRect(x: 0, y: y, width: 640, height: size * 1.5))
    }
    // Text is drawn unflipped, so temporarily undo the flip for each string.
    func drawText(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        ctx.cgContext.translateBy(x: 0, y: size.height)
        ctx.cgContext.scaleBy(x: 1, y: -1)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Arrow from app → Applications.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 252, y: 200))
    arrow.line(to: NSPoint(x: 384, y: 200))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    color(0xCC6267).setStroke()
    let dashes: [CGFloat] = [0.1, 11]
    arrow.setLineDash(dashes, count: 2, phase: 0)
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 376, y: 188))
    head.line(to: NSPoint(x: 390, y: 200))
    head.line(to: NSPoint(x: 376, y: 212))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    drawText {
        // Unflipped coordinates: y measured from the bottom.
        text("Install TrackEdge", size: 22, weight: .semibold, color: color(0x1C1C1E), y: 400 - 64)
        text("Drag TrackEdge into Applications to install", size: 13, weight: .regular,
             color: color(0x4E4E55), y: 400 - 358)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try render(scale: 1).write(to: outDir.appendingPathComponent("background.png"))
try render(scale: 2).write(to: outDir.appendingPathComponent("background@2x.png"))
print("Rendered DMG background to \(outDir.path)")
