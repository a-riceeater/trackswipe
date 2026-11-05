import Foundation

/// Immutable recognizer configuration: user settings plus physical device geometry and tuning thresholds.
/// Distances that should feel identical across trackpad sizes are expressed in millimetres.
struct GestureConfig: Equatable, Sendable {
    // MARK: User settings
    var edgeWidth: Double = 0.05
    var sensitivity: Double = 1.5
    var swapSides = false
    var bottomQuarterOnly = false
    var requireModifier = false
    var fineControlEnabled = true
    var quickMuteEnabled = true
    var mediaStripEnabled = true
    var mediaTapEnabled = false

    // MARK: Device geometry (millimetres)
    var surfaceWidthMM: Double = 100
    var surfaceHeightMM: Double = 70

    // MARK: Slide tuning
    /// Vertical travel required before an edge touch becomes a slide.
    var slideDeadZoneMM = 2.0
    /// Horizontal noise allowed before the slide decision; more lateral travel means ordinary pointer motion.
    var slideLateralToleranceMM = 3.5
    /// Vertical travel must dominate horizontal travel by this ratio to activate.
    var slideDirectionRatio = 1.5
    /// Finger travel per 1/16 step at 1.0× sensitivity.
    var baseStepTravelMM = 6.0
    /// Fine (1/64) steps need this fraction of the normal per-step travel.
    var fineTravelFactor = 0.5
    /// Exponential smoothing weight of the newest y sample (1 = no smoothing).
    var smoothingFactor = 0.6
    var bottomQuarterBoundary = 0.75

    // MARK: Quick Mute tuning
    var muteCornerWidth = 0.12
    var muteCornerHeight = 0.12
    var tapMaxDuration = 0.22
    var tapMaxMovementMM = 1.8
    /// Maximum gap between the first tap lifting and the second tap landing.
    var doubleTapWindow = 0.35

    // MARK: Media Strip tuning
    var stripTop = 0.95
    /// A swipe may drift this far above the strip before it stops counting.
    var stripDriftTolerance = 0.07
    /// Minimum horizontal swipe distance as a fraction of the surface width.
    var swipeMinDistance = 0.12
    var swipeMaxDuration = 0.8
    var swipeDirectionRatio = 2.0
    var mediaTapMaxDuration = 0.18
    /// A strip tap only fires once no new touch arrives within this delay (rejects double taps / clicks).
    var mediaTapConfirmDelay = 0.3

    // MARK: Derived
    var stepTravelMM: Double { baseStepTravelMM / max(sensitivity, 0.1) }

    func stepTravelMM(fine: Bool) -> Double {
        fine ? stepTravelMM * fineTravelFactor : stepTravelMM
    }

    func target(forLeftEdge left: Bool) -> SlideTarget {
        switch (left, swapSides) {
        case (true, false), (false, true): return .brightness
        default: return .volume
        }
    }
}
