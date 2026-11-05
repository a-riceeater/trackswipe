import Foundation

/// Keyboard-compatible level stepping. macOS volume/brightness keys move along a 1/16 grid, and
/// ⇧⌥ + key moves along a 1/64 grid. Every normal grid point is also a fine grid point, so switching
/// between modes mid-slide never jumps or drifts.
enum StepMath {
    static let normalDivisions = 16
    static let fineDivisions = 64
    /// Fraction of a grid unit treated as "already there". macOS's own keys skip a grid point that is
    /// less than ~0.1 step away (measured: brightness 0.6839 → up → 0.75, 0.4776 → up → 0.5), so a
    /// step always moves a meaningful amount and the predicted value matches what the keys produce.
    private static let epsilon = 0.1

    static func divisions(fine: Bool) -> Int { fine ? fineDivisions : normalDivisions }

    /// Moves `value` by `steps` grid positions, snapping off-grid values to the next grid point first
    /// in the direction of travel, and clamping to 0...1.
    static func apply(steps: Int, to value: Double, fine: Bool) -> Double {
        let n = Double(divisions(fine: fine))
        var v = clamp(value)
        if steps > 0 {
            for _ in 0..<steps {
                v = min(1, (floor(v * n + epsilon) + 1) / n)
            }
        } else if steps < 0 {
            for _ in 0..<(-steps) {
                v = max(0, (ceil(v * n - epsilon) - 1) / n)
            }
        }
        return v
    }

    /// Number of grid moves in `steps` that actually change the value before clamping at 0 or 1.
    static func effectiveSteps(_ steps: Int, from value: Double, fine: Bool) -> Int {
        var v = clamp(value)
        var count = 0
        let unit = steps > 0 ? 1 : -1
        for _ in 0..<abs(steps) {
            let next = apply(steps: unit, to: v, fine: fine)
            if abs(next - v) < 1e-9 { break }
            v = next
            count += 1
        }
        return count * unit
    }

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    /// Integer percentage for display; never shows 100 % unless the value is genuinely at the top.
    static func percent(_ value: Double) -> Int {
        let p = Int((clamp(value) * 100).rounded())
        return value < 0.995 ? min(p, 99) : p
    }
}
