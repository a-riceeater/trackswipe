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
    #if DEBUG
    /// `-forceDirectRoute YES` simulates a Mac without Accessibility to exercise the fallback routes.
    let keys = UserDefaults.standard.bool(forKey: "forceDirectRoute") ? SystemKeyEmitter(permissions: { false }) : SystemKeyEmitter()
    #else
    let keys = SystemKeyEmitter()
    #endif
    let indicatorPreference: IndicatorPreference
    let osd: SystemOSDController
    let cursor = CursorManager()
    let haptics = HapticEngine()
    let volumeService: VolumeService
    let brightnessService: BrightnessService
    let media: MediaController
    let dispatcher: ActionDispatcher
    let engine: GestureEngine
    private let provider = MultitouchProvider.shared
    private let playback = PlaybackObserver()
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
    private var distributedObservers: [NSObjectProtocol] = []
    /// Pending resume after wake / session switch; cancelled if the Mac suspends again first.
    private var resumeWork: DispatchWorkItem?
    /// Pending debounced trackpad reconnect (screen wake, unlock, post-wake check).
    private var restartWork: DispatchWorkItem?
    /// Keeps App Nap from throttling the main thread, which draws the on-screen indicator.
    private var appNapActivity: NSObjectProtocol?
    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "App")

    init(settings: AppSettings) {
        self.settings = settings
        let preference = IndicatorPreference()
        preference.useSystemHUD = settings.indicatorStyle == .system
        indicatorPreference = preference
        let osd = SystemOSDController(preference: preference)
        self.osd = osd
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

        // A menu-bar app with no visible window gets App Napped after a while, which delays the
        // main-thread indicator while the background level changes keep working. Opt out (sleep still allowed).
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Responding to trackpad edge gestures"
        )

        dispatcher.onLevelChanged = { [weak self] target, _ in
            Task { @MainActor in self?.refreshLevel(target) }
        }
        dispatcher.onMediaSent = { [weak self] command, sentAt in
            Task { @MainActor in self?.showMediaFeedback(command, sentAt: sentAt) }
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
        resumeWork?.cancel()
        restartWork?.cancel()
        if let appNapActivity { ProcessInfo.processInfo.endActivity(appNapActivity) }
        appNapActivity = nil
    }

    // MARK: - Settings → engine

    private func applySettings() {
        indicatorPreference.useSystemHUD = settings.indicatorStyle == .system
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
        case let .slideCancelled(t): return "slide undone (typing) · \(t.rawValue)"
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
        // A resume scheduled by an earlier wake must not fire into this new sleep (or right after the
        // next wake, before the trackpad is back), leaving stale device refs and no further restart.
        resumeWork?.cancel()
        resumeWork = nil
        restartWork?.cancel()
        restartWork = nil
        guard !isSuspended else { return }
        log.info("Suspending: \(reason, privacy: .public)")
        isSuspended = true
        engine.cancelAll()
        cursor.forceRelease()
        provider.stop()
        providerState = .stopped
    }

    private func resume(after delay: TimeInterval) {
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isSuspended else { return }
                self.resumeWork = nil
                self.log.info("Resuming")
                self.isSuspended = false
                IndicatorHUD.shared.reset()
                self.startTrackpads()
                self.refreshAll()
                // Trackpads can finish re-attaching after the first attempt; reconnect once more.
                self.scheduleRestart(after: 3.0, reason: "post-wake check")
            }
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Debounced reconnect to every trackpad. Used when the display wakes or the screen unlocks
    /// without a full system sleep, where MultitouchSupport device refs can still go stale.
    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isSuspended else { return }
                self.restartWork = nil
                self.log.info("Reconnecting trackpads: \(reason, privacy: .public)")
                self.restartTrackpads()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        add(NSWorkspace.activeSpaceDidChangeNotification) { IndicatorHUD.shared.activeSpaceChanged() }
        // Locking the screen or display sleep never posts willSleep, so reconnect when the display returns.
        add(NSWorkspace.screensDidWakeNotification) { [weak self] in
            IndicatorHUD.shared.reset()
            self?.scheduleRestart(after: 1.0, reason: "screens woke")
        }

        let token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                IndicatorHUD.shared.reset()
                self?.refreshBrightness()
            }
        }
        workspaceObservers.append(token)

        let unlock = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                IndicatorHUD.shared.reset()
                self?.scheduleRestart(after: 0.5, reason: "screen unlocked")
            }
        }
        distributedObservers.append(unlock)
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

    /// Sends a media command outside of gestures (Diagnostics) with the same on-screen feedback.
    @discardableResult
    func sendMedia(_ command: MediaCommand) -> Bool {
        let sentAt = Date()
        let ok = media.send(command)
        if ok { showMediaFeedback(command, sentAt: sentAt) }
        return ok
    }

    /// How long to keep listening for the player's broadcast. Spotify Connect (playing on another
    /// device) round-trips through Spotify's servers and often reports well after 0.8 s.
    private static let playbackReportWindow: TimeInterval = 3.0

    /// Next/previous show immediately, then update in place with the new song if Spotify/Music reports
    /// it. Play/pause waits up to 0.5 s for the resulting state ("Playing"/"Paused"), shows the neutral
    /// label if none arrived, and still updates in place if a late report comes in.
    private func showMediaFeedback(_ command: MediaCommand, sentAt: Date) {
        let after = sentAt.addingTimeInterval(-0.05)
        let logLatency: (PlaybackObserver.Event) -> Void = { [log] event in
            log.info("Playback report from \(event.app, privacy: .public) \(event.date.timeIntervalSince(sentAt), format: .fixed(precision: 2)) s after the command")
        }
        guard command == .playPause else {
            IndicatorHUD.shared.show(command)
            playback.waitForChange(after: after, timeout: Self.playbackReportWindow) { event in
                guard let event else { return }
                logLatency(event)
                if let content = IndicatorHUD.Content(skip: command, event: event) {
                    IndicatorHUD.shared.show(content)
                }
            }
            return
        }
        playback.waitForChange(after: after, timeout: 0.5) { [playback] event in
            if let event {
                logLatency(event)
                IndicatorHUD.shared.show(IndicatorHUD.Content(event))
            } else {
                IndicatorHUD.shared.show(.playPause)
                playback.waitForChange(after: after, timeout: Self.playbackReportWindow - 0.5) { late in
                    guard let late else { return }
                    logLatency(late)
                    IndicatorHUD.shared.show(IndicatorHUD.Content(late))
                }
            }
        }
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

    var volumeRoute: ControlRoute { settings.indicatorStyle == .system && accessibilityTrusted ? .systemKeys : .direct }
    var mediaRoute: MediaController.Route { media.route }
}
