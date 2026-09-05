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

    // Everyday interactions. Keep these separate from the slower, earned/onboarding beats.
    static let pressedScale: CGFloat = 0.98
    static let pressIn: Animation = .easeOut(duration: instant)
    static let pressRelease: Animation = .spring(response: 0.24, dampingFraction: 0.9)
    static let selection: Animation = .easeInOut(duration: 0.18)
    static let panel: Animation = .spring(response: 0.28, dampingFraction: 0.92)
    static let content: Animation = .easeOut(duration: 0.22)
    static let crossfade: Animation = .easeOut(duration: fast)

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

/// Shared tactile response for native buttons AND the map's gesture-backed controls. Scope the
/// animation to these transforms, so a press never animates the label's layout or new data.
struct PressFeedback: ViewModifier {
    let isPressed: Bool
    var scale: CGFloat = Motion.pressedScale
    @ReducedMotionPreference private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(isPressed ? Motion.pressIn : Motion.pressRelease) { view in
            view
                .scaleEffect(isPressed && !reduceMotion ? scale : 1)
                .opacity(isPressed ? 0.9 : 1)
        }
    }
}

/// Attach to the numeral, not its containing card: values may crossfade/roll without animating
/// neighboring rows, keyboard geometry or the scroll view's content size.
struct NumericFeedback<Value: Equatable>: ViewModifier {
    let value: Value
    @ReducedMotionPreference private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? Motion.crossfade : Motion.content, value: value)
    }
}

/// SwiftUI's Reduce Motion environment value is read-only. This reader always honors it, and
/// allows UI tests to exercise the same reduced branches without changing device-wide settings.
@propertyWrapper
struct ReducedMotionPreference: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemValue
    #if DEBUG
    private static let testOverride = ProcessInfo.processInfo.arguments.contains("--ui-test-reduce-motion")
    #endif

    var wrappedValue: Bool {
        #if DEBUG
        systemValue || Self.testOverride
        #else
        systemValue
        #endif
    }
}
