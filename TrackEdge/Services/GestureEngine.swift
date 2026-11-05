import Foundation

/// Live data for the developer Touch Inspector (only produced while the inspector is open).
struct InspectorSnapshot: Equatable, Sendable {
    var deviceName = ""
    var contacts: [TouchContact] = []
    var state = "idle"
    var modifiers = ModifierState.none
    var buttonDown = false
    var secondsSinceKeyDown: TimeInterval = .infinity
    var config = GestureConfig()
}

/// Glue between `MultitouchProvider` (framework thread) and `GestureRecognizer` (pure).
/// Owns one recognizer per trackpad on a serial queue, samples modifier/button state per frame,
/// and forwards commands to the `ActionDispatcher`.
final class GestureEngine {
    private let queue = DispatchQueue(label: "dev.trackedge.gestures", qos: .userInteractive)
    private let dispatcher: ActionDispatcher

    // Queue-confined.
    private var recognizers: [UInt64: GestureRecognizer] = [:]
    private var baseConfig = GestureConfig()
    private var invertY = false
    private var enabled = true
    private var tickWork: DispatchWorkItem?
    private var lastInspectorPublish: CFAbsoluteTime = 0
    private var inspectorHandler: ((InspectorSnapshot) -> Void)?

    init(dispatcher: ActionDispatcher) {
        self.dispatcher = dispatcher
    }

    /// Entry point from the MultitouchSupport callback thread.
    func handle(device: TrackpadDevice, contacts raw: [RawContact], timestamp: TimeInterval) {
        // Sample input state as close to the frame as possible.
        let modifiers = ModifierMonitor.current()
        let buttonDown = ModifierMonitor.primaryButtonDown()
        let sinceKey = ModifierMonitor.secondsSinceKeyDown()
        queue.async { [self] in
            guard enabled else { return }
            let contacts = raw.map { contact -> TouchContact in
                let point = TouchNormalizer.normalize(rawX: contact.x, rawY: contact.y, invertY: invertY)
                return TouchContact(id: contact.id, x: point.x, y: point.y, isTouching: contact.isTouching, size: contact.majorAxis)
            }
            let frame = TouchFrame(timestamp: timestamp, contacts: contacts, modifiers: modifiers, buttonDown: buttonDown,
                                   secondsSinceKeyDown: sinceKey)
            var recognizer = recognizers[device.id] ?? GestureRecognizer(config: config(for: device))
            let commands = recognizer.process(frame)
            recognizers[device.id] = recognizer

            dispatcher.execute(commands, deviceID: device.id)
            if recognizer.activeSlideTarget != nil { dispatcher.slideFrame() }
            scheduleTick(for: device.id, recognizer: recognizer, frameTime: timestamp)
            publishInspector(device: device, frame: frame, recognizer: recognizer)
        }
    }

    func update(config: GestureConfig, invertY: Bool) {
        queue.async { [self] in
            baseConfig = config
            self.invertY = invertY
            for (id, var recognizer) in recognizers {
                var updated = config
                updated.surfaceWidthMM = recognizer.config.surfaceWidthMM
                updated.surfaceHeightMM = recognizer.config.surfaceHeightMM
                recognizer.update(config: updated)
                recognizers[id] = recognizer
            }
        }
    }

    /// Cancels every in-flight gesture and releases the cursor (sleep, device change, quit).
    func cancelAll() {
        dispatcher.abortAll()
        queue.async { [self] in
            tickWork?.cancel()
            for (id, var recognizer) in recognizers {
                dispatcher.execute(recognizer.cancel(), deviceID: id)
                recognizers[id] = recognizer
            }
        }
    }

    /// Drops recognizers for devices that disappeared.
    func retainDevices(_ ids: Set<UInt64>) {
        queue.async { [self] in
            for id in recognizers.keys where !ids.contains(id) {
                if var recognizer = recognizers.removeValue(forKey: id) {
                    dispatcher.execute(recognizer.cancel(), deviceID: id)
                }
            }
        }
    }

    func setEnabled(_ value: Bool) {
        if !value { cancelAll() }
        queue.async { [self] in enabled = value }
    }

    func setInspector(_ handler: ((InspectorSnapshot) -> Void)?) {
        queue.async { [self] in inspectorHandler = handler }
    }

    // MARK: - Private

    private func config(for device: TrackpadDevice) -> GestureConfig {
        var config = baseConfig
        config.surfaceWidthMM = device.widthMM
        config.surfaceHeightMM = device.heightMM
        return config
    }

    /// Strip taps are confirmed after a quiet period; frames may stop arriving, so use a timer.
    private func scheduleTick(for id: UInt64, recognizer: GestureRecognizer, frameTime: TimeInterval) {
        tickWork?.cancel()
        tickWork = nil
        guard let deadline = recognizer.pendingMediaTapDeadline else { return }
        let work = DispatchWorkItem { [self] in
            guard var r = recognizers[id] else { return }
            let commands = r.tick(now: deadline, secondsSinceKeyDown: ModifierMonitor.secondsSinceKeyDown())
            recognizers[id] = r
            dispatcher.execute(commands, deviceID: id)
        }
        tickWork = work
        queue.asyncAfter(deadline: .now() + max(0, deadline - frameTime), execute: work)
    }

    private func publishInspector(device: TrackpadDevice, frame: TouchFrame, recognizer: GestureRecognizer) {
        guard let handler = inspectorHandler else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastInspectorPublish > 1.0 / 30.0 else { return }
        lastInspectorPublish = now
        let snapshot = InspectorSnapshot(
            deviceName: device.name,
            contacts: frame.contacts,
            state: recognizer.stateName,
            modifiers: frame.modifiers,
            buttonDown: frame.buttonDown,
            secondsSinceKeyDown: frame.secondsSinceKeyDown,
            config: recognizer.config
        )
        DispatchQueue.main.async { handler(snapshot) }
    }
}
