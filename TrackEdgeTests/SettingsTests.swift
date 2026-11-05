import XCTest
@testable import TrackEdge

final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TrackEdgeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsMatchSpecification() {
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.hapticStrength, .strong)
        XCTAssertTrue(s.quickMuteEnabled)
        XCTAssertTrue(s.mediaStripEnabled)
        XCTAssertFalse(s.mediaTapEnabled)
        XCTAssertEqual(s.sensitivity, 1.5)
        XCTAssertEqual(s.edgeWidth, 0.05)
        XCTAssertFalse(s.swapSides)
        XCTAssertFalse(s.bottomQuarterOnly)
        XCTAssertFalse(s.requireModifier)
        XCTAssertTrue(s.freezeCursor)
        XCTAssertTrue(s.fineControl)
        XCTAssertEqual(s.appearance, .light)
        XCTAssertEqual(s.indicatorStyle, .trackEdge, "TrackEdge's bottom-centre indicator is the default")
        XCTAssertFalse(s.inspectorEnabled, "developer inspector must ship disabled")
        XCTAssertFalse(s.invertY)
    }

    func testValuesPersistImmediately() {
        let s = AppSettings(defaults: defaults)
        s.hapticStrength = .light
        s.swapSides = true
        s.sensitivity = 2.25
        s.edgeWidth = 0.08
        s.appearance = .dark
        s.mediaTapEnabled = true
        s.indicatorStyle = .system

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.hapticStrength, .light)
        XCTAssertTrue(reloaded.swapSides)
        XCTAssertEqual(reloaded.sensitivity, 2.25)
        XCTAssertEqual(reloaded.edgeWidth, 0.08)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertTrue(reloaded.mediaTapEnabled)
        XCTAssertEqual(reloaded.indicatorStyle, .system)
    }

    func testOutOfRangeValuesAreClampedAndQuantized() {
        let s = AppSettings(defaults: defaults)
        s.sensitivity = 9
        XCTAssertEqual(s.sensitivity, AppSettings.sensitivityRange.upperBound)
        s.sensitivity = 1.6
        XCTAssertEqual(s.sensitivity, 1.5)
        s.edgeWidth = 0.001
        XCTAssertEqual(s.edgeWidth, AppSettings.edgeWidthRange.lowerBound)
        s.edgeWidth = 0.0649
        XCTAssertEqual(s.edgeWidth, 0.06)

        defaults.set(-4.0, forKey: AppSettings.Key.sensitivity)
        defaults.set("bogus", forKey: AppSettings.Key.hapticStrength)
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.sensitivity, AppSettings.sensitivityRange.lowerBound)
        XCTAssertEqual(reloaded.hapticStrength, .strong)
    }

    func testSliderRangesMatchReferenceTicks() {
        // Reference shows 15 sensitivity positions with 1.5× at index 4, and 13 edge positions with 5 % at index 2.
        let sensTicks = Int(((AppSettings.sensitivityRange.upperBound - AppSettings.sensitivityRange.lowerBound) / AppSettings.sensitivityStep).rounded()) + 1
        XCTAssertEqual(sensTicks, 15)
        XCTAssertEqual((1.5 - AppSettings.sensitivityRange.lowerBound) / AppSettings.sensitivityStep, 4)
        let edgeTicks = Int(((AppSettings.edgeWidthRange.upperBound - AppSettings.edgeWidthRange.lowerBound) / AppSettings.edgeWidthStep).rounded()) + 1
        XCTAssertEqual(edgeTicks, 13)
    }

    func testResetRestoresDefaults() {
        let s = AppSettings(defaults: defaults)
        s.quickMuteEnabled = false
        s.freezeCursor = false
        s.sensitivity = 3
        s.inspectorEnabled = true
        s.resetToDefaults()
        XCTAssertTrue(s.quickMuteEnabled)
        XCTAssertTrue(s.freezeCursor)
        XCTAssertEqual(s.sensitivity, 1.5)
        XCTAssertFalse(s.inspectorEnabled)
        XCTAssertTrue(AppSettings(defaults: defaults).quickMuteEnabled)
    }

    func testGestureConfigReflectsSettings() {
        let s = AppSettings(defaults: defaults)
        s.swapSides = true
        s.bottomQuarterOnly = true
        s.requireModifier = true
        s.fineControl = false
        s.quickMuteEnabled = false
        s.mediaStripEnabled = false
        s.mediaTapEnabled = true
        s.edgeWidth = 0.1
        s.sensitivity = 2
        let c = s.gestureConfig
        XCTAssertTrue(c.swapSides)
        XCTAssertTrue(c.bottomQuarterOnly)
        XCTAssertTrue(c.requireModifier)
        XCTAssertFalse(c.fineControlEnabled)
        XCTAssertFalse(c.quickMuteEnabled)
        XCTAssertFalse(c.mediaStripEnabled)
        XCTAssertTrue(c.mediaTapEnabled)
        XCTAssertEqual(c.edgeWidth, 0.1)
        XCTAssertEqual(c.sensitivity, 2)
        XCTAssertEqual(c.target(forLeftEdge: true), .volume)
    }

    func testMediaTapChoicePreservedWhenStripDisabled() {
        let s = AppSettings(defaults: defaults)
        s.mediaTapEnabled = true
        s.mediaStripEnabled = false
        XCTAssertTrue(AppSettings(defaults: defaults).mediaTapEnabled)
    }

    func testVersionStringComesFromBundle() {
        XCTAssertFalse(AppInfo.version.isEmpty)
        XCTAssertNotEqual(AppInfo.shortVersion, "1.4")
    }
}
