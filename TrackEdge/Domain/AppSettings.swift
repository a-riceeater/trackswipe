import Combine
import Foundation

enum HapticStrength: String, CaseIterable, Identifiable, Sendable {
    case off, light, medium, strong
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case light, dark
    var id: String { rawValue }
    var title: String { self == .light ? "Light" : "Dark" }
}

/// The single source of truth for persisted preferences. Every property writes through to
/// `UserDefaults` immediately; observers (UI and the gesture engine) receive changes live.
///
/// "Open at Login" is intentionally *not* stored here: it is read from and written to
/// `SMAppService` by `LoginItemController`, so the UI always reflects the real OS registration.
final class AppSettings: ObservableObject {
    enum Key {
        static let hapticStrength = "hapticStrength"
        static let quickMute = "quickMuteEnabled"
        static let mediaStrip = "mediaStripEnabled"
        static let mediaTap = "mediaTapPlayPause"
        static let mediaStripExpanded = "mediaStripExpanded"
        static let sensitivity = "sensitivity"
        static let edgeWidth = "edgeWidth"
        static let swapSides = "swapSides"
        static let bottomQuarterOnly = "bottomQuarterOnly"
        static let requireModifier = "requireModifier"
        static let freezeCursor = "freezeCursor"
        static let fineControl = "fineControl"
        static let appearance = "appearance"
        static let inspectorEnabled = "debug.touchInspector"
        static let invertY = "debug.invertY"
    }

    enum Defaults {
        static let hapticStrength = HapticStrength.strong
        static let quickMute = true
        static let mediaStrip = true
        static let mediaTap = false
        static let mediaStripExpanded = true
        static let sensitivity = 1.5
        static let edgeWidth = 0.05
        static let swapSides = false
        static let bottomQuarterOnly = false
        static let requireModifier = false
        static let freezeCursor = true
        static let fineControl = true
        static let appearance = AppearanceMode.light
    }

    static let sensitivityRange: ClosedRange<Double> = 0.5...4.0
    static let sensitivityStep = 0.25
    static let edgeWidthRange: ClosedRange<Double> = 0.03...0.15
    static let edgeWidthStep = 0.01

    let defaults: UserDefaults

