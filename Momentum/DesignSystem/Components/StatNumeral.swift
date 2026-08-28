import SwiftUI

/// A hero numeral with its unit raised and small — 4.54ᵐⁱ, 7:50ᐟᵐⁱ — the live-tracker and share
/// grammar (2026-08-25). The value is Space Grotesk, tabular; the unit is Inter at ~40%, sat on
/// the cap line so it reads as part of the number, not a label. Pass the ink explicitly: this
/// draws on fixed-dark cards over live media as often as on the canvas.
struct StatNumeral: View {
    let value: String
    var unit: String? = nil
    var size: CGFloat = 34
    var ink: Color = Theme.ink
    var unitInk: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.display(size, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let unit, !unit.isEmpty {
                Text(unit)
                    .font(.rounded(size * 0.4, weight: .semibold))
                    .foregroundStyle(unitInk ?? ink.opacity(0.7))
                    .baselineOffset(size * 0.42)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(unit ?? "")")
    }
}
