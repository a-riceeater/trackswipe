import XCTest
@testable import TrackEdge

final class StepMathTests: XCTestCase {
    func testNormalStepsAreSixteenths() {
        XCTAssertEqual(StepMath.apply(steps: 1, to: 0.5, fine: false), 0.5625, accuracy: 1e-9)
        XCTAssertEqual(StepMath.apply(steps: -1, to: 0.5, fine: false), 0.4375, accuracy: 1e-9)
    }

    func testFineStepsAreSixtyFourths() {
        XCTAssertEqual(StepMath.apply(steps: 1, to: 0.5, fine: true), 0.515625, accuracy: 1e-9)
        XCTAssertEqual(StepMath.apply(steps: -1, to: 0.5, fine: true), 0.484375, accuracy: 1e-9)
    }

    func testOffGridValuesSnapInDirectionOfTravel() {
        // Matches the observed macOS key behaviour: 0.4776 → up → 0.5, → down → 0.4375.
        XCTAssertEqual(StepMath.apply(steps: 1, to: 0.4776, fine: false), 0.5, accuracy: 1e-9)
        XCTAssertEqual(StepMath.apply(steps: -1, to: 0.4776, fine: false), 0.4375, accuracy: 1e-9)
    }

    func testClampsAtBounds() {
        XCTAssertEqual(StepMath.apply(steps: 5, to: 0.95, fine: false), 1)
        XCTAssertEqual(StepMath.apply(steps: -5, to: 0.05, fine: false), 0)
        XCTAssertEqual(StepMath.apply(steps: 1, to: 1, fine: true), 1)
        XCTAssertEqual(StepMath.apply(steps: -1, to: 0, fine: true), 0)
        XCTAssertEqual(StepMath.apply(steps: 1, to: 1.7, fine: false), 1)
        XCTAssertEqual(StepMath.apply(steps: -1, to: -0.3, fine: false), 0)
    }

    func testEffectiveStepsStopAtLimit() {
        XCTAssertEqual(StepMath.effectiveSteps(5, from: 0.875, fine: false), 2)
        XCTAssertEqual(StepMath.effectiveSteps(-3, from: 0, fine: false), 0)
        XCTAssertEqual(StepMath.effectiveSteps(-3, from: 0.0625, fine: false), -1)
    }

    func testFourQuarterStepsEqualOneNormalStepWithoutDrift() {
        var v = 0.25
        for _ in 0..<4 { v = StepMath.apply(steps: 1, to: v, fine: true) }
        XCTAssertEqual(v, StepMath.apply(steps: 1, to: 0.25, fine: false), accuracy: 1e-12)
        // Long alternating sequences return exactly to the start.
        var w = 0.5
        for i in 0..<1000 {
            w = StepMath.apply(steps: i.isMultiple(of: 2) ? 1 : -1, to: w, fine: i % 3 == 0)
        }
        XCTAssertEqual(w * 64, (w * 64).rounded(), accuracy: 1e-9, "value stays on the 1/64 grid")
    }

    func testSwitchingModesMidwayNeverJumpsMoreThanOneStep() {
        var v = 0.3
        for i in 0..<200 {
            let fine = i % 5 < 2
            let next = StepMath.apply(steps: 1, to: v, fine: fine)
            XCTAssertLessThanOrEqual(next - v, 1.0 / 16 + 1e-9)
            v = next
        }
    }

    func testPercentDisplay() {
        XCTAssertEqual(StepMath.percent(0.5625), 56)
        XCTAssertEqual(StepMath.percent(0.994), 99)
        XCTAssertEqual(StepMath.percent(1), 100)
        XCTAssertEqual(StepMath.percent(0), 0)
    }
}

// MARK: - Dispatcher with mocks

private final class MockLevel: LevelControlling, MuteControlling {
    var value: Double
    var began = 0, ended = 0, muteToggles = 0
    init(_ value: Double) { self.value = value }
    func beginAdjust() { began += 1 }
    func adjust(steps: Int, fine: Bool) -> AdjustResult? {
        let next = StepMath.apply(steps: steps, to: value, fine: fine)
        defer { value = next }
        return AdjustResult(changed: next != value, value: next)
    }
    func endAdjust() { ended += 1 }
    func toggleMute() -> Bool { muteToggles += 1; return true }
}

private final class MockMedia: MediaControlling {
    var sent: [MediaCommand] = []
    func send(_ command: MediaCommand) -> Bool { sent.append(command); return true }
}

private final class MockHaptics: HapticPerforming {
    var count = 0
    var strengths: [HapticStrength] = []
    func perform(_ strength: HapticStrength, on deviceID: UInt64?) {
        guard strength != .off else { return }
        count += 1
        strengths.append(strength)
    }
}

private final class MockCursor: CursorFreezing {
    var isFrozen = false
    var freezes = 0, releases = 0, maintains = 0
    func freeze() { isFrozen = true; freezes += 1 }
    func maintain() { maintains += 1 }
    func release() { isFrozen = false; releases += 1 }
}

