import AppKit
import Combine
import Sparkle

/// Sparkle 2 auto-updates.
///
/// - Feed: `SUFeedURL` in Info.plist (the repo's `appcast.xml`); archives are GitHub release assets.
/// - Every archive is verified against `SUPublicEDKey` (EdDSA) *and* must carry the same Developer ID
///   signature as the running app before Sparkle installs it.
/// - Scheduled checks run once a day (`SUScheduledCheckInterval`). Because TrackEdge is a menu-bar app
///   with no Dock icon, scheduled updates use Sparkle's "gentle reminder" mode and bring the app forward
///   so the update window isn't hidden behind other apps.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false

    private var controller: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()

    /// - Parameter start: false in unit tests so no network checks run.
    init(start: Bool) {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecks = $0 }
            .store(in: &cancellables)
    }

    var updater: SPUUpdater { controller.updater }

    /// User-initiated check: always shows a result (update found, up to date, or error).
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    var lastCheckDescription: String {
        guard let date = updater.lastUpdateCheckDate else { return "Never" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}

extension UpdateController: SPUUpdaterDelegate {
    #if DEBUG
    /// `-debugFeedURL http://localhost:8000/appcast.xml` points a development build at a local test feed.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "debugFeedURL")
    }
    #endif
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        // A menu-bar app isn't active by default; bring the update window to the front.
        guard handleShowingUpdate else { return }
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
}
