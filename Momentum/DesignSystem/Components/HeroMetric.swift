import SwiftUI

/// The single large hero metric used on live screens and summaries (PRD §5.5). Tabular figures
/// mandatory so digits never jitter (§5.3).
struct HeroMetric: View {
    let value: String
    let label: String
    var size: CGFloat = Theme.FontSize.heroNumber

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            Text(value)
                .font(.display(size, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label.uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

#Preview {
    HeroMetric(value: "5,240", label: "Volume (kg)")
}
