import AppKit
import SwiftUI

/// Brief on-screen confirmation for Media Strip gestures. macOS shows no HUD for media keys, so this
/// fills the gap. It sits bottom-centre above the Dock, in the same spot as TrackEdge's level indicator,
/// follows the system appearance and never takes focus or mouse input.
@MainActor
final class MediaHUD {
    static let shared = MediaHUD()

    private var panel: NSPanel?
    private var hosting: NSHostingView<MediaHUDView>?
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: MediaHUDView.width, height: MediaHUDView.height)

    struct Content: Equatable {
        let symbol: String
        let title: String
        let subtitle: String

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
        let view = MediaHUDView(content: content)
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

struct MediaHUDView: View {
    static let width: CGFloat = 290
    static let height: CGFloat = 54

    let content: MediaHUD.Content

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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.width, height: Self.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(content.subtitle)")
    }
}
