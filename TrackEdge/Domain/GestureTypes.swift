import CoreGraphics
import Foundation

/// Snapshot of the keyboard modifier keys at the moment a touch frame is processed.
struct ModifierState: Equatable, Sendable {
    var shift = false
    var option = false
    var control = false
    var command = false
    /// Fn / Globe. Both report `maskSecondaryFn` on Apple keyboards.
    var function = false

    static let none = ModifierState()

    init(shift: Bool = false, option: Bool = false, control: Bool = false, command: Bool = false, function: Bool = false) {
        self.shift = shift
        self.option = option
        self.control = control
        self.command = command
        self.function = function
    }

    init(cgFlags: CGEventFlags) {
        shift = cgFlags.contains(.maskShift)
        option = cgFlags.contains(.maskAlternate)
        control = cgFlags.contains(.maskControl)
        command = cgFlags.contains(.maskCommand)
        function = cgFlags.contains(.maskSecondaryFn)
    }

    /// Fn/Globe or Option — the gate for "Require Fn or ⌥".
    var satisfiesSlideGate: Bool { function || option }

    /// Shift + Option — the chord for Fine Control quarter steps.
    var isFineChord: Bool { shift && option }
}

/// One finger contact in the app's normalised coordinate model:
/// `x = 0` is the left edge, `x = 1` the right edge, `y = 0` the top (far from the user) and `y = 1` the bottom.
struct TouchContact: Equatable, Sendable {
    var id: Int
    var x: Double
    var y: Double
    var isTouching: Bool

    init(id: Int, x: Double, y: Double, isTouching: Bool = true) {
        self.id = id
        self.x = x
        self.y = y
        self.isTouching = isTouching
    }
}

/// Everything the recognizer needs about one multitouch frame.
struct TouchFrame: Sendable {
    var timestamp: TimeInterval
    var contacts: [TouchContact]
    var modifiers: ModifierState
    /// True while the physical trackpad button (or tap-to-click) holds the primary button down.
    var buttonDown: Bool

    init(timestamp: TimeInterval, contacts: [TouchContact], modifiers: ModifierState = .none, buttonDown: Bool = false) {
        self.timestamp = timestamp
        self.contacts = contacts
        self.modifiers = modifiers
        self.buttonDown = buttonDown
    }
}

enum SlideTarget: String, Sendable, CaseIterable {
    case volume
    case brightness
}

enum MediaCommand: String, Sendable {
    case next
    case previous
    case playPause
}

/// Typed output of the recognizer. The recognizer never touches system APIs; the
/// `ActionDispatcher` turns these into real volume/brightness/media/cursor work.
enum GestureCommand: Equatable, Sendable {
    case slideBegan(SlideTarget)
    /// Positive steps raise the value, negative lower it. `fine` selects 1/64 instead of 1/16 steps.
    case adjust(SlideTarget, steps: Int, fine: Bool)
    case slideEnded(SlideTarget)
    case toggleMute
    case media(MediaCommand)
}

/// Converts raw MultitouchSupport normalised coordinates into the app model.
enum TouchNormalizer {
    /// MultitouchSupport reports y = 0 at the bottom (near the user). The app model uses y = 0 at the top,
    /// so the default conversion flips y. `invertY` exists only as a developer override, exposed in the
    /// Touch Inspector, in case a device reports the opposite orientation.
    static func normalize(rawX: Double, rawY: Double, invertY: Bool = false) -> (x: Double, y: Double) {
        let x = min(max(rawX, 0), 1)
        let y = min(max(rawY, 0), 1)
        return (x, invertY ? y : 1 - y)
    }
}
