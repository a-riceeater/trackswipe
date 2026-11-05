import Foundation
import os

protocol MediaControlling: AnyObject {
    @discardableResult func send(_ command: MediaCommand) -> Bool
}

/// Global media commands that reach whatever app currently owns Now Playing (Music, Spotify, browsers…).
///
/// Route 1 (preferred): synthesised media keys — identical to pressing ⏮ ⏯ ⏭ on the keyboard.
///   Requires Accessibility.
/// Route 2 (fallback): PRIVATE `MediaRemote.framework` `MRMediaRemoteSendCommand`, loaded at runtime.
///   Works without Accessibility on the macOS versions tested; Apple restricted *reading* Now Playing
///   info in macOS 15.4, so this route only sends commands and may stop working in a future release.
final class MediaController: MediaControlling {
    enum Route: String, Sendable {
        case mediaKeys = "Media keys"
        case mediaRemote = "MediaRemote"
        case unavailable = "Unavailable"
    }

    private typealias SendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let mediaRemoteSend: SendCommandFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommandFn.self)
    }()

    private let keys: SystemKeyEmitter
    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "Media")

    init(keys: SystemKeyEmitter) {
        self.keys = keys
    }

    var route: Route {
        if keys.isAvailable { return .mediaKeys }
        if Self.mediaRemoteSend != nil { return .mediaRemote }
        return .unavailable
    }

    @discardableResult
    func send(_ command: MediaCommand) -> Bool {
        switch route {
        case .mediaKeys:
            let key: SystemKeyEmitter.Key
            switch command {
            case .next: key = .next
            case .previous: key = .previous
            case .playPause: key = .play
            }
            return keys.press(key)
        case .mediaRemote:
            // MRMediaRemoteCommand: 2 = togglePlayPause, 4 = nextTrack, 5 = previousTrack
            let code: UInt32
            switch command {
            case .playPause: code = 2
            case .next: code = 4
            case .previous: code = 5
            }
            let ok = Self.mediaRemoteSend?(code, nil) ?? false
            if !ok { log.notice("MRMediaRemoteSendCommand(\(code)) reported failure") }
            return ok
        case .unavailable:
            return false
        }
    }
}
