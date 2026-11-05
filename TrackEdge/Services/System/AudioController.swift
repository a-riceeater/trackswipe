import AudioToolbox
import CoreAudio
import Foundation
import os

/// Reads and writes the default output device through CoreAudio (public API).
///
/// Volume uses `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (what the menu-bar slider uses),
/// falling back to the main-element and then per-channel `VolumeScalar`. Devices with no settable
/// volume (many HDMI/DisplayPort/optical outputs) are reported as such instead of being silently ignored.
final class AudioController {
    struct Snapshot: Equatable, Sendable {
        var deviceID: AudioDeviceID = 0
        var deviceName: String = ""
        var volume: Double?
        var muted = false
        var canSetVolume = false
        var hasMute = false

        var isAvailable: Bool { deviceID != 0 && volume != nil }
    }

    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "Audio")
    private let queue = DispatchQueue(label: "dev.trackedge.audio.listeners")
    private var observedDevice: AudioDeviceID = 0
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemListener: AudioObjectPropertyListenerBlock?
    /// Volume restored by Quick Mute on devices without a hardware mute control.
    private var softMutedVolume: Double?

    /// Called (on a background queue) whenever the default device, its volume or its mute state changes.
    var onChange: (() -> Void)?

    init() {}

    deinit { stopObserving() }

    // MARK: - Reading

    func snapshot() -> Snapshot {
        guard let device = defaultOutputDevice() else { return Snapshot() }
        var snap = Snapshot(deviceID: device)
        snap.deviceName = name(of: device) ?? "Output device"
        snap.volume = readVolume(device)
        snap.canSetVolume = volumeAddress(for: device, settable: true) != nil
        if let muteAddr = muteAddress(for: device) {
            snap.hasMute = true
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = muteAddr
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                snap.muted = value != 0
            }
        } else {
            snap.muted = softMutedVolume != nil
        }
        return snap
    }

    // MARK: - Writing

    @discardableResult
    func setVolume(_ value: Double) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let clamped = Float32(min(max(value, 0), 1))
        if var addr = volumeAddress(for: device, settable: true) {
            if addr.mSelector == kAudioDevicePropertyVolumeScalar && addr.mElement != kAudioObjectPropertyElementMain {
                // Per-channel device: write both stereo channels.
                var ok = false
                for channel: UInt32 in [1, 2] {
                    addr.mElement = channel
                    var v = clamped
                    if isSettable(device, addr) {
                        ok = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr || ok
                    }
                }
                return ok
            }
            var v = clamped
            let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            if status != noErr { log.error("Set volume failed: \(status)") }
            return status == noErr
        }
        return false
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        if var addr = muteAddress(for: device), isSettable(device, addr) {
            var value: UInt32 = muted ? 1 : 0
            return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        }
        // No hardware mute: emulate by zeroing volume and remembering the previous level.
        if muted {
            guard softMutedVolume == nil, let current = readVolume(device) else { return softMutedVolume != nil }
            softMutedVolume = current
            return setVolume(0)
        } else {
            guard let restore = softMutedVolume else { return true }
            softMutedVolume = nil
            return setVolume(restore)
        }
    }

    // MARK: - Observation

    func startObserving() {
        guard systemListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebindDeviceListeners()
            self?.onChange?()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
            systemListener = block
        }
        rebindDeviceListeners()
    }

    func stopObserving() {
        removeDeviceListeners()
        if let block = systemListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            systemListener = nil
        }
    }

    private func rebindDeviceListeners() {
        removeDeviceListeners()
        guard let device = defaultOutputDevice() else { return }
        observedDevice = device
        softMutedVolume = nil
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioDevicePropertyMute, kAudioObjectPropertyElementMain),
        ]
        for (selector, element) in selectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
            if AudioObjectAddPropertyListenerBlock(device, &addr, queue, block) == noErr {
                deviceListeners.append((addr, block))
            }
        }
    }

    private func removeDeviceListeners() {
        for (address, block) in deviceListeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(observedDevice, &addr, queue, block)
        }
        deviceListeners.removeAll()
        observedDevice = 0
    }

    // MARK: - CoreAudio helpers

    func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private func name(of device: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private func readVolume(_ device: AudioDeviceID) -> Double? {
        guard var addr = volumeAddress(for: device, settable: false) else { return nil }
        if addr.mSelector == kAudioDevicePropertyVolumeScalar && addr.mElement != kAudioObjectPropertyElementMain {
            var values: [Float32] = []
            for channel: UInt32 in [1, 2] {
                addr.mElement = channel
                var v: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectHasProperty(device, &addr), AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr {
                    values.append(v)
                }
            }
            return values.isEmpty ? nil : Double(values.reduce(0, +) / Float32(values.count))
        }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return Double(v)
    }

    /// Finds the best volume property: virtual main → main-element scalar → channel 1 scalar.
    private func volumeAddress(for device: AudioDeviceID, settable: Bool) -> AudioObjectPropertyAddress? {
        let candidates: [AudioObjectPropertyAddress] = [
            AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                       mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioDevicePropertyScopeOutput, mElement: 1),
        ]
        for candidate in candidates {
            var addr = candidate
            guard AudioObjectHasProperty(device, &addr) else { continue }
            if settable && !isSettable(device, addr) { continue }
            return candidate
        }
        return nil
    }

    private func muteAddress(for device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(device, &addr) ? addr : nil
    }

    private func isSettable(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }
}
