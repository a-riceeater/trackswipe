import XCTest
@testable import TrackEdge

/// Synthetic-contact tests for the pure recognizer. Geometry: 100 × 70 mm surface, so 0.01 in x = 1 mm
/// and 0.01 in y = 0.7 mm. Default sensitivity 1.5× → 4 mm per normal step (≈ 0.0571 in y).
final class GestureRecognizerTests: XCTestCase {
    private var config = GestureConfig()
    private var t: TimeInterval = 100

    override func setUp() {
        super.setUp()
        config = GestureConfig()
        config.surfaceWidthMM = 100
        config.surfaceHeightMM = 70
        t = 100
    }

    // MARK: Helpers

    private func frame(_ contacts: [TouchContact], dt: TimeInterval = 0.01, mods: ModifierState = .none, button: Bool = false) -> TouchFrame {
        t += dt
        return TouchFrame(timestamp: t, contacts: contacts, modifiers: mods, buttonDown: button)
    }

    private func touch(_ x: Double, _ y: Double, id: Int = 1) -> TouchContact {
        TouchContact(id: id, x: x, y: y)
    }

    /// Drives one finger along a path, returning every emitted command (including the lift).
    @discardableResult
    private func drag(_ r: inout GestureRecognizer, from start: (Double, Double), to end: (Double, Double),
                      frames: Int = 40, dt: TimeInterval = 0.01, mods: ModifierState = .none, id: Int = 1,
                      lift: Bool = true, button: Bool = false) -> [GestureCommand] {
        var out: [GestureCommand] = []
        for i in 0...frames {
            let f = Double(i) / Double(frames)
            let x = start.0 + (end.0 - start.0) * f
            let y = start.1 + (end.1 - start.1) * f
            out += r.process(frame([touch(x, y, id: id)], dt: dt, mods: mods, button: button))
        }
        // Let smoothing settle on the final point.
        for _ in 0..<10 { out += r.process(frame([touch(end.0, end.1, id: id)], dt: dt, mods: mods, button: button)) }
        if lift { out += r.process(frame([], dt: dt, mods: mods)) }
        return out
    }

    private func tap(_ r: inout GestureRecognizer, at p: (Double, Double), duration: TimeInterval = 0.08, id: Int = 1, button: Bool = false) -> [GestureCommand] {
        var out = r.process(frame([touch(p.0, p.1, id: id)], dt: 0.01, button: button))
        out += r.process(frame([touch(p.0, p.1, id: id)], dt: duration, button: button))
        out += r.process(frame([], dt: 0.01))
        return out
    }

    private func totalSteps(_ commands: [GestureCommand], _ target: SlideTarget? = nil) -> Int {
        commands.reduce(0) { sum, c in
            if case let .adjust(tg, steps, _) = c, target == nil || tg == target { return sum + steps }
            return sum
        }
    }

    // MARK: Edge zones & direction