    @Published var hapticStrength: HapticStrength { didSet { defaults.set(hapticStrength.rawValue, forKey: Key.hapticStrength) } }
    @Published var quickMuteEnabled: Bool { didSet { defaults.set(quickMuteEnabled, forKey: Key.quickMute) } }
    @Published var mediaStripEnabled: Bool { didSet { defaults.set(mediaStripEnabled, forKey: Key.mediaStrip) } }
    @Published var mediaTapEnabled: Bool { didSet { defaults.set(mediaTapEnabled, forKey: Key.mediaTap) } }
    @Published var mediaStripExpanded: Bool { didSet { defaults.set(mediaStripExpanded, forKey: Key.mediaStripExpanded) } }
    @Published var sensitivity: Double {
        didSet {
            let clamped = Self.quantize(sensitivity, range: Self.sensitivityRange, step: Self.sensitivityStep)
            if clamped != sensitivity { sensitivity = clamped; return }
            defaults.set(sensitivity, forKey: Key.sensitivity)
        }
    }
    @Published var edgeWidth: Double {
        didSet {
            let clamped = Self.quantize(edgeWidth, range: Self.edgeWidthRange, step: Self.edgeWidthStep)
            if clamped != edgeWidth { edgeWidth = clamped; return }
            defaults.set(edgeWidth, forKey: Key.edgeWidth)
        }
    }
    @Published var swapSides: Bool { didSet { defaults.set(swapSides, forKey: Key.swapSides) } }
    @Published var bottomQuarterOnly: Bool { didSet { defaults.set(bottomQuarterOnly, forKey: Key.bottomQuarterOnly) } }
    @Published var requireModifier: Bool { didSet { defaults.set(requireModifier, forKey: Key.requireModifier) } }
    @Published var freezeCursor: Bool { didSet { defaults.set(freezeCursor, forKey: Key.freezeCursor) } }
    @Published var fineControl: Bool { didSet { defaults.set(fineControl, forKey: Key.fineControl) } }
    @Published var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    /// Developer-only live touch inspector. Off by default and never enabled automatically.
    @Published var inspectorEnabled: Bool { didSet { defaults.set(inspectorEnabled, forKey: Key.inspectorEnabled) } }
    /// Developer override for devices that report y in the opposite orientation.
    @Published var invertY: Bool { didSet { defaults.set(invertY, forKey: Key.invertY) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hapticStrength = HapticStrength(rawValue: defaults.string(forKey: Key.hapticStrength) ?? "") ?? Defaults.hapticStrength
        quickMuteEnabled = defaults.object(forKey: Key.quickMute) as? Bool ?? Defaults.quickMute
        mediaStripEnabled = defaults.object(forKey: Key.mediaStrip) as? Bool ?? Defaults.mediaStrip
        mediaTapEnabled = defaults.object(forKey: Key.mediaTap) as? Bool ?? Defaults.mediaTap
        mediaStripExpanded = defaults.object(forKey: Key.mediaStripExpanded) as? Bool ?? Defaults.mediaStripExpanded
        sensitivity = Self.quantize(defaults.object(forKey: Key.sensitivity) as? Double ?? Defaults.sensitivity,
                                    range: Self.sensitivityRange, step: Self.sensitivityStep)
        edgeWidth = Self.quantize(defaults.object(forKey: Key.edgeWidth) as? Double ?? Defaults.edgeWidth,
                                  range: Self.edgeWidthRange, step: Self.edgeWidthStep)
        swapSides = defaults.object(forKey: Key.swapSides) as? Bool ?? Defaults.swapSides
        bottomQuarterOnly = defaults.object(forKey: Key.bottomQuarterOnly) as? Bool ?? Defaults.bottomQuarterOnly
        requireModifier = defaults.object(forKey: Key.requireModifier) as? Bool ?? Defaults.requireModifier
        freezeCursor = defaults.object(forKey: Key.freezeCursor) as? Bool ?? Defaults.freezeCursor
        fineControl = defaults.object(forKey: Key.fineControl) as? Bool ?? Defaults.fineControl
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? Defaults.appearance
        inspectorEnabled = defaults.object(forKey: Key.inspectorEnabled) as? Bool ?? false
        invertY = defaults.object(forKey: Key.invertY) as? Bool ?? false
    }

    /// Restores every preference to its default. Login-item registration is left untouched because
    /// it is owned by macOS, not by this store.
    func resetToDefaults() {
        hapticStrength = Defaults.hapticStrength
        quickMuteEnabled = Defaults.quickMute
        mediaStripEnabled = Defaults.mediaStrip
        mediaTapEnabled = Defaults.mediaTap
        mediaStripExpanded = Defaults.mediaStripExpanded
        sensitivity = Defaults.sensitivity
        edgeWidth = Defaults.edgeWidth
        swapSides = Defaults.swapSides
        bottomQuarterOnly = Defaults.bottomQuarterOnly
        requireModifier = Defaults.requireModifier
        freezeCursor = Defaults.freezeCursor
        fineControl = Defaults.fineControl
        appearance = Defaults.appearance
        inspectorEnabled = false
        invertY = false
    }

    /// Recognizer configuration derived from the current preferences (device geometry is filled in per device).
    var gestureConfig: GestureConfig {
        var config = GestureConfig()
        config.edgeWidth = edgeWidth
        config.sensitivity = sensitivity
        config.swapSides = swapSides
        config.bottomQuarterOnly = bottomQuarterOnly
        config.requireModifier = requireModifier
        config.fineControlEnabled = fineControl
        config.quickMuteEnabled = quickMuteEnabled
        config.mediaStripEnabled = mediaStripEnabled
        config.mediaTapEnabled = mediaTapEnabled
        return config
    }

    static func quantize(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let steps = ((clamped - range.lowerBound) / step).rounded()
        let result = range.lowerBound + steps * step
        // Strip floating-point noise so 0.05 stays 0.05 when persisted.
        return (result * 10_000).rounded() / 10_000
    }
}
