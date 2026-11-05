import Foundation

/// Pure, deterministic edge-gesture state machine.
///
/// It consumes normalised single-device touch frames plus modifier/button state and emits typed
/// `GestureCommand`s. It owns no timers and calls no system APIs; time comes only from frame
/// timestamps and explicit `tick(now:)` calls, which makes every decision reproducible in unit tests.
///
/// Rules, in priority order for a fresh single-finger touch:
/// 1. More than one finger at any point cancels everything until all fingers lift (scrolls, pinches, palms).
/// 2. A touch that starts inside a side edge becomes a slide once vertical travel passes the dead zone,
///    dominates horizontal travel, and lateral travel stays within tolerance. Physical clicks reject it.
/// 3. A touch that starts in the bottom strip becomes a media swipe once horizontal travel dominates and
///    passes the minimum distance quickly enough. Exactly one command per stroke.
/// 4. Short, still taps in the top-right corner (twice, within the window) toggle mute.
/// 5. A short, still tap in the bottom strip (when enabled) queues play/pause, confirmed only if no new
///    touch lands (and no key is pressed) within `mediaTapConfirmDelay`.
///
/// Typing palm rejection: a touch that starts within `typingGuard` of a key press is ignored until it
/// lifts, and a key press at any point during a touch cancels that touch (ending an active slide).
struct GestureRecognizer {
    struct Zones: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let leftEdge = Zones(rawValue: 1 << 0)
        static let rightEdge = Zones(rawValue: 1 << 1)
        static let muteCorner = Zones(rawValue: 1 << 2)
        static let bottomStrip = Zones(rawValue: 1 << 3)
        static let edges: Zones = [.leftEdge, .rightEdge]
    }

    struct Candidate: Equatable, Sendable {
        var contactID: Int
        var startTime: TimeInterval
        var startX: Double
        var startY: Double
        var lastX: Double
        var lastY: Double
        var maxDistanceMM: Double = 0
        var zones: Zones
        var buttonPressed: Bool
        var isSecondCornerTap: Bool
    }

    struct Slide: Equatable, Sendable {
        var contactID: Int
        var startTime: TimeInterval
        var target: SlideTarget
        var smoothedY: Double
        var anchorY: Double
        var fine: Bool
    }

    enum Phase: Equatable, Sendable {
        case idle
        case candidate(Candidate)
        case sliding(Slide)
        /// The current touch was decided (or rejected); ignore it until every finger lifts.
        case consumed
        /// Multi-finger input; ignore until every finger lifts.
        case blocked
    }

    private(set) var config: GestureConfig
    private(set) var phase: Phase = .idle
    private var lastCornerTapLift: TimeInterval?
    private(set) var pendingMediaTapDeadline: TimeInterval?

    init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    mutating func update(config: GestureConfig) {
        self.config = config
        if !config.mediaTapEnabled || !config.mediaStripEnabled { pendingMediaTapDeadline = nil }
        if !config.quickMuteEnabled { lastCornerTapLift = nil }
    }

    var activeSlideTarget: SlideTarget? {
        if case let .sliding(slide) = phase { return slide.target }
        return nil
    }

    var stateName: String {
        switch phase {
        case .idle: return "idle"
        case let .candidate(c):
            var parts: [String] = []
            if c.zones.contains(.leftEdge) { parts.append("left") }
            if c.zones.contains(.rightEdge) { parts.append("right") }
            if c.zones.contains(.muteCorner) { parts.append(c.isSecondCornerTap ? "corner#2" : "corner") }
            if c.zones.contains(.bottomStrip) { parts.append("strip") }
            return "candidate(\(parts.joined(separator: ",")))"
        case let .sliding(s): return "\(s.target.rawValue)Slide\(s.fine ? " fine" : "")"
        case .consumed: return "consumed"
        case .blocked: return "blocked"
        }
    }

    /// Abort any in-flight gesture (sleep, device loss, disable). Ends an active slide so the cursor is released.
    mutating func cancel() -> [GestureCommand] {
        defer {
            phase = .blocked
            pendingMediaTapDeadline = nil
            lastCornerTapLift = nil
        }
        if case let .sliding(slide) = phase { return [.slideEnded(slide.target)] }
        return []
    }

    /// Fires a confirmed strip tap once its deadline passes without a new touch or key press.
    mutating func tick(now: TimeInterval, secondsSinceKeyDown: TimeInterval = .infinity) -> [GestureCommand] {
        guard let deadline = pendingMediaTapDeadline, now >= deadline else { return [] }
        pendingMediaTapDeadline = nil
        guard config.mediaStripEnabled, config.mediaTapEnabled else { return [] }
        let liftTime = deadline - config.mediaTapConfirmDelay
        // A key pressed after the tap means the "tap" was a palm settling in to type.
        guard secondsSinceKeyDown > now - liftTime else { return [] }
        return [.media(.playPause)]
    }

    mutating func process(_ frame: TouchFrame) -> [GestureCommand] {
        let touching = frame.contacts.filter(\.isTouching)
        switch phase {
        case .idle:
            var out = tick(now: frame.timestamp, secondsSinceKeyDown: frame.secondsSinceKeyDown)
            guard !touching.isEmpty else { return out }
            // Any new touch before the confirm delay means the strip tap was part of something else.
            pendingMediaTapDeadline = nil
            if touching.count > 1 {
                lastCornerTapLift = nil
                phase = .blocked
                return out
            }
            out += begin(touching[0], frame: frame)
            return out

        case var .candidate(candidate):
            if touching.isEmpty {
                phase = .idle
                return lift(candidate, at: frame.timestamp)
            }
            guard touching.count == 1, touching[0].id == candidate.contactID else {
                lastCornerTapLift = nil
                phase = .blocked
                return []
            }
            return advance(&candidate, contact: touching[0], frame: frame)

        case var .sliding(slide):
            if touching.isEmpty {
                phase = .idle
                return [.slideEnded(slide.target)]
            }
            guard touching.count == 1, touching[0].id == slide.contactID else {
                phase = .blocked
                return [.slideEnded(slide.target)]
            }
            if config.requireModifier && !frame.modifiers.satisfiesSlideGate {
                phase = .consumed
                return [.slideEnded(slide.target)]
            }
            let touchAge = frame.timestamp - slide.startTime
            if frame.secondsSinceKeyDown <= touchAge {
                // Typing started while sliding: this is a palm settling, not a deliberate slide.
                phase = .consumed
                return [touchAge <= config.typingRevertWindow ? .slideCancelled(slide.target) : .slideEnded(slide.target)]
            }
            let out = step(&slide, y: touching[0].y, modifiers: frame.modifiers)
            phase = .sliding(slide)
            return out

        case .consumed, .blocked:
            if touching.isEmpty { phase = .idle }
            return []
        }
    }

    // MARK: - Phases

    private mutating func begin(_ contact: TouchContact, frame: TouchFrame) -> [GestureCommand] {
        if frame.secondsSinceKeyDown < config.typingGuard {
            // Landed while typing: almost certainly a resting palm.
            lastCornerTapLift = nil
            phase = .consumed
            return []
        }
        let zones = zones(x: contact.x, y: contact.y)
        guard !zones.isEmpty else {
            // An unrelated touch breaks a pending double tap.
            lastCornerTapLift = nil
            phase = .consumed
            return []
        }
        var isSecondTap = false
        if zones.contains(.muteCorner), let lastLift = lastCornerTapLift {
            isSecondTap = frame.timestamp - lastLift <= config.doubleTapWindow
        }
        if !zones.contains(.muteCorner) { lastCornerTapLift = nil }

        var candidate = Candidate(
            contactID: contact.id,
            startTime: frame.timestamp,
            startX: contact.x,
            startY: contact.y,
            lastX: contact.x,
            lastY: contact.y,
            zones: zones,
            buttonPressed: frame.buttonDown,
            isSecondCornerTap: isSecondTap
        )
        phase = .candidate(candidate)
        return advance(&candidate, contact: contact, frame: frame)
    }

    private mutating func advance(_ c: inout Candidate, contact: TouchContact, frame: TouchFrame) -> [GestureCommand] {
        if frame.secondsSinceKeyDown <= frame.timestamp - c.startTime {
            // A key was pressed after this touch began.
            lastCornerTapLift = nil
            phase = .consumed
            return []
        }
        c.lastX = contact.x
        c.lastY = contact.y
        if frame.buttonDown { c.buttonPressed = true }

        let dxMM = (contact.x - c.startX) * config.surfaceWidthMM
        let dyMM = (contact.y - c.startY) * config.surfaceHeightMM
        let adx = abs(dxMM)
        let ady = abs(dyMM)
        c.maxDistanceMM = max(c.maxDistanceMM, (dxMM * dxMM + dyMM * dyMM).squareRoot())
        let elapsed = frame.timestamp - c.startTime

        // 1. Edge slide.
        if !c.zones.intersection(.edges).isEmpty {
            // Give a sloppy second mute tap extra room so it is not stolen by the right-edge slide.
            let deadZone = c.isSecondCornerTap ? config.slideDeadZoneMM * 2 : config.slideDeadZoneMM
            if ady >= deadZone, ady >= adx * config.slideDirectionRatio, adx <= config.slideLateralToleranceMM {
                if c.buttonPressed || (config.requireModifier && !frame.modifiers.satisfiesSlideGate) {
                    // Click-drags and un-gated slides are ordinary pointer use.
                    phase = .consumed
                    return []
                }
                let left = c.zones.contains(.leftEdge)
                let fine = isFine(frame.modifiers)
                var slide = Slide(
                    contactID: c.contactID,
                    startTime: c.startTime,
                    target: config.target(forLeftEdge: left),
                    smoothedY: contact.y,
                    anchorY: c.startY,
                    fine: fine
                )
                var out: [GestureCommand] = [.slideBegan(slide.target)]
                out += step(&slide, y: contact.y, modifiers: frame.modifiers, smoothing: false)
                phase = .sliding(slide)
                return out
            }
            if adx > config.slideLateralToleranceMM {
                c.zones.subtract(.edges)
            }
        }

        // 2. Bottom-strip media swipe.
        if c.zones.contains(.bottomStrip) {
            if contact.y < config.stripTop - config.stripDriftTolerance || elapsed > config.swipeMaxDuration {
                c.zones.remove(.bottomStrip)
            } else if adx >= config.swipeMinDistance * config.surfaceWidthMM, adx >= ady * config.swipeDirectionRatio {
                phase = .consumed
                guard !c.buttonPressed else { return [] }
                return [.media(dxMM > 0 ? .next : .previous)]
            }
        }

        // 3. Still a possible tap?
        let tapPossible = !c.buttonPressed
            && c.maxDistanceMM <= config.tapMaxMovementMM
            && elapsed <= config.tapMaxDuration
            && (c.zones.contains(.muteCorner) || c.zones.contains(.bottomStrip) || stripTapEligible(c))

        if c.zones.intersection([.leftEdge, .rightEdge, .bottomStrip]).isEmpty && !tapPossible {
            if c.zones.contains(.muteCorner) { lastCornerTapLift = nil }
            phase = .consumed
            return []
        }
        phase = .candidate(c)
        return []
    }

    private func stripTapEligible(_ c: Candidate) -> Bool {
        config.mediaStripEnabled && config.mediaTapEnabled && c.startY >= config.stripTop
    }

    private mutating func lift(_ c: Candidate, at time: TimeInterval) -> [GestureCommand] {
        let duration = time - c.startTime
        let isTap = !c.buttonPressed && duration <= config.tapMaxDuration && c.maxDistanceMM <= config.tapMaxMovementMM

        if c.zones.contains(.muteCorner) {
            guard isTap else {
                lastCornerTapLift = nil
                return []
            }
            if c.isSecondCornerTap {
                lastCornerTapLift = nil
                return config.quickMuteEnabled ? [.toggleMute] : []
            }
            lastCornerTapLift = time
            return []
        }

        if stripTapEligible(c), isTap, duration <= config.mediaTapMaxDuration {
            pendingMediaTapDeadline = time + config.mediaTapConfirmDelay
        }
        return []
    }

    private mutating func step(_ s: inout Slide, y: Double, modifiers: ModifierState, smoothing: Bool = true) -> [GestureCommand] {
        if smoothing {
            s.smoothedY += (y - s.smoothedY) * config.smoothingFactor
        }
        let fine = isFine(modifiers)
        if fine != s.fine {
            // Re-anchor on a mode change so leftover travel in one unit is never replayed in the other.
            s.fine = fine
            s.anchorY = s.smoothedY
        }
        let perStep = config.stepTravelMM(fine: fine) / config.surfaceHeightMM
        guard perStep > 0 else { return [] }
        // Up the trackpad (decreasing y) raises the value.
        let travel = s.anchorY - s.smoothedY
        let steps = Int(travel / perStep)
        guard steps != 0 else { return [] }
        s.anchorY -= Double(steps) * perStep
        return [.adjust(s.target, steps: steps, fine: fine)]
    }

    private func isFine(_ modifiers: ModifierState) -> Bool {
        config.fineControlEnabled && modifiers.isFineChord
    }

    func zones(x: Double, y: Double) -> Zones {
        var zones: Zones = []
        let edgeAllowed = !config.bottomQuarterOnly || y >= config.bottomQuarterBoundary
        if edgeAllowed && x <= config.edgeWidth { zones.insert(.leftEdge) }
        if edgeAllowed && x >= 1 - config.edgeWidth { zones.insert(.rightEdge) }
        if config.quickMuteEnabled && x >= 1 - config.muteCornerWidth && y <= config.muteCornerHeight {
            zones.insert(.muteCorner)
        }
        if config.mediaStripEnabled && y >= config.stripTop { zones.insert(.bottomStrip) }
        return zones
    }
}
