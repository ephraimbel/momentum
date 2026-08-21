import SwiftUI

/// One-tap durations — the missing half of logging a lift.
///
/// Duration is the least memorable fact about a strength session: nobody thinks "I benched for 47
/// minutes", they think "I benched 185 for 10, five sets". The parser reads that perfectly and then
/// the app refused to save it, because a workout needs a duration — so a correctly-understood
/// session sat behind a greyed-out button with a hint asking the athlete to go say more words. This
/// is the fix, and it stays honest: nothing is guessed, the athlete taps the number themselves.
///
/// Shared by the log composer's receipt card and the manual form, so "45 min" means one tap in both.
struct QuickDurationRow: View {
    /// Currently-selected duration in seconds, if any — the matching chip reads as chosen.
    var selected: TimeInterval?
    var onPick: (TimeInterval) -> Void

    /// The everyday session lengths, in the order a gym-goer thinks of them.
    static let options: [TimeInterval] = [20 * 60, 30 * 60, 45 * 60, 60 * 60, 90 * 60]

    static func label(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)h" }
        return minutes > 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(Self.options, id: \.self) { option in
                let isOn = selected.map { abs($0 - option) < 1 } ?? false
                Button {
                    Haptics.selection()
                    onPick(option)
                } label: {
                    Text(Self.label(option))
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(isOn ? Theme.background : Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(isOn ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.background)))
                        .overlay(Capsule().stroke(isOn ? Color.clear : Theme.hairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Int(option / 60)) minutes")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}
