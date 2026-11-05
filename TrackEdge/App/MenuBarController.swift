import AppKit
import Combine
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app.
final class PopoverPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Owns the status item and the single popover panel (dashboard ⇄ settings).
@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let settings: AppSettings
    private let navigation = PanelNavigation()
    private let statusItem: NSStatusItem
    private var panel: PopoverPanel?
    private var hosting: NSHostingView<PopoverRootView>?
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private lazy var diagnostics = DiagnosticsWindowController(model: model, settings: settings)

    /// Matches the reference popover height (~556 pt); grows only for optional content.
    private let baseHeight: CGFloat = 556

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = StatusItemIcon.make()
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = AppInfo.name
            button.setAccessibilityLabel(AppInfo.name)
        }

        settings.$appearance
            .sink { [weak self] mode in self?.applyAppearance(mode) }
            .store(in: &cancellables)
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Panel

    @objc private func togglePanel() {
        if isPanelVisible { closePanel() } else { showPanel() }
    }

    /// - Parameter pinned: development only; keeps the panel open when clicking elsewhere.
    func showPanel(page: PanelNavigation.Page = .dashboard, pinned: Bool = false) {
        let panel = self.panel ?? makePanel()
        navigation.page = page
        model.surfaceVisibilityChanged(true)
        layoutPanel()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        statusItem.button?.highlight(true)
        if !pinned { installOutsideClickMonitor() }
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        removeOutsideClickMonitor()
        statusItem.button?.highlight(false)
        panel.orderOut(nil)
        model.surfaceVisibilityChanged(false)
    }

    private func makePanel() -> PopoverPanel {
        let panel = PopoverPanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: baseHeight),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.onCancel = { [weak self] in self?.closePanel() }

        var actions = PanelActions()
        actions.openDiagnostics = { [weak self] in self?.openDiagnostics() }
        actions.about = { [weak self] in self?.showAbout() }
        actions.resetSettings = { [weak self] in self?.confirmReset() }
        actions.quit = { [weak self] in self?.quit() }

        let root = PopoverRootView(model: model, settings: settings, navigation: navigation, actions: actions, minimumHeight: baseHeight)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: baseHeight)
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        applyAppearance(settings.appearance)

        // Re-fit when content height changes (e.g. the Accessibility hint or nested row appears).
        Publishers.Merge3(model.objectWillChange.map { _ in () },
                          settings.objectWillChange.map { _ in () },
                          navigation.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.layoutPanel() }
            .store(in: &cancellables)
        return panel
    }

    private func layoutPanel() {
        guard let panel, let hosting, let button = statusItem.button, let buttonWindow = button.window else { return }
        let fitting = hosting.fittingSize
        let height = max(baseHeight, fitting.height)
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = buttonFrame.midX - Metrics.panelWidth / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Metrics.panelWidth - 8)
        let top = buttonFrame.minY - 6
        let frame = NSRect(x: x, y: top - height, width: Metrics.panelWidth, height: height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            hosting.frame = NSRect(origin: .zero, size: frame.size)
            panel.invalidateShadow()
        }
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        let appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        panel?.appearance = appearance
        panel?.invalidateShadow()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    // MARK: - Actions

    func openDiagnostics() {
        closePanel()
        diagnostics.show()
    }

    private func showAbout() {
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Trackpad edge gestures for brightness, volume and media.\nClean-room implementation; uses private macOS frameworks for direct distribution only.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
            .credits: credits,
        ])
    }

    private func confirmReset() {
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Reset all \(AppInfo.name) settings?"
        alert.informativeText = "Gesture, haptic and appearance preferences return to their defaults. Open at Login is not changed."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            settings.resetToDefaults()
        }
    }

    private func quit() {
        if model.activeSlide != nil {
            // Release the pointer before asking anything.
            model.engine.cancelAll()
            model.cursor.forceRelease()
            closePanel()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "A gesture is in progress"
            alert.informativeText = "Quit \(AppInfo.name) anyway?"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        closePanel()
        NSApp.terminate(nil)
    }
}
