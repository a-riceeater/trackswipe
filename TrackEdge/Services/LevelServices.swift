import CoreGraphics
import Foundation

struct AdjustResult: Equatable, Sendable {
    /// True if the level actually moved (false when pinned at 0 % / 100 %).
    let changed: Bool
    let value: Double
}

/// A system level that edge slides can step: output volume or display brightness.
protocol LevelControlling: AnyObject {
    func beginAdjust()
    /// Applies `steps` grid steps. Returns nil when the level cannot be controlled at all.
    func adjust(steps: Int, fine: Bool) -> AdjustResult?
    /// Restores the value captured by `beginAdjust`. Returns the restored value, or nil if nothing changed.
    func revert() -> Double?
    func endAdjust()
}

protocol MuteControlling: AnyObject {
    @discardableResult func toggleMute() -> Bool
}

/// How a level change reaches the system.
enum ControlRoute: String, Sendable {
    /// Synthesised hardware keys: exact keyboard behaviour + Apple's own HUD. Needs Accessibility and
    /// the "macOS" indicator style.
    case systemKeys = "Hardware key events (macOS HUD)"
    /// Direct CoreAudio / DisplayServices writes + feedback from `SystemOSDController`.
    case direct = "Direct write"
}

/// Output volume. Tracks the expected value during a slide so key-route steps (which macOS applies
/// asynchronously) never double-count, and so 0 %/100 % clamping is known without re-reading hardware.
final class VolumeService: LevelControlling, MuteControlling {
    private let audio: AudioController
    private let keys: SystemKeyEmitter
    private let osd: SystemOSDController
    private var tracked: AudioController.Snapshot?
    private var original: AudioController.Snapshot?

    init(audio: AudioController, keys: SystemKeyEmitter, osd: SystemOSDController) {
        self.audio = audio
        self.keys = keys
        self.osd = osd
    }

    /// Hardware-key events (macOS draws its own HUD) only when the "macOS" indicator style is chosen.
    private var useKeys: Bool { osd.preference.useSystemHUD && keys.isAvailable }

    var route: ControlRoute { useKeys ? .systemKeys : .direct }

    func beginAdjust() {
        tracked = audio.snapshot()
        original = tracked
    }

    func revert() -> Double? {
        guard let original, let value = original.volume, let current = tracked,
              current.volume != value || current.muted != original.muted else { return nil }
        // Written directly so no extra HUD flashes up for an undo.
        audio.setVolume(value)
        if current.muted != original.muted { audio.setMuted(original.muted) }
        tracked = original
        return value
    }

    func adjust(steps: Int, fine: Bool) -> AdjustResult? {
        guard steps != 0 else { return nil }
        var snap = tracked ?? audio.snapshot()
        guard snap.deviceID != 0, let current = snap.volume else { return nil }
        defer { tracked = snap }

        let useKeys = self.useKeys
        guard snap.canSetVolume else {
            // Fixed-volume output (e.g. HDMI): let macOS show its own "not adjustable" HUD if it can.
            if useKeys { keys.press(steps > 0 ? .soundUp : .soundDown) }
            return AdjustResult(changed: false, value: current)
        }

        let effective = StepMath.effectiveSteps(steps, from: current, fine: fine)
        let next = StepMath.apply(steps: effective, to: current, fine: fine)
        let unmutes = snap.muted && steps > 0

        if useKeys {
            // At a limit, one press still lets macOS show the pinned HUD, like the keyboard does.
            keys.press(steps > 0 ? .soundUp : .soundDown, fine: fine, repeatCount: max(abs(effective), 1))
        } else {
            if unmutes { audio.setMuted(false) }
            if effective != 0 { audio.setVolume(next) }
            osd.show(.volume(muted: snap.muted && !unmutes), value: next)
        }
        snap.volume = next
        if unmutes { snap.muted = false }
        return AdjustResult(changed: effective != 0 || unmutes, value: next)
    }

    func endAdjust() {
        tracked = nil
        original = nil
    }

    @discardableResult
    func toggleMute() -> Bool {
        let snap = audio.snapshot()
        guard snap.deviceID != 0 else { return false }
        if useKeys {
            return keys.press(.mute)
        }
        let ok = audio.setMuted(!snap.muted)
        if ok { osd.show(.volume(muted: !snap.muted), value: snap.volume ?? 0) }
        return ok
    }
}

/// Display brightness for the display chosen by `DisplayBrightnessController.targetDisplay()`.
final class BrightnessService: LevelControlling {
    private let display: DisplayBrightnessController
    private let keys: SystemKeyEmitter
    private let osd: SystemOSDController
    private var tracked: (id: CGDirectDisplayID, value: Double)?
    private var original: (id: CGDirectDisplayID, value: Double)?

    init(display: DisplayBrightnessController, keys: SystemKeyEmitter, osd: SystemOSDController) {
        self.display = display
        self.keys = keys
        self.osd = osd
    }

    var route: ControlRoute { osd.preference.useSystemHUD && keys.isAvailable ? .systemKeys : .direct }

    func beginAdjust() {
        if let id = display.targetDisplay(), let value = display.read(id) {
            tracked = (id, value)
        } else {
            tracked = nil
        }
        original = tracked
    }

    func revert() -> Double? {
        guard let original, let current = tracked, abs(current.value - original.value) > 1e-6 else { return nil }
        display.set(original.value, on: original.id)
        tracked = original
        return original.value
    }

    func adjust(steps: Int, fine: Bool) -> AdjustResult? {
        guard steps != 0 else { return nil }
        if tracked == nil { beginAdjust() }
        guard let state = tracked else { return nil }

        let effective = StepMath.effectiveSteps(steps, from: state.value, fine: fine)
        let next = StepMath.apply(steps: effective, to: state.value, fine: fine)
        // Brightness keys drive the built-in/Apple display; for any other capable display write directly.
        let useKeys = osd.preference.useSystemHUD && keys.isAvailable
            && (CGDisplayIsBuiltin(state.id) != 0 || CGMainDisplayID() == state.id)
        if useKeys {
            keys.press(steps > 0 ? .brightnessUp : .brightnessDown, fine: fine, repeatCount: max(abs(effective), 1))
        } else {
            if effective != 0 { display.set(next, on: state.id) }
            osd.show(.brightness, value: next, display: state.id)
        }
        tracked = (state.id, next)
        return AdjustResult(changed: effective != 0, value: next)
    }

    func endAdjust() {
        tracked = nil
        original = nil
    }
}
