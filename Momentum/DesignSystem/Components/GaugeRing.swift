import SwiftUI

/// A small glowing gauge — the Bevel/Oura ring, in our material (glass pass 2026-08-27). A soft
/// same-tint track, one flowing arc (round caps, brightening along its travel), a static glow
/// beneath, the reading in the display face and a quiet label under it. The arc sweeps in with a
/// spring on appear; Reduce Motion lands it whole. `value == nil` draws the bare track and a dash —
/// a missing signal is never a fake zero.
struct GaugeRing: View {
    /// 0…1, or nil when there is no honest reading.
    let value: Double?
    let text: String
    let label: String
    var tint: Color = Theme.purple
    var size: CGFloat = 88
    var lineWidth: CGFloat = 9
    /// The quiet "tap for the full story" mark beside the label (the app's depth-is-a-promise rule).
    var showsChevron = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var sweep = 0.0

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(scheme == .dark ? 0.18 : 0.13), lineWidth: lineWidth)
                if let value {
                    Circle()
                        .trim(from: 0, to: max(0.003, min(1, value * sweep)))
                        .stroke(AngularGradient(colors: [tint.opacity(0.55), tint, tint],
                                                center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: tint.opacity(scheme == .dark ? 0.65 : 0.45), radius: 8)
                }
                Text(value == nil ? "—" : text)
                    .font(.display(size * 0.26, weight: .bold)).monospacedDigit()
                    .foregroundStyle(value == nil ? Theme.inkTertiary : Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, lineWidth + 6)
                    .contentTransition(.numericText())
            }
            .frame(width: size, height: size)
            HStack(spacing: 3) {
                Text(label)
                    .font(.rounded(13, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                if showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
        }
        .onAppear {
            if reduceMotion { sweep = 1 }
            else { withAnimation(.spring(response: 0.9, dampingFraction: 0.82).delay(0.1)) { sweep = 1 } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value == nil ? "no reading" : text)
    }
}

#Preview {
    HStack(spacing: 24) {
        GaugeRing(value: 0.12, text: "12%", label: "Strain", tint: Theme.Health.strainInk)
        GaugeRing(value: 0.8, text: "80", label: "Recovery", tint: Theme.Health.recoveryInk)
        GaugeRing(value: nil, text: "", label: "Sleep", tint: Theme.Health.sleepInk)
    }
    .padding()
}
