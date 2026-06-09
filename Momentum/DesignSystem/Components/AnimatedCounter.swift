import SwiftUI

/// A number that counts up from 0 to its target when it appears — the premium "tally" reveal on
/// summary heroes (PRD §6.1: motion rewards effort; restraint is the brand). Tabular figures so
/// digits never jitter; honors Reduce Motion by snapping straight to the final value.
///
/// Conforms to `Animatable` so SwiftUI re-evaluates `body` across interpolated values during the
/// `withAnimation` that drives `shown` from 0 → target.
struct AnimatedCounter: View, Animatable {
    var value: Double
    let format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value)).monospacedDigit()
    }
}

/// The hero metric on summary screens, with a count-up reveal. Mirrors `HeroMetric`'s look but
/// animates the number on appear. (Live screens keep the static `HeroMetric` — a live value
/// shouldn't re-tally on every update.)
struct CountUpHero: View {
    let target: Double
    let format: (Double) -> String
    let label: String
    var size: CGFloat = Theme.FontSize.heroNumber
    var duration: Double = 0.9

    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            AnimatedCounter(value: shown, format: format)
                .font(.display(size, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label.uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(target))
        .onAppear {
            guard !reduceMotion else { shown = target; return }
            withAnimation(.easeOut(duration: duration)) { shown = target }
        }
    }
}

/// Fades + lifts a view into place once, with an optional stagger `delay`. Used to reveal summary
/// sections in sequence for a calm, professional cascade. Reduce Motion → appears instantly.
private struct RevealOnAppear: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.5).delay(delay)) { shown = true }
            }
    }
}

extension View {
    /// Reveal this view with a fade + lift on appear; pass a `delay` to stagger a cascade.
    func reveal(_ delay: Double = 0) -> some View { modifier(RevealOnAppear(delay: delay)) }
}
