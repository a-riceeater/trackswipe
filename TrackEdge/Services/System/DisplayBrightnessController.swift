import AppKit
import CoreGraphics
import os

/// Display brightness through Apple's PRIVATE `DisplayServices.framework` (loaded at runtime).
///
/// Per-display capability strategy:
/// 1. The built-in panel when it is active (lid open) and DisplayServices reports it can change brightness.
/// 2. Otherwise the first active display DisplayServices can drive (Apple Studio Display, Pro Display XDR,
///    LG UltraFine and other displays that expose native brightness control).
/// 3. Otherwise brightness is reported "Unsupported display". Third-party monitors would need DDC/CI over
///    I²C, which this app deliberately does not implement (no fake/gamma dimming is substituted).
final class DisplayBrightnessController {
    struct Snapshot: Equatable, Sendable {
        var displayID: CGDirectDisplayID = 0
        var displayName: String = ""
        var isBuiltIn = false
        var brightness: Double?
        var isAvailable: Bool { displayID != 0 && brightness != nil }
    }

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Int32

    private struct Bridge {
        let get: GetFn
        let set: SetFn
        let canChange: CanFn?
        let changed: ChangedFn?

        static let shared: Bridge? = {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
                  let get = dlsym(handle, "DisplayServicesGetBrightness"),
                  let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
            return Bridge(
                get: unsafeBitCast(get, to: GetFn.self),
                set: unsafeBitCast(set, to: SetFn.self),
                canChange: dlsym(handle, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanFn.self) },
                changed: dlsym(handle, "DisplayServicesBrightnessChanged").map { unsafeBitCast($0, to: ChangedFn.self) }
            )
        }()
    }

    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "Brightness")

    var isFrameworkAvailable: Bool { Bridge.shared != nil }

    /// The display gestures adjust, per the strategy above.
    func targetDisplay() -> CGDirectDisplayID? {
        guard let bridge = Bridge.shared else { return nil }
        let displays = activeDisplays()
        func capable(_ id: CGDirectDisplayID) -> Bool {
            if let can = bridge.canChange { return can(id) }
            var value: Float = 0
            return bridge.get(id, &value) == 0
        }
        if let builtIn = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }), capable(builtIn) {
            return builtIn
        }
        return displays.first(where: capable)
    }

    func snapshot() -> Snapshot {
        guard let display = targetDisplay() else {
            return Snapshot(displayName: activeDisplays().isEmpty ? "No display" : "Unsupported display")
        }
        return Snapshot(
            displayID: display,
            displayName: Self.name(of: display),
            isBuiltIn: CGDisplayIsBuiltin(display) != 0,
            brightness: read(display)
        )
    }

    func read(_ display: CGDirectDisplayID) -> Double? {
        guard let bridge = Bridge.shared else { return nil }
        var value: Float = 0
        guard bridge.get(display, &value) == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    @discardableResult
    func set(_ value: Double, on display: CGDirectDisplayID) -> Bool {
        guard let bridge = Bridge.shared else { return false }
        let clamped = Float(min(max(value, 0), 1))
        let status = bridge.set(display, clamped)
        if status != 0 {
            log.error("DisplayServicesSetBrightness failed: \(status)")
            return false
        }
        // Lets the system brightness UI / Control Center catch up where the symbol exists.
        _ = bridge.changed?(display, Double(clamped))
        return true
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    static func name(of display: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(display) != 0 { return "Built-in Display" }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
        return screen?.localizedName ?? "Display \(display)"
    }
}
