import AppKit
import os

protocol HapticPerforming: AnyObject {
    /// `fine` marks a quarter-step tick, which plays a softer waveform than the chosen strength.
    func perform(_ strength: HapticStrength, fine: Bool, on deviceID: UInt64?)
}

extension HapticPerforming {
    func perform(_ strength: HapticStrength, on deviceID: UInt64?) {
        perform(strength, fine: false, on: deviceID)
    }
}

/// Trackpad haptics.
///
/// Preferred route: the Taptic actuator of the touching device via PRIVATE MultitouchSupport
/// `MTActuator*` functions. They work from a background app, target the exact trackpad being used and
/// expose distinct waveforms, which is what makes Light/Medium/Strong genuinely different.
///
/// Fallback: public `NSHapticFeedbackManager`, which only offers fixed patterns and macOS may ignore it
/// while the app is inactive. Devices without a Taptic engine (pre-Force-Touch trackpads) get no
/// haptics at all; no audible "click" substitute is ever produced.
final class HapticEngine: HapticPerforming {
    enum Support: Equatable, Sendable {
        case actuator
        case publicAPI
        case unsupported

        var description: String {
            switch self {
            case .actuator: return "Force Touch actuator"
            case .publicAPI: return "System haptics (limited)"
            case .unsupported: return "Not supported by this trackpad"
            }
        }
    }

    /// Actuation waveform IDs. The IDs are NOT ordered by intensity: on a 2022+ MacBook trackpad,
    /// waveform 2 feels clearly stronger than 3, and 3 is a good "light" tick. Light/Medium/Strong
    /// therefore follow the community-documented 3/4/6 progression. Quarter steps (⇧⌥) arrive four
    /// times as often and always use waveform 1. Feel and retune in Diagnostics › Haptic waveforms.
    static let waveforms: [HapticStrength: (normal: Int32, fine: Int32)] = [
        .light: (normal: 3, fine: 1),
        .medium: (normal: 4, fine: 1),
        .strong: (normal: 6, fine: 1),
    ]

    static func actuationID(for strength: HapticStrength, fine: Bool) -> Int32? {
        guard let entry = waveforms[strength] else { return nil }
        return fine ? entry.fine : entry.normal
    }

    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "Haptics")
    private let lock = NSLock()
    private var actuators: [UInt64: CFTypeRef] = [:]
    private var support: [UInt64: Support] = [:]
    private var lastFire: CFAbsoluteTime = 0
    /// Upper bound on tick rate so fast slides feel like discrete detents rather than a buzz.
    private let minimumInterval: CFTimeInterval = 0.028
    /// Quarter steps arrive faster; space their ticks further apart so they never blur into a buzz.
    private let minimumFineInterval: CFTimeInterval = 0.05

    deinit { closeAll() }

    /// Opens actuators for the given trackpads, closing any for devices that went away.
    func configure(devices: [TrackpadDevice]) {
        closeAll()
        let bridge = MultitouchBridge.shared
        var newActuators: [UInt64: CFTypeRef] = [:]
        var newSupport: [UInt64: Support] = [:]
        for device in devices {
            if let bridge, bridge.supportsActuator,
               let actuator = bridge.actuatorCreate?(device.id)?.takeRetainedValue(),
               bridge.actuatorOpen?(actuator) == 0 {
                newActuators[device.id] = actuator
                newSupport[device.id] = .actuator
            } else if device.forceTouch {
                newSupport[device.id] = .publicAPI
            } else {
                newSupport[device.id] = .unsupported
            }
        }
        lock.sync {
            actuators = newActuators
            support = newSupport
        }
    }

    func support(for deviceID: UInt64) -> Support {
        lock.sync { support[deviceID] ?? .unsupported }
    }

    /// Best support across all connected trackpads (for the dashboard summary).
    var overallSupport: Support {
        lock.sync {
            if support.values.contains(.actuator) { return .actuator }
            if support.values.contains(.publicAPI) { return .publicAPI }
            return .unsupported
        }
    }

    func perform(_ strength: HapticStrength, fine: Bool, on deviceID: UInt64?) {
        guard let actuationID = Self.actuationID(for: strength, fine: fine) else { return }
        actuate(actuationID, fine: fine, publicPattern: Self.publicPattern(for: strength, fine: fine), on: deviceID)
    }

    /// Plays a raw waveform ID (Diagnostics tester).
    func test(actuationID: Int32) {
        actuate(actuationID, fine: false, publicPattern: .generic, on: nil, throttle: false)
    }

    private static func publicPattern(for strength: HapticStrength, fine: Bool) -> NSHapticFeedbackManager.FeedbackPattern {
        if fine { return .alignment }
        switch strength {
        case .strong: return .generic
        default: return .alignment
        }
    }

    private func actuate(_ actuationID: Int32, fine: Bool, publicPattern pattern: NSHapticFeedbackManager.FeedbackPattern,
                         on deviceID: UInt64?, throttle: Bool = true) {
        let now = CFAbsoluteTimeGetCurrent()
        let interval = fine ? minimumFineInterval : minimumInterval
        let target: (actuator: CFTypeRef?, support: Support) = lock.sync {
            guard !throttle || now - lastFire >= interval else { return (nil, .unsupported) }
            let id = deviceID ?? support.first(where: { $0.value == .actuator })?.key
            let resolved = id.flatMap { support[$0] } ?? .unsupported
            if resolved != .unsupported { lastFire = now }
            return (id.flatMap { actuators[$0] }, resolved)
        }
        switch target.support {
        case .actuator:
            if let actuator = target.actuator, let actuate = MultitouchBridge.shared?.actuatorActuate {
                let result = actuate(actuator, actuationID, 0, 1.0, 2.0)
                if result != 0 { log.debug("MTActuatorActuate returned \(result)") }
            }
        case .publicAPI:
            DispatchQueue.main.async {
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            }
        case .unsupported:
            break
        }
    }

    private func closeAll() {
        let old: [CFTypeRef] = lock.sync {
            let values = Array(actuators.values)
            actuators.removeAll()
            support.removeAll()
            return values
        }
        if let close = MultitouchBridge.shared?.actuatorClose {
            for actuator in old { _ = close(actuator) }
        }
    }
}
