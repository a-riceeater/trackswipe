import AppKit
import os

/// On-screen feedback for the *direct-write* route (used only when Accessibility is not granted;
/// with Accessibility, `SystemKeyEmitter` makes macOS show its own HUD and this class is not used).
///
/// - macOS 13–15: PRIVATE `OSD.framework` `OSDManager` draws Apple's real HUD for a value we set.
/// - macOS 26+: `OSDManager` still resolves but no longer renders anything (verified on 26.6), so a
///   small, clearly app-branded fallback indicator is shown instead. It never claims to be Apple's HUD.
final class SystemOSDController {
    enum Route: String, Sendable {
        case privateOSD = "Apple HUD (OSDManager)"
        case fallback = "TrackEdge indicator (fallback)"
    }

    enum Kind {
        case volume(muted: Bool)
        case brightness
    }

    private typealias ShowFn = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void

    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "OSD")
    private var lastShown: CFAbsoluteTime = 0

    private static let osd: (manager: NSObject, selector: Selector, show: ShowFn)? = {
        guard #unavailable(macOS 26) else { return nil }
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/OSD.framework"), bundle.load(),
              let cls = NSClassFromString("OSDManager") as? NSObject.Type,
              let manager = cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        let selector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
        guard manager.responds(to: selector), let imp = manager.method(for: selector) else { return nil }
        return (manager, selector, unsafeBitCast(imp, to: ShowFn.self))
    }()

    var route: Route { Self.osd != nil ? .privateOSD : .fallback }

    /// Shows feedback for a new value. Throttled to ~30 Hz; safe to call from any thread.
    func show(_ kind: Kind, value: Double, display: CGDirectDisplayID? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastShown > 0.033 else { return }
        lastShown = now
        let clamped = min(max(value, 0), 1)
        if let osd = Self.osd {
            // OSDGraphic: 1 = backlight, 3 = speaker, 4 = speaker muted. 64 chiclets keeps quarter steps visible.
            let image: Int64
            switch kind {
            case .brightness: image = 1
            case let .volume(muted): image = muted || clamped == 0 ? 4 : 3
            }
            let filled = UInt32((clamped * 64).rounded())
            osd.show(osd.manager, osd.selector, image, display ?? CGMainDisplayID(), 0x1F4, 1000, filled, 64, false)
            return
        }
        Task { @MainActor in
            FallbackHUD.shared.show(kind: kind, value: clamped)
        }
    }
}

/// Minimal, app-branded level indicator used only when no native HUD route exists.
@MainActor
final class FallbackHUD {
    static let shared = FallbackHUD()

    private var panel: NSPanel?
    private var hosting: NSHostingView<FallbackHUDView>?
    private var hideWork: DispatchWorkItem?

    func show(kind: SystemOSDController.Kind, value: Double) {
        let symbol: String
        let label: String
        switch kind {
        case .brightness:
            symbol = "sun.max.fill"
            label = "Brightness"
        case let .volume(muted):
            symbol = muted || value == 0 ? "speaker.slash.fill" : (value < 0.34 ? "speaker.wave.1.fill" : (value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
            label = muted ? "Muted" : "Volume"
        }
        let view = FallbackHUDView(symbol: symbol, label: label, value: value)
        let panel = self.panel ?? makePanel()
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 220, height: 64)
            panel.contentView = hosting
            self.hosting = hosting
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 110, y: frame.minY + 96))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel?.animator().alphaValue = 0
            } completionHandler: {
                panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.panel = panel
        return panel
    }
}

import SwiftUI

struct FallbackHUDView: View {
    let symbol: String
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    (Text(label) + Text("  \(AppInfo.name)").foregroundColor(.secondary))
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(StepMath.percent(value))%").font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(Color.primary.opacity(0.85)).frame(width: max(0, geo.size.width * value))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 220, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AppInfo.name) \(label) \(StepMath.percent(value)) percent")
    }
}
