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

    // MARK: Onboarding motion system (see docs/ONBOARDING-MOTION-PLAN.md §3)
    // One shared vocabulary so every onboarding beat — and every hero draw — moves with the same hand.

    /// Element reveals / the assemble cascade.
    static let entrance: Animation = .easeOut(duration: slower)
    /// Step-to-step directional travel.
    static let travel: Animation = .spring(response: 0.5, dampingFraction: 0.86)
    /// The "drawing pen": eases gently out of the start and decelerates into the finish. Every hero
    /// line/ring that *draws itself* (welcome route, projection curve, commitment ring) shares it.
    static func pen(_ duration: Double) -> Animation { .timingCurve(0.42, 0.0, 0.22, 1.0, duration: duration) }
}