    func testRightEdgeUpSlideRaisesVolume() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.98, 0.7), to: (0.98, 0.28))
        XCTAssertEqual(out.first, .slideBegan(.volume))
        XCTAssertEqual(out.last, .slideEnded(.volume))
        // 0.42 × 70 mm = 29.4 mm at 4 mm/step = 7 whole steps.
        XCTAssertEqual(totalSteps(out, .volume), 7)
    }

    func testLeftEdgeDownSlideLowersBrightness() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.02, 0.2), to: (0.02, 0.62))
        XCTAssertEqual(out.first, .slideBegan(.brightness))
        XCTAssertEqual(totalSteps(out, .brightness), -7)
    }

    func testSwapSidesFlipsTargets() {
        config.swapSides = true
        var r = GestureRecognizer(config: config)
        XCTAssertEqual(drag(&r, from: (0.02, 0.7), to: (0.02, 0.3)).first, .slideBegan(.volume))
        XCTAssertEqual(drag(&r, from: (0.98, 0.7), to: (0.98, 0.3)).first, .slideBegan(.brightness))
    }

    func testTouchOutsideEdgeIsIgnored() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.5, 0.7), to: (0.5, 0.2))
        XCTAssertTrue(out.isEmpty)
    }

    func testEdgeWidthIsRespected() {
        config.edgeWidth = 0.05
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(drag(&r, from: (0.07, 0.7), to: (0.07, 0.3)).isEmpty, "7 % is outside a 5 % edge")
        config.edgeWidth = 0.10
        r.update(config: config)
        XCTAssertEqual(drag(&r, from: (0.07, 0.7), to: (0.07, 0.3)).first, .slideBegan(.brightness))
        XCTAssertEqual(drag(&r, from: (0.92, 0.7), to: (0.92, 0.3)).first, .slideBegan(.volume))
    }

    func testBottomQuarterOnlyRejectsUpperEdgeStarts() {
        config.bottomQuarterOnly = true
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(drag(&r, from: (0.98, 0.5), to: (0.98, 0.2)).isEmpty)
        let out = drag(&r, from: (0.98, 0.9), to: (0.98, 0.6))
        XCTAssertEqual(out.first, .slideBegan(.volume))
        XCTAssertGreaterThan(totalSteps(out), 0)
    }

    func testBottomQuarterOnlyKeepsMediaStripWorking() {
        config.bottomQuarterOnly = true
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.3, 0.97), to: (0.6, 0.97), frames: 20)
        XCTAssertEqual(out, [.media(.next)])
    }

    // MARK: Thresholds, jitter, dead zone

    func testDeadZoneJitterNeverActivates() {
        var r = GestureRecognizer(config: config)
        var out: [GestureCommand] = []
        // ±1 mm vertical jitter (dead zone is 2 mm) for half a second.
        for i in 0..<50 {
            let y = 0.5 + (i.isMultiple(of: 2) ? 0.014 : -0.014) / 2
            out += r.process(frame([touch(0.98, y)]))
        }
        out += r.process(frame([]))
        XCTAssertTrue(out.isEmpty)
    }

    func testMostlyHorizontalMotionFromEdgeIsPointerUse() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.98, 0.5), to: (0.70, 0.45))
        XCTAssertTrue(out.isEmpty)
    }

    func testJitterAroundStepBoundaryDoesNotOscillate() {
        var r = GestureRecognizer(config: config)
        var out: [GestureCommand] = []
        // Activate and move exactly one step (4 mm ≈ 0.0571) upward.
        for i in 0...20 { out += r.process(frame([touch(0.98, 0.6 - 0.0600 * Double(i) / 20)])) }
        for _ in 0..<10 { out += r.process(frame([touch(0.98, 0.54)])) }
        XCTAssertEqual(totalSteps(out), 1)
        // Now jitter ±0.5 mm around that point for a while: no further steps either way.
        var jitter: [GestureCommand] = []
        for i in 0..<60 {
            jitter += r.process(frame([touch(0.98, 0.54 + (i.isMultiple(of: 2) ? 0.007 : -0.007))]))
        }
        XCTAssertTrue(jitter.filter { if case .adjust = $0 { return true }; return false }.isEmpty)
    }

    func testRelativeMotionNeverJumps() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.98, 0.95), to: (0.98, 0.93), frames: 10)
        // 1.4 mm is inside the dead zone; starting low on the pad must not imply a low absolute value.
        XCTAssertTrue(out.filter { if case .adjust = $0 { return true }; return false }.isEmpty)
    }

    func testSensitivityScalesSteps() {
        config.sensitivity = 3.0 // 2 mm per step
        var r = GestureRecognizer(config: config)
        XCTAssertEqual(totalSteps(drag(&r, from: (0.98, 0.7), to: (0.98, 0.28))), 14)
    }

    func testDirectionReversalMidSlide() {
        var r = GestureRecognizer(config: config)
        var out = drag(&r, from: (0.98, 0.7), to: (0.98, 0.28), lift: false)
        XCTAssertEqual(totalSteps(out), 7)
        // Coming back past the start undoes exactly the steps taken (hysteresis keeps the remainder).
        out += drag(&r, from: (0.98, 0.28), to: (0.98, 0.72))
        XCTAssertEqual(totalSteps(out), 0)
    }

    // MARK: Multi-finger & contact IDs

    func testSecondFingerCancelsSlide() {
        var r = GestureRecognizer(config: config)
        var out = drag(&r, from: (0.98, 0.7), to: (0.98, 0.5), lift: false)
        XCTAssertEqual(out.first, .slideBegan(.volume))
        out = r.process(frame([touch(0.98, 0.5), touch(0.5, 0.5, id: 2)]))
        XCTAssertEqual(out, [.slideEnded(.volume)])
        // Remaining finger moving keeps nothing alive until everything lifts.
        out = drag(&r, from: (0.98, 0.5), to: (0.98, 0.1), lift: false)
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(r.process(frame([])).isEmpty)
        XCTAssertEqual(r.phase, .idle)
    }

    func testTwoFingerScrollAtEdgeIsIgnored() {
        var r = GestureRecognizer(config: config)
        var out: [GestureCommand] = []
        for i in 0...30 {
            let y = 0.7 - 0.4 * Double(i) / 30
            out += r.process(frame([touch(0.98, y), touch(0.90, y, id: 2)]))
        }
        out += r.process(frame([]))
        XCTAssertTrue(out.isEmpty)
    }

    func testContactIDChangeCancels() {
        var r = GestureRecognizer(config: config)
        _ = drag(&r, from: (0.98, 0.7), to: (0.98, 0.5), lift: false)
        XCTAssertEqual(r.process(frame([touch(0.98, 0.45, id: 9)])), [.slideEnded(.volume)])
    }

    func testCancelEndsActiveSlide() {
        var r = GestureRecognizer(config: config)
        _ = drag(&r, from: (0.98, 0.7), to: (0.98, 0.5), lift: false)
        XCTAssertEqual(r.cancel(), [.slideEnded(.volume)])
        XCTAssertEqual(r.phase, .blocked)
        XCTAssertTrue(drag(&r, from: (0.98, 0.5), to: (0.98, 0.2), lift: false).isEmpty)
    }

    func testClickDragAlongEdgeIsRejected() {
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(drag(&r, from: (0.98, 0.7), to: (0.98, 0.3), button: true).isEmpty)
    }

    // MARK: Modifier gating & fine control

    func testRequireModifierGatesSlides() {
        config.requireModifier = true
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(drag(&r, from: (0.98, 0.7), to: (0.98, 0.3)).isEmpty)
        XCTAssertEqual(drag(&r, from: (0.98, 0.7), to: (0.98, 0.3), mods: ModifierState(option: true)).first, .slideBegan(.volume))
        XCTAssertEqual(drag(&r, from: (0.02, 0.7), to: (0.02, 0.3), mods: ModifierState(function: true)).first, .slideBegan(.brightness))
    }

    func testReleasingRequiredModifierEndsSlide() {
        config.requireModifier = true
        var r = GestureRecognizer(config: config)
        _ = drag(&r, from: (0.98, 0.7), to: (0.98, 0.5), mods: ModifierState(option: true), lift: false)
        XCTAssertEqual(r.process(frame([touch(0.98, 0.45)])), [.slideEnded(.volume)])
    }

    func testRequireModifierDoesNotGateTapsOrStrip() {
        config.requireModifier = true
        var r = GestureRecognizer(config: config)
        XCTAssertEqual(drag(&r, from: (0.3, 0.97), to: (0.6, 0.97), frames: 20), [.media(.next)])
        _ = tap(&r, at: (0.95, 0.05))
        XCTAssertEqual(tap(&r, at: (0.95, 0.05)), [.toggleMute])
    }

    func testFineControlUsesQuarterStepsWithShiftOption() {
        var r = GestureRecognizer(config: config)
        let mods = ModifierState(shift: true, option: true)
        let out = drag(&r, from: (0.98, 0.7), to: (0.98, 0.28), mods: mods)
        let adjusts = out.compactMap { c -> (Int, Bool)? in
            if case let .adjust(_, s, fine) = c { return (s, fine) }
            return nil
        }
        XCTAssertFalse(adjusts.isEmpty)
        XCTAssertTrue(adjusts.allSatisfy { $0.1 })
        // Fine steps need half the travel: 29.4 mm / 2 mm = 14 quarter steps.
        XCTAssertEqual(adjusts.reduce(0) { $0 + $1.0 }, 14)
    }

    func testFineControlDisabledIgnoresChord() {
        config.fineControlEnabled = false
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.98, 0.7), to: (0.98, 0.3), mods: ModifierState(shift: true, option: true))
        XCTAssertTrue(out.allSatisfy { if case let .adjust(_, _, fine) = $0 { return !fine }; return true })
    }

    func testOptionAloneIsNotFine() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.98, 0.7), to: (0.98, 0.28), mods: ModifierState(option: true))
        XCTAssertEqual(totalSteps(out), 7)
    }

    // MARK: Quick Mute

    func testDoubleTapTopRightTogglesMute() {
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(tap(&r, at: (0.95, 0.05)).isEmpty)
        t += 0.12
        XCTAssertEqual(tap(&r, at: (0.95, 0.06)), [.toggleMute])
        // A third tap starts a fresh sequence.
        t += 0.12
        XCTAssertTrue(tap(&r, at: (0.95, 0.05)).isEmpty)
    }

    func testSlowDoubleTapDoesNotMute() {
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.95, 0.05))
        t += 0.6
        XCTAssertTrue(tap(&r, at: (0.95, 0.05)).isEmpty)
    }

    func testLongPressInCornerIsNotATap() {
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.95, 0.05), duration: 0.5)
        t += 0.1
        XCTAssertTrue(tap(&r, at: (0.95, 0.05)).isEmpty)
    }

    func testPhysicalClicksInCornerDoNotMute() {
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.95, 0.05), button: true)
        t += 0.1
        XCTAssertTrue(tap(&r, at: (0.95, 0.05), button: true).isEmpty)
    }

    func testTapElsewhereBreaksDoubleTap() {
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.95, 0.05))
        t += 0.05
        _ = tap(&r, at: (0.5, 0.5))
        t += 0.05
        XCTAssertTrue(tap(&r, at: (0.95, 0.05)).isEmpty)
    }

    func testQuickMuteDisabled() {
        config.quickMuteEnabled = false
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.95, 0.05))
        t += 0.1
        XCTAssertTrue(tap(&r, at: (0.95, 0.05)).isEmpty)
    }

    func testCornerSlideStillControlsVolume() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.98, 0.08), to: (0.98, 0.5))
        XCTAssertEqual(out.first, .slideBegan(.volume))
        XCTAssertLessThan(totalSteps(out), 0)
    }

    func testSloppySecondTapPrefersMuteOverSlide() {
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.98, 0.05))
        t += 0.1
        // Second tap drifts 2.5 mm vertically: past the normal dead zone, but within the doubled one.
        var out = r.process(frame([touch(0.98, 0.05)]))
        out += r.process(frame([touch(0.98, 0.05 + 2.5 / 70)], dt: 0.03))
        out += r.process(frame([], dt: 0.01))
        XCTAssertFalse(out.contains(.slideBegan(.volume)))
    }

    // MARK: Media strip

    func testStripSwipeRightIsNextOncePerStroke() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.2, 0.97), to: (0.8, 0.97), frames: 30)
        XCTAssertEqual(out, [.media(.next)])
    }

    func testStripSwipeLeftIsPrevious() {
        var r = GestureRecognizer(config: config)
        XCTAssertEqual(drag(&r, from: (0.7, 0.98), to: (0.4, 0.98), frames: 20), [.media(.previous)])
    }

    func testShortStripSwipeIgnored() {
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(drag(&r, from: (0.5, 0.97), to: (0.58, 0.97), frames: 10).isEmpty)
    }

    func testSlowStripDragIgnored() {
        var r = GestureRecognizer(config: config)
        // 0.1 width/s reaches the 12 % threshold after 1.2 s, beyond the 0.8 s swipe limit.
        XCTAssertTrue(drag(&r, from: (0.2, 0.97), to: (0.4, 0.97), frames: 100, dt: 0.02).isEmpty)
    }

    func testSwipeStartingAboveStripIgnored() {
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(drag(&r, from: (0.2, 0.85), to: (0.8, 0.85), frames: 20).isEmpty)
    }

    func testStripDisabled() {
        config.mediaStripEnabled = false
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(drag(&r, from: (0.2, 0.97), to: (0.8, 0.97), frames: 20).isEmpty)
    }

    func testBottomCornerVerticalMotionIsSlideNotMedia() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.98, 0.97), to: (0.98, 0.6))
        XCTAssertEqual(out.first, .slideBegan(.volume))
        XCTAssertFalse(out.contains(.media(.next)))
    }

    func testBottomCornerHorizontalMotionIsMediaNotSlide() {
        var r = GestureRecognizer(config: config)
        let out = drag(&r, from: (0.98, 0.97), to: (0.7, 0.97), frames: 20)
        XCTAssertEqual(out, [.media(.previous)])
    }

    func testStripTapIsOffByDefault() {
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(tap(&r, at: (0.5, 0.97)).isEmpty)
        XCTAssertNil(r.pendingMediaTapDeadline)
    }

    func testStripTapPlaysAfterQuietPeriod() {
        config.mediaTapEnabled = true
        var r = GestureRecognizer(config: config)
        XCTAssertTrue(tap(&r, at: (0.5, 0.97)).isEmpty)
        let deadline = try! XCTUnwrap(r.pendingMediaTapDeadline)
        XCTAssertTrue(r.tick(now: deadline - 0.01).isEmpty)
        XCTAssertEqual(r.tick(now: deadline), [.media(.playPause)])
        XCTAssertTrue(r.tick(now: deadline + 1).isEmpty, "fires once")
    }

    func testStripDoubleTapCancelsPlayPause() {
        config.mediaTapEnabled = true
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.5, 0.97))
        t += 0.1
        _ = tap(&r, at: (0.5, 0.97))
        // The second tap re-queues; the first never fired.
        XCTAssertNotNil(r.pendingMediaTapDeadline)
        XCTAssertEqual(r.tick(now: r.pendingMediaTapDeadline!), [.media(.playPause)])
    }

    func testStripClickDoesNotPlay() {
        config.mediaTapEnabled = true
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.5, 0.97), button: true)
        XCTAssertNil(r.pendingMediaTapDeadline)
    }

    func testStripTapCancelledWhenDisabledBeforeDeadline() {
        config.mediaTapEnabled = true
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.5, 0.97))
        config.mediaTapEnabled = false
        r.update(config: config)
        XCTAssertTrue(r.tick(now: t + 1).isEmpty)
    }

    // MARK: Typing palm rejection

    private func frame(_ contacts: [TouchContact], sinceKey: TimeInterval, dt: TimeInterval = 0.01) -> TouchFrame {
        t += dt
        return TouchFrame(timestamp: t, contacts: contacts, secondsSinceKeyDown: sinceKey)
    }

    func testTouchStartingWhileTypingIsIgnoredUntilLift() {
        var r = GestureRecognizer(config: config)
        var out: [GestureCommand] = []
        // Palm lands 0.2 s after a keystroke, then keeps sliding long after typing stops.
        for i in 0...60 {
            out += r.process(frame([touch(0.98, 0.7 - 0.4 * Double(i) / 60)], sinceKey: 0.2 + 0.01 * Double(i)))
        }
        out += r.process(frame([], sinceKey: 2))
        XCTAssertTrue(out.isEmpty)
        // After the guard, a fresh deliberate slide works.
        XCTAssertEqual(drag(&r, from: (0.98, 0.7), to: (0.98, 0.3)).first, .slideBegan(.volume))
    }

    func testKeyPressDuringCandidateCancelsTouch() {
        var r = GestureRecognizer(config: config)
        var out = r.process(frame([touch(0.98, 0.7)], sinceKey: 5))
        // A key is pressed 0.05 s after the touch began; the finger then moves.
        out += r.process(frame([touch(0.98, 0.7)], sinceKey: 0.0, dt: 0.05))
        for i in 1...30 { out += r.process(frame([touch(0.98, 0.7 - 0.4 * Double(i) / 30)], sinceKey: 0.01 * Double(i))) }
        out += r.process(frame([], sinceKey: 1))
        XCTAssertTrue(out.isEmpty)
    }

    func testTypingShortlyAfterSlideStartUndoesIt() {
        var r = GestureRecognizer(config: config)
        var out: [GestureCommand] = []
        for i in 0...20 { out += r.process(frame([touch(0.02, 0.7 - 0.2 * Double(i) / 20)], sinceKey: 10 + 0.01 * Double(i))) }
        XCTAssertEqual(out.first, .slideBegan(.brightness))
        XCTAssertEqual(r.process(frame([touch(0.02, 0.5)], sinceKey: 0.0)), [.slideCancelled(.brightness)])
        XCTAssertTrue(r.process(frame([touch(0.02, 0.3)], sinceKey: 0.01)).isEmpty)
    }

    func testTypingLongAfterSlideStartJustEndsIt() {
        var r = GestureRecognizer(config: config)
        _ = r.process(frame([touch(0.98, 0.7)], sinceKey: 30))
        _ = r.process(frame([touch(0.98, 0.6)], sinceKey: 30))
        for _ in 0..<200 { _ = r.process(frame([touch(0.98, 0.6)], sinceKey: 30)) }
        XCTAssertEqual(r.process(frame([touch(0.98, 0.6)], sinceKey: 0.0)), [.slideEnded(.volume)])
    }

    func testCornerTapsWhileTypingNeverMute() {
        var r = GestureRecognizer(config: config)
        var out: [GestureCommand] = []
        for _ in 0..<2 {
            out += r.process(frame([touch(0.95, 0.05)], sinceKey: 0.3))
            out += r.process(frame([touch(0.95, 0.05)], sinceKey: 0.38, dt: 0.08))
            out += r.process(frame([], sinceKey: 0.39))
        }
        XCTAssertTrue(out.isEmpty)
    }

    func testStripTapFollowedByTypingDoesNotPlay() {
        config.mediaTapEnabled = true
        var r = GestureRecognizer(config: config)
        _ = tap(&r, at: (0.5, 0.97))
        let deadline = try! XCTUnwrap(r.pendingMediaTapDeadline)
        // A key was pressed 0.1 s before the deadline, i.e. after the tap lifted.
        XCTAssertTrue(r.tick(now: deadline, secondsSinceKeyDown: 0.1).isEmpty)
    }

    // MARK: Normalisation

    func testNormalizerFlipsY() {
        let p = TouchNormalizer.normalize(rawX: 0.25, rawY: 0.1)
        XCTAssertEqual(p.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.9, accuracy: 1e-9)
        XCTAssertEqual(TouchNormalizer.normalize(rawX: 0.25, rawY: 0.1, invertY: true).y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(TouchNormalizer.normalize(rawX: -1, rawY: 2).x, 0)
    }
}
