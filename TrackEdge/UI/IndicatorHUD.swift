import AppKit
import SwiftUI

/// TrackEdge's on-screen indicator, shown bottom-centre above the Dock.
///
/// One panel serves every kind of feedback so they never stack: volume/brightness levels (the default
/// "TrackEdge" indicator style) and Media Strip results (macOS shows no HUD for media keys at all).
/// It follows the system appearance and never takes focus or mouse input.
@MainActor
final class IndicatorHUD {
    static let shared = IndicatorHUD()

    private var panel: NSPanel?
    private var hosting: NSHostingView<IndicatorHUDView>?
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: IndicatorHUDView.width, height: IndicatorHUDView.height)

    struct Content: Equatable {
        let symbol: String
        let title: String
        var subtitle: String = ""
        /// 0...1 for volume/brightness; nil for media feedback.
        var level: Double?

        init(_ command: MediaCommand) {
            switch command {
            case .next: symbol = "forward.fill"; title = "Next Track"
            case .previous: symbol = "backward.fill"; title = "Previous Track"
            case .playPause: symbol = "playpause.fill"; title = "Play / Pause"
            }
            subtitle = "Media Strip"
        }

        init(_ event: PlaybackObserver.Event) {
            symbol = event.state == .playing ? "play.fill" : "pause.fill"
            title = event.state == .playing ? "Playing" : "Paused"
            subtitle = [event.title, event.app].compactMap { $0 }.joined(separator: " · ")
        }

        /// Volume or brightness level.
        init(level kind: SystemOSDController.Kind, value: Double) {
            let v = min(max(value, 0), 1)
            switch kind {
            case .brightness:
                symbol = v < 0.5 ? "sun.min.fill" : "sun.max.fill"
                title = "Brightness"
            case let .volume(muted):
                if muted || v == 0 {
                    symbol = "speaker.slash.fill"
                } else {
                    symbol = v < 0.34 ? "speaker.wave.1.fill" : (v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                }
                title = muted ? "Muted" : "Volume"
            }
            level = muted(kind) ? 0 : v
        }

        private func muted(_ kind: SystemOSDController.Kind) -> Bool {
            if case let .volume(m) = kind { return m }
            return false
        }

        /// Skip result with the song that is now playing; nil when the player didn't say.
        init?(skip command: MediaCommand, event: PlaybackObserver.Event) {
            guard command != .playPause, let song = event.title else { return nil }
            symbol = command == .next ? "forward.fill" : "backward.fill"
            title = song
            subtitle = [event.artist, event.app].compactMap { $0 }.joined(separator: " · ")
        }
    }

    func show(_ command: MediaCommand) {
        show(Content(command))
    }

    func show(_ content: Content) {
        let view = IndicatorHUDView(content: content)
        let panel = self.panel ?? makePanel()
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hosting
            self.hosting = hosting
        }

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let target = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 96)
        let wasVisible = panel.isVisible && panel.alphaValue > 0.5

        hideWork?.cancel()
        if wasVisible {
            // Repeated swipes just refresh the content in place.
            panel.setFrameOrigin(target)
        } else {
            panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - 8))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(target)
            }
        }

        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel?.animator().alphaValue = 0
            } completionHandler: {
                if panel?.alphaValue == 0 { panel?.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.panel = panel
        return panel
    }
}

struct IndicatorHUDView: View {
    static let width: CGFloat = 290
    static let height: CGFloat = 54

    let content: IndicatorHUD.Content

    private var symbol: String { content.symbol }
    private var title: String { content.title }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: 0xCC6267))
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
            if let level = content.level {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(StepMath.percent(level))%")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.14))
                            Capsule()
                                .fill(Color(hex: 0xCC6267))
                                .frame(width: max(level > 0 ? 6 : 0, geo.size.width * level))
                        }
                    }
                    .frame(height: 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(content.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.width, height: Self.height)
        .indicatorGlass(cornerRadius: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.level.map { "\(title) \(StepMath.percent($0)) percent" } ?? "\(title), \(content.subtitle)")
    }
}

private extension View {
    /// Liquid Glass on macOS 26+. Earlier systems get an always-active HUD blur: the indicator's panel
    /// never becomes key, and SwiftUI materials render flat and opaque in inactive windows.
    @ViewBuilder
    func indicatorGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(ActiveBlur().clipShape(shape))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

/// NSVisualEffectView pinned to the active state so it stays translucent in a non-key panel.
private struct ActiveBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
