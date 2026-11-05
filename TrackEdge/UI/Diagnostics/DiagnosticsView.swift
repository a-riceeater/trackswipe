import AppKit
import SwiftUI

@MainActor
final class DiagnosticsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let settings: AppSettings
    private var window: NSWindow?

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "\(AppInfo.name) Diagnostics"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = NSSize(width: 480, height: 420)
            window.contentViewController = NSHostingController(rootView: DiagnosticsView(model: model, settings: settings))
            window.center()
            self.window = window
        }
        let wasVisible = window?.isVisible ?? false
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if !wasVisible { model.surfaceVisibilityChanged(true) }
    }

    func windowWillClose(_ notification: Notification) {
        model.surfaceVisibilityChanged(false)
    }
}

/// Actionable diagnostics: subsystem status, permissions, backend self-tests, and the opt-in
/// developer Touch Inspector used to validate coordinate orientation and gesture decisions on hardware.
struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var testResult = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusSection
                permissionsSection
                devicesSection
                testsSection
                inspectorSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: Sections

    private var statusSection: some View {
        GroupBox(label: Label("Status", systemImage: "waveform.path.ecg")) {
            VStack(alignment: .leading, spacing: 6) {
                row("Overall", "\(model.health.title) — \(model.health.detail)")
                row("Multitouch", providerDescription)
                row("Volume", volumeDescription)
                row("Brightness", brightnessDescription)
                row("Level route", model.volumeRoute.rawValue)
                row("Feedback", model.volumeRoute == .systemKeys ? "Apple HUD (via hardware key events)" : model.osd.route.rawValue)
                row("Media route", model.mediaRoute.rawValue)
                row("Haptics", model.hapticSupport.description)
                row("Open at Login", model.loginItem.description)
                row("Live modifiers", modifierDescription(model.liveModifiers))
            }
            .padding(6)
        }
    }

    private var permissionsSection: some View {
        GroupBox(label: Label("Permissions", systemImage: "lock.shield")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility — \(model.accessibilityTrusted ? "Granted" : "Not granted")").bold()
                        Text("Lets \(AppInfo.name) press the system volume, brightness and media keys so macOS shows its own HUD. Without it, levels are written directly and media uses MediaRemote.")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !model.accessibilityTrusted {
                        Button("Request…") { model.requestAccessibility() }
                    }
                    Button("Open Settings") { PermissionsController.openAccessibilitySettings() }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Input Monitoring — \(model.inputMonitoring.rawValue)").bold()
                        Text("Not required on the macOS versions tested. If touches never reach the inspector below, grant it and relaunch.")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Settings") { PermissionsController.openInputMonitoringSettings() }
                }
                HStack {
                    Spacer()
                    Button("Refresh") { model.refreshAll() }
                    Button("Restart Trackpads") { model.restartTrackpads() }
                }
            }
            .padding(6)
        }
    }

    private var devicesSection: some View {
        GroupBox(label: Label("Trackpads", systemImage: "rectangle.and.hand.point.up.left")) {
            VStack(alignment: .leading, spacing: 6) {
                if model.trackpads.isEmpty {
                    Text("No multitouch trackpad detected.").foregroundColor(.secondary)
                }
                ForEach(model.trackpads) { device in
                    row(device.name, String(format: "%@ · %.1f × %.1f mm · family %d · %@", device.kindDescription,
                                            device.widthMM, device.heightMM, device.familyID,
                                            model.haptics.support(for: device.id).description))
                }
            }
            .padding(6)
        }
    }

    private var testsSection: some View {
        GroupBox(label: Label("Backend self-test", systemImage: "checkmark.seal")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Exercise each real system control without any gesture.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Button("Volume −") { test { runLevel(model.volumeService, steps: -1, name: "Volume") } }
                    Button("Volume +") { test { runLevel(model.volumeService, steps: 1, name: "Volume") } }
                    Button("Mute") { test { model.volumeService.toggleMute() ? "Toggled mute" : "Mute unavailable" } }
                    Button("Brightness −") { test { runLevel(model.brightnessService, steps: -1, name: "Brightness") } }
                    Button("Brightness +") { test { runLevel(model.brightnessService, steps: 1, name: "Brightness") } }
                }
                HStack {
                    Button("Previous") { test { model.sendMedia(.previous) ? "Sent previous" : "Media unavailable" } }
                    Button("Play/Pause") { test { model.sendMedia(.playPause) ? "Sent play/pause" : "Media unavailable" } }
                    Button("Next") { test { model.sendMedia(.next) ? "Sent next" : "Media unavailable" } }
                    Button("Haptic") {
                        test {
                            model.haptics.perform(settings.hapticStrength, on: nil)
                            return "Haptic (\(settings.hapticStrength.title)) — rest a finger on the trackpad to feel it"
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text("Haptic waveforms:").font(.caption)
                    ForEach([Int32(1), 2, 3, 4, 5, 6], id: \.self) { id in
                        Button("\(id)") {
                            test {
                                model.haptics.test(actuationID: id)
                                return "Waveform \(id) — rest a finger on the trackpad to feel it (current mapping in HapticEngine.waveforms)"
                            }
                        }
                    }
                }
                if !testResult.isEmpty {
                    Text(testResult).font(.caption.monospaced()).foregroundColor(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var inspectorSection: some View {
        GroupBox(label: Label("Developer: Touch Inspector", systemImage: "hand.point.up.braille")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show live contacts and gesture decisions (off by default; nothing is logged to disk)", isOn: $settings.inspectorEnabled)
                Toggle("Invert Y axis (only if the inspector shows top and bottom swapped)", isOn: $settings.invertY)
                if settings.inspectorEnabled {
                    TouchInspectorView(snapshot: model.inspector, edgeWidth: settings.edgeWidth,
                                       bottomQuarter: settings.bottomQuarterOnly)
                        .frame(height: 230)
                    if !model.commandLog.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.commandLog, id: \.self) { line in
                                Text(line).font(.caption.monospaced())
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: Helpers

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundColor(.secondary).frame(width: 120, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }

    private func test(_ body: () -> String) {
        testResult = body()
        model.refreshAll()
    }

    private func runLevel(_ service: LevelControlling, steps: Int, name: String) -> String {
        service.beginAdjust()
        defer { service.endAdjust() }
        guard let result = service.adjust(steps: steps, fine: false) else { return "\(name) unavailable" }
        return "\(name) → \(StepMath.percent(result.value))%\(result.changed ? "" : " (at limit)")"
    }

    private var providerDescription: String {
        switch model.providerState {
        case .stopped: return "Stopped"
        case let .unavailable(reason): return reason
        case .noDevices: return "No trackpad"
        case let .running(count): return "Running on \(count) device\(count == 1 ? "" : "s")"
        }
    }

    private var volumeDescription: String {
        let v = model.volume
        guard v.deviceID != 0 else { return "No default output device" }
        var parts = [v.deviceName]
        if let level = v.volume { parts.append("\(StepMath.percent(level))%") } else { parts.append("no volume control") }
        if !v.canSetVolume { parts.append("not settable") }
        if v.muted { parts.append("muted") }
        if !v.hasMute { parts.append("no hardware mute") }
        return parts.joined(separator: " · ")
    }

    private var brightnessDescription: String {
        let b = model.brightness
        guard let level = b.brightness else { return "\(b.displayName) — not controllable (DDC/CI monitors unsupported)" }
        return "\(b.displayName) · \(StepMath.percent(level))%"
    }

    private func modifierDescription(_ m: ModifierState) -> String {
        var keys: [String] = []
        if m.function { keys.append("fn/🌐") }
        if m.control { keys.append("⌃") }
        if m.option { keys.append("⌥") }
        if m.shift { keys.append("⇧") }
        if m.command { keys.append("⌘") }
        return keys.isEmpty ? "none (hold keys to verify Fn/Globe detection)" : keys.joined(separator: " ")
    }
}

/// Draws the trackpad surface with the configured zones and live contacts.
struct TouchInspectorView: View {
    let snapshot: InspectorSnapshot?
    let edgeWidth: Double
    let bottomQuarter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let config = snapshot?.config ?? GestureConfig()
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12))
                    // Edge zones
                    let edgeTop = bottomQuarter ? h * config.bottomQuarterBoundary : 0
                    Rectangle().fill(Color.orange.opacity(0.22))
                        .frame(width: w * edgeWidth, height: h - edgeTop)
                        .offset(y: edgeTop)
                    Rectangle().fill(Color.blue.opacity(0.22))
                        .frame(width: w * edgeWidth, height: h - edgeTop)
                        .offset(x: w * (1 - edgeWidth), y: edgeTop)
                    // Mute corner
                    Rectangle().fill(Color.red.opacity(0.18))
                        .frame(width: w * config.muteCornerWidth, height: h * config.muteCornerHeight)
                        .offset(x: w * (1 - config.muteCornerWidth))
                    // Media strip
                    Rectangle().fill(Color.pink.opacity(0.2))
                        .frame(width: w, height: h * (1 - config.stripTop))
                        .offset(y: h * config.stripTop)
                    Text("TOP (far from you)").font(.caption2).foregroundColor(.secondary).padding(4)
                    ForEach(snapshot?.contacts ?? [], id: \.id) { contact in
                        ZStack {
                            Circle().fill(contact.isTouching ? Color.accentColor : Color.gray.opacity(0.5))
                            Text("\(contact.id)").font(.caption2.bold()).foregroundColor(.white)
                        }
                        .frame(width: 22, height: 22)
                        .position(x: contact.x * w, y: contact.y * h)
                    }
                }
            }
            .aspectRatio((snapshot?.config.surfaceWidthMM ?? 100) / (snapshot?.config.surfaceHeightMM ?? 70), contentMode: .fit)
            if let s = snapshot {
                Text("\(s.deviceName) · state: \(s.state) · button: \(s.buttonDown ? "down" : "up")"
                     + (s.secondsSinceKeyDown < s.config.typingGuard ? " · typing guard ON" : ""))
                    .font(.caption.monospaced())
                ForEach(s.contacts, id: \.id) { c in
                    Text(String(format: "#%d  x=%.3f  y=%.3f  size=%.1f  %@", c.id, c.x, c.y, c.size, c.isTouching ? "touching" : "hover/lift"))
                        .font(.caption.monospaced())
                }
            } else {
                Text("Touch the trackpad to see contacts.").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
