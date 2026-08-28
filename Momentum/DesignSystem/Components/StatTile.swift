import SwiftUI

/// A raised stat tile with a domain-tinted glyph disc — the Progress page's colour, applied the
/// Bevel way (glass pass 2026-08-27): the tint lives in one small disc and the delta chip, the
/// number stays ink, the tile stays white. Four of these read as one instrument panel.
struct StatTile: View {
    let value: String
    let label: String
    var unit: String? = nil
    var systemImage: String? = nil
    var tint: Color = Theme.purple
    /// "↑12%" / "+2" — coloured by the tint when it's the good direction, quiet ink otherwise.
    var delta: String? = nil
    var deltaGood: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(tint.opacity(0.13)))
                }
                Spacer(minLength: 0)
                if let delta {
                    Text(delta)
                        .font(.rounded(11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(deltaGood ? tint : Theme.inkSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(deltaGood ? tint.opacity(0.12) : Theme.ink.opacity(0.05)))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.display(24, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit).font(.rounded(12, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                Text(label)
                    .font(.rounded(12, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A section eyebrow with a tinted dot — how a card announces which domain it belongs to.
struct EyebrowLabel: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let tint {
                Circle().fill(tint).frame(width: 6, height: 6)
                    .shadow(color: tint.opacity(0.6), radius: 3)
            }
            Text(text.uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.3)
                .foregroundStyle(Theme.inkTertiary)
        }
    }
}
