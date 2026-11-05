import AppKit
import SwiftUI

/// TrackEdge's own mark: a violet tile containing a trackpad outline with a highlighted right edge.
struct AppGlyph: View {
    var size: CGFloat = 18

    var body: some View {
        let corner = size * 0.26
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x8A6BFF), Color(hex: 0x5733E3)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: max(1, size * 0.065))
                .frame(width: size * 0.64, height: size * 0.48)
            Capsule()
                .fill(Color.white)
                .frame(width: max(1.2, size * 0.09), height: size * 0.3)
                .offset(x: size * 0.19)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum StatusItemIcon {
    /// Template image for the menu bar: trackpad outline with a bar along its right edge.
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let outline = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 3.75, width: 14.5, height: 10.5), xRadius: 2.6, yRadius: 2.6)
            outline.lineWidth = 1.5
            NSColor.black.setStroke()
            outline.stroke()
            let bar = NSBezierPath(roundedRect: NSRect(x: 11.6, y: 6.2, width: 2, height: 5.6), xRadius: 1, yRadius: 1)
            NSColor.black.setFill()
            bar.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        return image
    }
}
