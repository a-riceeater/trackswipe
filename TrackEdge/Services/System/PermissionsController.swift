import AppKit
import ApplicationServices
import IOKit.hid

/// Permission status and System Settings deep links.
///
/// What actually needs a permission in this implementation:
/// - **Accessibility** — posting synthetic hardware-key events (native HUD, exact keyboard stepping,
///   media keys). Without it the app still works through direct writes and MediaRemote.
/// - **Input Monitoring** — not required by MultitouchSupport or the modifier-state query on the macOS
///   versions tested. It is shown read-only in Diagnostics because some macOS releases have gated raw HID
///   access differently; if touches never arrive on a given Mac, this is the first thing to check.
enum PermissionsController {
    enum Status: String, Sendable {
        case granted = "Granted"
        case denied = "Not granted"
        case unknown = "Not determined"
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static var inputMonitoring: Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// Shows the system Accessibility prompt (adds the app to the list, unchecked).
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
