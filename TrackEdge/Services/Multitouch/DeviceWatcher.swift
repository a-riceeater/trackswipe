import Foundation
import IOKit

/// Watches IOKit for multitouch devices appearing or disappearing (Magic Trackpad connect/disconnect,
/// Bluetooth power cycles) and reports a debounced change so the provider can re-enumerate.
final class DeviceWatcher {
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue()
            DeviceWatcher.drain(iterator)
            watcher.scheduleChange()
        }

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"), callback, refcon, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("AppleMultitouchDevice"), callback, refcon, &removedIterator)
        // Arm the notifications (existing devices are already handled by the initial enumeration).
        Self.drain(addedIterator)
        Self.drain(removedIterator)
    }

    func stop() {
        pending?.cancel()
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        // Devices publish several registry entries while attaching; wait for them to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}
