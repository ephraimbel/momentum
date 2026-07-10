import SwiftUI

/// A row of metric cells with hairline separators — the enterprise stat strip used on the profile
/// header and feed cards (Strava's signature multi-up). Value is `.display` monospaced over a tracked
/// uppercase label. Lean by design: no box, just figures and thin rules.
struct StatGrid: View {
    struct Cell: Identifiable {
        let value: String
        let label: String
        var id: String { label }
    }

    let cells: [Cell]
    var valueSize: CGFloat = 20
    /// Left-align each cell (feed strip) vs centered (profile header).
    var leading: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                if index > 0 { divider }
                VStack(alignment: leading ? .leading : .center, spacing: 3) {
                    Text(cell.value)
                        .font(.display(valueSize, weight: .black)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(cell.label.uppercased())
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(cell.label): \(cell.value)")
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 30)
    }
}
