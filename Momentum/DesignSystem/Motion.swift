import SwiftUI

/// Motion tokens (PRD §6.1). Principle: motion serves clarity and rewards effort;
/// restraint is the brand. Animate transforms only (opacity/scale/offset), never layout.
/// Honor Reduce Motion (callers should swap to crossfades / static iridescence).
enum Motion {
    // Durations
    static let instant = 0.10
    static let fast = 0.15
    static let normal = 0.25
    static let slow = 0.35
    static let slower = 0.50

    // Curves
    static let standard: Animation = .easeOut(duration: normal)   // entrances
    static let exit: Animation = .easeIn(duration: fast)
    static let reversible: Animation = .easeInOut(duration: normal)
    /// Selections, PR pops — minimal overshoot only (premium, not playful).
    static let lively: Animation = .spring(response: 0.4, dampingFraction: 0.72)

    /// Slow continuous drift for iridescence (~6–10s); never fast/strobing.
    static let iridescenceLoop = 8.0
}
