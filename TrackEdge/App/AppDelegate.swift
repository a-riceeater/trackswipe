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
        menuBar = MenuBarController(model: model, settings: settings)
        installSignalHandlers()
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
