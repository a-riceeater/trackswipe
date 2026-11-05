import AppKit
import ApplicationServices

/// Synthesises the same system-defined (NX_SYSDEFINED) key events that the keyboard's volume,
/// brightness and media keys produce.
///
/// This is the most faithful route: macOS itself performs the change, shows its own native HUD
/// (verified on macOS 26, including the redesigned volume HUD), unmutes on volume-up and routes media
/// keys to the current Now Playing app. ⇧⌥ + key yields the system's own quarter (1/64) steps.
///
/// Requirement: posting synthetic events needs the Accessibility permission. Without it the events are
/// silently dropped, so callers must check `isAvailable` and fall back to direct writes.
final class SystemKeyEmitter {
    enum Key: Int32 {
        case soundUp = 0       // NX_KEYTYPE_SOUND_UP
        case soundDown = 1     // NX_KEYTYPE_SOUND_DOWN
        case brightnessUp = 2  // NX_KEYTYPE_BRIGHTNESS_UP
        case brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
        case mute = 7          // NX_KEYTYPE_MUTE
        case play = 16         // NX_KEYTYPE_PLAY
        case next = 17         // NX_KEYTYPE_NEXT
        case previous = 18     // NX_KEYTYPE_PREVIOUS
    }

    private let permissions: () -> Bool

    init(permissions: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.permissions = permissions
    }

    var isAvailable: Bool { permissions() }

    /// Posts a key-down/key-up pair. Returns false if the route is unavailable.
    @discardableResult
    func press(_ key: Key, fine: Bool = false, repeatCount: Int = 1) -> Bool {
        guard isAvailable, repeatCount > 0 else { return false }
        // Only the flags we set are attached to the event, so a physically held ⌥ (used for
        // "Require Fn or ⌥") does not turn a volume key into "open Sound settings".
        let modifiers: NSEvent.ModifierFlags = fine ? [.shift, .option] : []
        for _ in 0..<repeatCount {
            for isDown in [true, false] {
                let stateBits: UInt = isDown ? 0xA00 : 0xB00
                let data1 = Int((key.rawValue << 16) | ((isDown ? 0xA : 0xB) << 8))
                guard let event = NSEvent.otherEvent(
                    with: .systemDefined,
                    location: .zero,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: stateBits | modifiers.rawValue),
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                    data1: data1,
                    data2: -1
                ), let cgEvent = event.cgEvent else { return false }
                cgEvent.post(tap: .cghidEventTap)
            }
        }
        return true
    }
}
