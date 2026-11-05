import AppKit
import os

/// Which on-screen display volume/brightness changes use. Read on the gesture/action queues, written
/// from the main thread when the setting changes, hence the lock.
final class IndicatorPreference: @unchecked Sendable {
    private let lock = NSLock()
    private var _useSystemHUD = false

    /// true = Apple's own HUD (via hardware-key events when Accessibility is granted);
    /// false = TrackEdge's bottom-centre indicator (the default).
    var useSystemHUD: Bool {
        get { lock.sync { _useSystemHUD } }
        set { lock.sync { _useSystemHUD = newValue } }
    }
}

/// On-screen feedback for level changes that TrackEdge writes directly (CoreAudio / DisplayServices).
///
/// - Indicator style "TrackEdge" (default): always TrackEdge's own bottom-centre indicator.
/// - Indicator style "macOS": the level services use hardware-key events so macOS draws its own HUD.
///   Only if that route is unavailable (no Accessibility) does this class step in: Apple's HUD through the
///   PRIVATE `OSDManager` on macOS 13–15, or TrackEdge's indicator on macOS 26+, where `OSDManager`
///   still resolves but no longer renders anything (verified on 26.6).
final class SystemOSDController {
    enum Route: String, Sendable {
        case trackEdge = "TrackEdge indicator (bottom centre)"
        case privateOSD = "Apple HUD (OSDManager)"
    }

    enum Kind: Equatable {
        case volume(muted: Bool)
        case brightness
    }

    private typealias ShowFn = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void

    let preference: IndicatorPreference
    private let lock = NSLock()
    private var lastShown: CFAbsoluteTime = 0

    init(preference: IndicatorPreference) {
        self.preference = preference
    }

    private static let osd: (manager: NSObject, selector: Selector, show: ShowFn)? = {
        guard #unavailable(macOS 26) else { return nil }
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/OSD.framework"), bundle.load(),
              let cls = NSClassFromString("OSDManager") as? NSObject.Type,
              let manager = cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        let selector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
        guard manager.responds(to: selector), let imp = manager.method(for: selector) else { return nil }
        return (manager, selector, unsafeBitCast(imp, to: ShowFn.self))
    }()

    var route: Route {
        preference.useSystemHUD && Self.osd != nil ? .privateOSD : .trackEdge
    }

    /// Shows feedback for a new value. Throttled to ~30 Hz; safe to call from any thread.
    func show(_ kind: Kind, value: Double, display: CGDirectDisplayID? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        let allowed: Bool = lock.sync {
            guard now - lastShown > 0.033 else { return false }
            lastShown = now
            return true
        }
        guard allowed else { return }
        let clamped = min(max(value, 0), 1)
        if route == .privateOSD, let osd = Self.osd {
            // OSDGraphic: 1 = backlight, 3 = speaker, 4 = speaker muted. 64 chiclets keeps quarter steps visible.
            let image: Int64
            switch kind {
            case .brightness: image = 1
            case let .volume(muted): image = muted || clamped == 0 ? 4 : 3
            }
            let filled = UInt32((clamped * 64).rounded())
            osd.show(osd.manager, osd.selector, image, display ?? CGMainDisplayID(), 0x1F4, 1000, filled, 64, false)
            return
        }
        Task { @MainActor in
            IndicatorHUD.shared.show(IndicatorHUD.Content(level: kind, value: clamped))
        }
    }
}
