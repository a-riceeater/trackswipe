import AppKit
import Combine
import os

/// Composition root and main-actor observable state for the UI.
///
/// Owns every service, wires settings into the gesture engine live, keeps the dashboard's numbers in
/// sync with the OS (CoreAudio listeners; brightness polled only while a window is visible), and
/// handles lifecycle recovery: sleep/wake, session switches, trackpad hot-plug and termination.
@MainActor
final class AppModel: ObservableObject {
    enum Health: Equatable {
        case starting
        case ready
        case attention(String)
        case noTrackpad
        case paused
        case unavailable(String)

        var title: String {
            switch self {
            case .starting: return "Starting"
            case .ready: return "Ready"
            case .attention: return "Limited"
            case .noTrackpad: return "No Trackpad"
            case .paused: return "Paused"
            case .unavailable: return "Unavailable"
            }
        }

        var detail: String {
            switch self {
            case .starting: return "Connecting to the trackpad…"
            case .ready: return "Edge gestures are active."
            case let .attention(reason): return reason
            case .noTrackpad: return "No multitouch trackpad found. Connect a Magic Trackpad or open the lid."
            case .paused: return "Paused while the Mac sleeps or another user is active."
            case let .unavailable(reason): return reason
            }
        }
    }

    let settings: AppSettings

    // MARK: Services
    let audio = AudioController()
    let display = DisplayBrightnessController()
    let keys = SystemKeyEmitter()
    let osd = SystemOSDController()
    let cursor = CursorManager()
    let haptics = HapticEngine()
    let volumeService: VolumeService
    let brightnessService: BrightnessService
    let media: MediaController
    let dispatcher: ActionDispatcher
    let engine: GestureEngine
    private let provider = MultitouchProvider.shared
    private var deviceWatcher: DeviceWatcher?

    // MARK: Published state
    @Published private(set) var volume = AudioController.Snapshot()
    @Published private(set) var brightness = DisplayBrightnessController.Snapshot()
    @Published private(set) var trackpads: [TrackpadDevice] = []
    @Published private(set) var providerState: MultitouchProvider.State = .stopped
    @Published private(set) var accessibilityTrusted = PermissionsController.accessibilityTrusted
    @Published private(set) var inputMonitoring = PermissionsController.inputMonitoring
    @Published private(set) var loginItem = LoginItemController.status
    @Published private(set) var activeSlide: SlideTarget?
    @Published private(set) var hapticSupport = HapticEngine.Support.unsupported
    @Published private(set) var liveModifiers = ModifierState.none
    @Published private(set) var inspector: InspectorSnapshot?
    @Published private(set) var commandLog: [String] = []
    @Published private(set) var isSuspended = false

