import Foundation
import IOKit
import os

/// A physical multitouch trackpad discovered through MultitouchSupport (+ IOKit metadata).
struct TrackpadDevice: Identifiable, Equatable, Sendable {
    let id: UInt64
    let name: String
    let isBuiltIn: Bool
    let familyID: Int32
    let widthMM: Double
    let heightMM: Double
    /// IOKit `ForceSupported`: the device has a Taptic actuator (Force Touch trackpad).
    let forceTouch: Bool

    var kindDescription: String { isBuiltIn ? "Built-in trackpad" : "External trackpad" }
}

/// One raw contact as delivered by MultitouchSupport (normalised, origin bottom-left).
struct RawContact: Equatable, Sendable {
    let id: Int
    let x: Double
    let y: Double
    let state: Int32

    var isTouching: Bool {
        state == Int32(TEMTTouchStateMakeTouch.rawValue) || state == Int32(TEMTTouchStateTouching.rawValue)
    }
}

/// Owns the MultitouchSupport device list and its frame callbacks.
///
/// Supports several trackpads at once (e.g. built-in + Magic Trackpad): every device gets its own
/// callback registration and frames carry the originating `TrackpadDevice`, so the engine keeps an
/// independent recognizer per device. The C callback has no context pointer, hence the singleton.
final class MultitouchProvider {
    enum State: Equatable, Sendable {
        case stopped
        case unavailable(String)
        case noDevices
        case running(Int)
    }

    typealias FrameHandler = (TrackpadDevice, [RawContact], TimeInterval) -> Void