final class ActionDispatcherTests: XCTestCase {
    private var volume = MockLevel(0.5)
    private var brightness = MockLevel(0.5)
    private var media = MockMedia()
    private var haptics = MockHaptics()
    private var cursor = MockCursor()
    private var dispatcher: ActionDispatcher!

    override func setUp() {
        super.setUp()
        volume = MockLevel(0.5)
        brightness = MockLevel(0.5)
        media = MockMedia()
        haptics = MockHaptics()
        cursor = MockCursor()
        dispatcher = ActionDispatcher(volume: volume, brightness: brightness, media: media, haptics: haptics, cursor: cursor,
                                      queue: DispatchQueue(label: "test"), minimumWriteInterval: 0)
    }

    func testSlideFreezesAndReleasesCursor() {
        dispatcher.executeNow([.slideBegan(.volume)], deviceID: 1)
        XCTAssertTrue(cursor.isFrozen)
        dispatcher.executeNow([.adjust(.volume, steps: 2, fine: false), .slideEnded(.volume)], deviceID: 1)
        XCTAssertFalse(cursor.isFrozen)
        XCTAssertEqual(volume.value, 0.625, accuracy: 1e-9)
        XCTAssertEqual(volume.began, 1)
        XCTAssertEqual(volume.ended, 1)
    }

    func testFreezeCursorDisabled() {
        dispatcher.options = .init(freezeCursor: false, haptics: .strong)
        dispatcher.executeNow([.slideBegan(.brightness)], deviceID: 1)
        XCTAssertEqual(cursor.freezes, 0)
        dispatcher.slideFrame()
        XCTAssertEqual(cursor.maintains, 0)
    }

    func testDisablingFreezeMidSlideReleasesImmediately() {
        dispatcher.executeNow([.slideBegan(.volume)], deviceID: 1)
        dispatcher.options = .init(freezeCursor: false, haptics: .strong)
        XCTAssertFalse(cursor.isFrozen)
    }

    func testHapticOnlyWhenValueChanges() {
        volume.value = 0.9375
        dispatcher.executeNow([.slideBegan(.volume), .adjust(.volume, steps: 1, fine: false)], deviceID: 1)
        XCTAssertEqual(haptics.count, 1)
        dispatcher.executeNow([.adjust(.volume, steps: 1, fine: false), .adjust(.volume, steps: 1, fine: false)], deviceID: 1)
        XCTAssertEqual(volume.value, 1)
        XCTAssertEqual(haptics.count, 1, "no ticks while pinned at 100 %")
    }

    func testHapticsOffMeansNone() {
        dispatcher.options = .init(freezeCursor: true, haptics: .off)
        dispatcher.executeNow([.slideBegan(.volume), .adjust(.volume, steps: 3, fine: false), .toggleMute, .media(.next)], deviceID: 1)
        XCTAssertEqual(haptics.count, 0)
    }

    func testAdjustForInactiveTargetIgnored() {
        dispatcher.executeNow([.slideBegan(.volume), .adjust(.brightness, steps: 3, fine: false)], deviceID: 1)
        XCTAssertEqual(brightness.value, 0.5)
    }

    func testMuteAndMediaRouted() {
        dispatcher.executeNow([.toggleMute, .media(.previous), .media(.playPause)], deviceID: 1)
        XCTAssertEqual(volume.muteToggles, 1)
        XCTAssertEqual(media.sent, [.previous, .playPause])
        XCTAssertEqual(haptics.count, 3)
    }

    func testAbortReleasesCursorAndEndsSlide() {
        dispatcher.executeNow([.slideBegan(.brightness)], deviceID: 1)
        dispatcher.abortAll()
        XCTAssertFalse(cursor.isFrozen)
        XCTAssertFalse(dispatcher.isSlideActive)
        XCTAssertEqual(brightness.ended, 1)
    }

    func testEndToEndRecognizerToDispatcherClampsAndStaysOnGrid() {
        var config = GestureConfig()
        config.surfaceWidthMM = 100
        config.surfaceHeightMM = 70
        var r = GestureRecognizer(config: config)
        brightness.value = 0.1
        var t = 0.0
        func send(_ y: Double?) {
            t += 0.01
            let contacts = y.map { [TouchContact(id: 1, x: 0.02, y: $0)] } ?? []
            dispatcher.executeNow(r.process(TouchFrame(timestamp: t, contacts: contacts)), deviceID: 1)
        }
        // Slide all the way down and keep pushing: must clamp at exactly 0 %.
        for i in 0...60 { send(0.05 + 0.9 * Double(i) / 60) }
        for _ in 0..<10 { send(0.95) }
        send(nil)
        XCTAssertEqual(brightness.value, 0)
        XCTAssertFalse(cursor.isFrozen)
    }
}