    private var visibleSurfaces = 0
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "App")

    init(settings: AppSettings) {
        self.settings = settings
        volumeService = VolumeService(audio: audio, keys: keys, osd: osd)
        brightnessService = BrightnessService(display: display, keys: keys, osd: osd)
        media = MediaController(keys: keys)
        dispatcher = ActionDispatcher(volume: volumeService, brightness: brightnessService, media: media, haptics: haptics, cursor: cursor)
        engine = GestureEngine(dispatcher: dispatcher)
    }

    // MARK: - Lifecycle

    func start() {
        // Recover from any previous crash that might have left association off.
        cursor.forceRelease()

        dispatcher.onLevelChanged = { [weak self] target, _ in
            Task { @MainActor in self?.refreshLevel(target) }
        }
        dispatcher.onSlideStateChanged = { [weak self] target in
            Task { @MainActor in self?.activeSlide = target }
        }
        audio.onChange = { [weak self] in
            Task { @MainActor in self?.refreshVolume() }
        }
        audio.startObserving()

        provider.frameHandler = { [weak engine] device, contacts, timestamp in
            engine?.handle(device: device, contacts: contacts, timestamp: timestamp)
        }

        applySettings()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)

        startTrackpads()
        deviceWatcher = DeviceWatcher { [weak self] in
            self?.log.info("Multitouch device change detected; re-enumerating")
            self?.restartTrackpads()
        }
        deviceWatcher?.start()

        observeWorkspace()
        refreshAll()
    }

    func shutdown() {
        engine.cancelAll()
        provider.stop()
        cursor.forceRelease()
        audio.stopObserving()
        deviceWatcher?.stop()
        pollTimer?.invalidate()
    }

    // MARK: - Settings → engine

    private func applySettings() {
        engine.update(config: settings.gestureConfig, invertY: settings.invertY)
        dispatcher.options = ActionDispatcher.Options(freezeCursor: settings.freezeCursor, haptics: settings.hapticStrength)
        setInspectorEnabled(settings.inspectorEnabled && visibleSurfaces > 0)
    }

    func setInspectorEnabled(_ enabled: Bool) {
        if enabled {
            engine.setInspector { [weak self] snapshot in
                MainActor.assumeIsolated { self?.inspector = snapshot }
            }
            dispatcher.onCommand = { [weak self] command in
                Task { @MainActor in self?.appendLog(command) }
            }
        } else {
            engine.setInspector(nil)
            dispatcher.onCommand = nil
            inspector = nil
            commandLog.removeAll()
        }
    }

    private func appendLog(_ command: GestureCommand) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        commandLog.insert("\(formatter.string(from: Date()))  \(Self.describe(command))", at: 0)
        if commandLog.count > 14 { commandLog.removeLast(commandLog.count - 14) }
    }

    static func describe(_ command: GestureCommand) -> String {
        switch command {
        case let .slideBegan(t): return "slide began · \(t.rawValue)"
        case let .adjust(t, steps, fine): return "\(t.rawValue) \(steps > 0 ? "+" : "")\(steps)\(fine ? " (¼)" : "")"
        case let .slideEnded(t): return "slide ended · \(t.rawValue)"
        case .toggleMute: return "toggle mute"
        case let .media(m): return "media · \(m.rawValue)"
        }
    }

    // MARK: - Trackpads

    private func startTrackpads() {
        let state = provider.start()
        providerState = state
        trackpads = provider.devices
        haptics.configure(devices: trackpads)
        hapticSupport = haptics.overallSupport
        engine.retainDevices(Set(trackpads.map(\.id)))
        log.info("Multitouch state: \(String(describing: state), privacy: .public)")
    }

    func restartTrackpads() {
        engine.cancelAll()
        guard !isSuspended else { return }
        startTrackpads()
    }

    private func suspend(_ reason: String) {
        guard !isSuspended else { return }
        log.info("Suspending: \(reason, privacy: .public)")
        isSuspended = true
        engine.cancelAll()
        cursor.forceRelease()
        provider.stop()
        providerState = .stopped
    }

    private func resume(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isSuspended else { return }
            self.isSuspended = false
            self.startTrackpads()
            self.refreshAll()
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let add: (Notification.Name, @escaping @MainActor () -> Void) -> Void = { name, handler in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            self.workspaceObservers.append(token)
        }
        add(NSWorkspace.willSleepNotification) { [weak self] in self?.suspend("sleep") }
        add(NSWorkspace.didWakeNotification) { [weak self] in self?.resume(after: 1.5) }
        add(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.suspend("session inactive") }
        add(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.resume(after: 0.5) }
        add(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.engine.cancelAll() }

        let token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBrightness() }
        }
        workspaceObservers.append(token)
    }

    // MARK: - Visibility-scoped polling

    /// Call when the popover or Diagnostics window appears/disappears. Brightness and permission
    /// polling run only while something is on screen, so the idle app uses no timers.
    func surfaceVisibilityChanged(_ visible: Bool) {
        visibleSurfaces = max(0, visibleSurfaces + (visible ? 1 : -1))
        if visibleSurfaces > 0 {
            refreshAll()
            if pollTimer == nil {
                let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.poll() }
                }
                RunLoop.main.add(timer, forMode: .common)
                pollTimer = timer
            }
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        setInspectorEnabled(settings.inspectorEnabled && visibleSurfaces > 0)
    }

    private func poll() {
        refreshBrightness()
        refreshPermissions()
        liveModifiers = ModifierMonitor.current()
    }

    // MARK: - Refresh

    func refreshAll() {
        refreshVolume()
        refreshBrightness()
        refreshPermissions()
        loginItem = LoginItemController.status
    }

    func refreshVolume() {
        let snap = audio.snapshot()
        if snap != volume { volume = snap }
    }

    func refreshBrightness() {
        let snap = display.snapshot()
        if snap != brightness { brightness = snap }
    }

    private func refreshLevel(_ target: SlideTarget) {
        switch target {
        case .volume:
            refreshVolume()
            // The key route applies asynchronously; read again once macOS has processed it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.refreshVolume() }
        case .brightness:
            refreshBrightness()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.refreshBrightness() }
        }
    }

    func refreshPermissions() {
        let trusted = PermissionsController.accessibilityTrusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        let monitoring = PermissionsController.inputMonitoring
        if monitoring != inputMonitoring { inputMonitoring = monitoring }
        let login = LoginItemController.status
        if login != loginItem { loginItem = login }
    }

    // MARK: - Actions

    func setOpenAtLogin(_ enabled: Bool) {
        loginItem = LoginItemController.setEnabled(enabled)
    }

    func requestAccessibility() {
        PermissionsController.requestAccessibility()
        PermissionsController.openAccessibilitySettings()
    }

    // MARK: - Derived status

    var health: Health {
        if isSuspended { return .paused }
        switch providerState {
        case .stopped: return .starting
        case let .unavailable(reason): return .unavailable(reason)
        case .noDevices: return .noTrackpad
        case .running:
            if !volume.isAvailable && !brightness.isAvailable {
                return .attention("No controllable output device or display.")
            }
            if !brightness.isAvailable {
                return .attention("Brightness: \(brightness.displayName). Volume gestures are active.")
            }
            if !volume.isAvailable {
                return .attention("Volume: output device unavailable. Brightness gestures are active.")
            }
            return .ready
        }
    }

    var volumeRoute: ControlRoute { accessibilityTrusted ? .systemKeys : .direct }
    var mediaRoute: MediaController.Route { media.route }
}
