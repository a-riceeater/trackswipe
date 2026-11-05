import AppKit
import os

@main
enum TrackEdgeMain {
    /// Strong reference: `NSApplication.delegate` is weak.
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        // Menu-bar only: no Dock icon, no main window (also declared via LSUIElement).
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var menuBar: MenuBarController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app host; don't start hardware services or UI for them.
        guard !AppInfo.isRunningTests else { return }

        let settings = AppSettings()
        let model = AppModel(settings: settings)
        self.model = model
        model.start()
        let menuBar = MenuBarController(model: model, settings: settings)
        self.menuBar = menuBar
        installSignalHandlers()

        #if DEBUG
        if UserDefaults.standard.bool(forKey: "selfTest") {
            // A run-loop timer (not a main-queue block) so the test's nested run loop can still
            // drain main-actor work such as the fallback indicator.
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                MainActor.assumeIsolated { BackendSelfTest.run(model: model) }
                exit(0)
            }
            return
        }
        // `-debugMediaHUD next|previous|playPause` shows the media indicator at launch (no command is sent).
        if let raw = UserDefaults.standard.string(forKey: "debugMediaHUD") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if raw == "song" {
                    let sample = PlaybackObserver.Event(app: "Spotify", state: .playing,
                                                        title: "A Fairly Long Song Title (Extended Remix)",
                                                        artist: "Some Artist", date: Date())
                    if let content = MediaHUD.Content(skip: .next, event: sample) { MediaHUD.shared.show(content) }
                } else if let command = MediaCommand(rawValue: raw) {
                    MediaHUD.shared.show(command)
                }
            }
        }
        // Development aid for visual comparison: `-debugOpenPanel dashboard|settings` opens the popover at launch.
        if let page = UserDefaults.standard.string(forKey: "debugOpenPanel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                menuBar.showPanel(page: page == "settings" ? .settings : .dashboard, pinned: true)
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// SIGTERM/SIGINT (e.g. `killall`, logout) still restore the cursor before exiting.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.model?.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
