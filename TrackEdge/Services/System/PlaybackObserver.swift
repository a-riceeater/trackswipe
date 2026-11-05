import Foundation

/// Learns the real result of media commands (play/pause state, the track now playing) without any permission.
///
/// macOS 15.4+ blocks third-party apps from reading Now Playing state through MediaRemote (verified on
/// macOS 26: it returns no app and no info). Spotify and Apple Music, however, broadcast every playback
/// change as a public distributed notification. After TrackEdge sends play/pause it waits briefly for
/// one of those broadcasts; if none arrives (browsers, other players) the caller falls back to a
/// neutral "Play / Pause" label instead of guessing.
@MainActor
final class PlaybackObserver {
    struct Event: Equatable {
        enum State: Equatable { case playing, paused }
        let app: String
        let state: State
        /// Track now playing, when the player includes it (Spotify and Music both send Name/Artist).
        let title: String?
        let artist: String?
        let date: Date
    }

    private static let sources: [(name: Notification.Name, app: String)] = [
        (Notification.Name("com.spotify.client.PlaybackStateChanged"), "Spotify"),
        (Notification.Name("com.apple.Music.playerInfo"), "Music"),
        (Notification.Name("com.apple.iTunes.playerInfo"), "iTunes"),
    ]

    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    private var lastEvent: Event?
    private var waiters: [(after: Date, completion: (Event?) -> Void)] = []

    /// `center` is injectable so tests never broadcast fake player notifications system-wide.
    init(center: NotificationCenter = DistributedNotificationCenter.default()) {
        self.center = center
        for source in Self.sources {
            let token = center.addObserver(forName: source.name, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo
                let rawState = info?["Player State"] as? String
                let title = (info?["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let artist = (info?["Artist"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                MainActor.assumeIsolated {
                    self?.record(app: source.app, rawState: rawState, title: title, artist: artist)
                }
            }
            tokens.append(token)
        }
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }

    /// Calls back with the first playback change reported at or after `date`, or nil after `timeout`.
    func waitForChange(after date: Date, timeout: TimeInterval, completion: @escaping (Event?) -> Void) {
        if let lastEvent, lastEvent.date >= date {
            completion(lastEvent)
            return
        }
        waiters.append((date, completion))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            let pending = self.waiters.filter { $0.after == date }
            self.waiters.removeAll { $0.after == date }
            pending.forEach { $0.completion(nil) }
        }
    }

    private func record(app: String, rawState: String?, title: String?, artist: String?) {
        let state: Event.State
        switch rawState {
        case "Playing": state = .playing
        case "Paused", "Stopped": state = .paused
        default: return
        }
        let event = Event(app: app, state: state, title: title, artist: artist, date: Date())
        lastEvent = event
        let ready = waiters.filter { $0.after <= event.date }
        waiters.removeAll { $0.after <= event.date }
        ready.forEach { $0.completion(event) }
    }
}
