import Foundation
import os

/// Executes recognizer commands against the real system controllers on a dedicated serial queue.
///
/// Responsibilities: cursor freeze/release around slides, coalescing bursts of steps into bounded-rate
/// writes, one haptic tick per real level change (never at a pinned limit), and notifying the UI.
final class ActionDispatcher {
    struct Options: Equatable, Sendable {
        var freezeCursor = true
        var haptics: HapticStrength = .strong
    }

    let volume: LevelControlling & MuteControlling
    let brightness: LevelControlling
    let media: MediaControlling
    let haptics: HapticPerforming
    let cursor: CursorFreezing

    /// UI hooks (invoked on the dispatcher queue; hop to main yourself).
    var onLevelChanged: ((SlideTarget, Double) -> Void)?
    var onSlideStateChanged: ((SlideTarget?) -> Void)?
    var onCommand: ((GestureCommand) -> Void)?

    private let queue: DispatchQueue
    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "Actions")
    private let optionsLock = NSLock()
    private var _options = Options()
    private let minimumWriteInterval: CFTimeInterval

    // Queue-confined state.
    private var activeSlide: SlideTarget?
    private var activeDevice: UInt64?
    private var pendingSteps = 0
    private var pendingFine = false
    private var lastWrite: CFAbsoluteTime = 0
    private var flushScheduled = false

    init(volume: LevelControlling & MuteControlling,
         brightness: LevelControlling,
         media: MediaControlling,
         haptics: HapticPerforming,
         cursor: CursorFreezing,
         queue: DispatchQueue = DispatchQueue(label: "dev.trackedge.actions", qos: .userInteractive),
         minimumWriteInterval: CFTimeInterval = 1.0 / 90.0) {
        self.volume = volume
        self.brightness = brightness
        self.media = media
        self.haptics = haptics
        self.cursor = cursor
        self.queue = queue
        self.minimumWriteInterval = minimumWriteInterval
    }

    var options: Options {
        get { optionsLock.sync { _options } }
        set {
            optionsLock.sync { _options = newValue }
            if !newValue.freezeCursor { cursor.release() }
        }
    }

    func execute(_ commands: [GestureCommand], deviceID: UInt64) {
        guard !commands.isEmpty else { return }
        queue.async { [self] in
            for command in commands { handle(command, deviceID: deviceID) }
        }
    }

    /// Synchronous variant for unit tests.
    func executeNow(_ commands: [GestureCommand], deviceID: UInt64) {
        queue.sync { [self] in
            for command in commands { handle(command, deviceID: deviceID) }
        }
    }

    /// Called on every frame while a slide is active (from the gesture queue).
    func slideFrame() {
        if options.freezeCursor { cursor.maintain() }
    }

    /// Ends any active slide and releases the cursor immediately (sleep, quit, device loss, disable).
    func abortAll() {
        cursor.release()
        queue.async { [self] in
            if let target = activeSlide { handle(.slideEnded(target), deviceID: activeDevice ?? 0) }
        }
    }

    var isSlideActive: Bool { queue.sync { activeSlide != nil } }

    // MARK: - Command handling (queue-confined)

    private func handle(_ command: GestureCommand, deviceID: UInt64) {
        onCommand?(command)
        switch command {
        case let .slideBegan(target):
            activeSlide = target
            activeDevice = deviceID
            pendingSteps = 0
            controller(for: target).beginAdjust()
            if options.freezeCursor { cursor.freeze() }
            onSlideStateChanged?(target)

        case let .adjust(target, steps, fine):
            guard target == activeSlide else { return }
            if pendingSteps != 0 && pendingFine != fine { flush() }
            pendingSteps += steps
            pendingFine = fine
            let elapsed = CFAbsoluteTimeGetCurrent() - lastWrite
            if elapsed >= minimumWriteInterval {
                flush()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + (minimumWriteInterval - elapsed)) { [self] in
                    flushScheduled = false
                    flush()
                }
            }

        case let .slideEnded(target):
            if activeSlide == target { flush() }
            cursor.release()
            controller(for: target).endAdjust()
            if activeSlide == target {
                activeSlide = nil
                activeDevice = nil
                onSlideStateChanged?(nil)
            }

        case .toggleMute:
            if volume.toggleMute() { haptics.perform(options.haptics, on: deviceID) }
            onLevelChanged?(.volume, -1)

        case let .media(mediaCommand):
            if media.send(mediaCommand) { haptics.perform(options.haptics, on: deviceID) }
        }
    }

    private func flush() {
        guard pendingSteps != 0, let target = activeSlide else { return }
        let steps = pendingSteps
        pendingSteps = 0
        lastWrite = CFAbsoluteTimeGetCurrent()
        guard let result = controller(for: target).adjust(steps: steps, fine: pendingFine) else { return }
        if result.changed {
            haptics.perform(options.haptics, on: activeDevice)
        }
        onLevelChanged?(target, result.value)
    }

    private func controller(for target: SlideTarget) -> LevelControlling {
        target == .volume ? volume : brightness
    }
}