    static let shared = MultitouchProvider()

    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "Multitouch")
    private let lock = NSLock()
    private var deviceList: CFArray?
    private var active: [UInt: (ref: MultitouchBridge.DeviceRef, device: TrackpadDevice)] = [:]
    private var _frameHandler: FrameHandler?
    private var _state: State = .stopped

    private init() {}

    var frameHandler: FrameHandler? {
        get { lock.sync { _frameHandler } }
        set { lock.sync { _frameHandler = newValue } }
    }

    var state: State { lock.sync { _state } }

    var devices: [TrackpadDevice] {
        lock.sync { active.values.map(\.device).sorted { $0.isBuiltIn && !$1.isBuiltIn } }
    }

    /// Enumerates trackpads and starts frame delivery. Safe to call repeatedly (it restarts).
    @discardableResult
    func start() -> State {
        stop()
        guard let bridge = MultitouchBridge.shared else {
            setState(.unavailable("MultitouchSupport could not be loaded on this macOS version."))
            return state
        }
        guard let list = bridge.createList()?.takeRetainedValue() else {
            setState(.noDevices)
            return state
        }
        let metadata = Self.ioKitMetadata()
        var started: [UInt: (ref: MultitouchBridge.DeviceRef, device: TrackpadDevice)] = [:]

        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let ref = UnsafeMutableRawPointer(mutating: raw)
            guard let device = Self.describe(ref, bridge: bridge, metadata: metadata) else { continue }
            bridge.registerCallback(ref, multitouchContactCallback)
            let result = bridge.start(ref, 0)
            if result == 0 {
                started[UInt(bitPattern: ref)] = (ref, device)
                log.info("Started \(device.name, privacy: .public) (\(device.widthMM, format: .fixed(precision: 1))×\(device.heightMM, format: .fixed(precision: 1)) mm, family \(device.familyID))")
            } else {
                bridge.unregisterCallback(ref, multitouchContactCallback)
                log.error("MTDeviceStart failed (\(result)) for \(device.name, privacy: .public)")
            }
        }

        lock.sync {
            deviceList = list
            active = started
            _state = started.isEmpty ? .noDevices : .running(started.count)
        }
        return state
    }

    func stop() {
        guard let bridge = MultitouchBridge.shared else { return }
        let entries: [(ref: MultitouchBridge.DeviceRef, device: TrackpadDevice)] = lock.sync {
            let values = Array(active.values)
            active.removeAll()
            _state = .stopped
            return values
        }
        for entry in entries {
            bridge.unregisterCallback(entry.ref, multitouchContactCallback)
            if bridge.isAlive?(entry.ref) ?? true {
                _ = bridge.stop(entry.ref)
            }
        }
        // Releasing the list after stopping devices; MultitouchSupport owns the device objects.
        lock.sync { deviceList = nil }
    }

    // MARK: - Callback

    fileprivate func receive(device ref: MultitouchBridge.DeviceRef?, touches: UnsafeMutableRawPointer?, count: Int, timestamp: Double) {
        guard let ref else { return }
        let (entry, handler) = lock.sync { (active[UInt(bitPattern: ref)], _frameHandler) }
        guard let entry, let handler else { return }

        var contacts: [RawContact] = []
        if let touches, count > 0 {
            let typed = touches.bindMemory(to: TEMTTouch.self, capacity: count)
            contacts.reserveCapacity(count)
            for i in 0..<count {
                let t = typed[i]
                contacts.append(RawContact(
                    id: Int(t.pathIndex),
                    x: Double(t.normalizedVector.position.x),
                    y: Double(t.normalizedVector.position.y),
                    state: t.state
                ))
            }
        }
        handler(entry.device, contacts, timestamp)
    }

    private func setState(_ state: State) {
        lock.sync { _state = state }
    }

    // MARK: - Device description

    private struct IOMetadata {
        var product: String?
        var forceSupported: Bool
        var builtIn: Bool?
    }

    private static func describe(_ ref: MultitouchBridge.DeviceRef, bridge: MultitouchBridge, metadata: [UInt64: IOMetadata]) -> TrackpadDevice? {
        var width: Int32 = 0
        var height: Int32 = 0
        _ = bridge.surfaceDimensions(ref, &width, &height)
        var family: Int32 = 0
        _ = bridge.familyID?(ref, &family)
        var id: UInt64 = 0
        _ = bridge.deviceID?(ref, &id)
        if id == 0 { id = UInt64(UInt(bitPattern: ref)) }

        let widthMM = Double(width) / 100
        let heightMM = Double(height) / 100
        let meta = metadata[id]
        let builtIn = bridge.isBuiltIn(ref)
        let product = meta?.product ?? ""

        // Magic Mouse surfaces (families 112/113) and Touch Bar strips are multitouch devices but not trackpads.
        if family == 112 || family == 113 || product.localizedCaseInsensitiveContains("mouse") { return nil }
        if heightMM > 0, widthMM / heightMM > 3.5 { return nil }
        if heightMM > 0, heightMM < 25 { return nil }

        let name: String
        if builtIn {
            name = "Built-in Trackpad"
        } else if !product.isEmpty {
            name = product
        } else {
            name = "Magic Trackpad"
        }
        return TrackpadDevice(
            id: id,
            name: name,
            isBuiltIn: builtIn,
            familyID: family,
            widthMM: widthMM > 0 ? widthMM : 100,
            heightMM: heightMM > 0 ? heightMM : 70,
            forceTouch: meta?.forceSupported ?? false
        )
    }

    /// Reads `AppleMultitouchDevice` registry entries for product names and Force Touch support.
    private static func ioKitMetadata() -> [UInt64: IOMetadata] {
        var result: [UInt64: IOMetadata] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let idNumber = property("Multitouch ID") as? NSNumber else { continue }
            result[idNumber.uint64Value] = IOMetadata(
                product: property("Product") as? String,
                forceSupported: (property("ForceSupported") as? Bool) ?? false,
                builtIn: property("MT Built-In") as? Bool
            )
        }
        return result
    }
}

/// C-compatible trampoline registered with MultitouchSupport. Runs on the framework's own thread.
private let multitouchContactCallback: MultitouchBridge.ContactCallback = { device, touches, count, timestamp, _ in
    MultitouchProvider.shared.receive(device: device, touches: touches, count: Int(count), timestamp: timestamp)
    return 0
}
