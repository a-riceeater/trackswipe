import CoreGraphics
import Foundation

/// Reads live modifier and mouse-button state from the combined HID session state.
///
/// `CGEventSource.flagsState` is a cheap synchronous query that needs no event tap and no Input
/// Monitoring permission, so it can be sampled on every touch frame. Fn and the Globe key both
/// report `maskSecondaryFn` on Apple keyboards (verify on each test Mac in Diagnostics → Live Input).
enum ModifierMonitor {
    static func current() -> ModifierState {
        ModifierState(cgFlags: CGEventSource.flagsState(.combinedSessionState))
    }

    /// True while the primary button is held (physical click, or tap-to-click's synthetic press).
    static func primaryButtonDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }
}
