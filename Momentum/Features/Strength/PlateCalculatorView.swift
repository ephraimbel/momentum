import SwiftUI

/// Plate calculator sheet (PRD §4.4 / §22): enter a target and see the plates per side, computed
/// by `PlateCalculator`. Shortfall is shown when a load can't be made exactly.
struct PlateCalculatorView: View {
    let weightUnit: WeightUnit
    @Environment(\.dismiss) private var dismiss

    @State private var targetText = ""

    private var bar: Double { weightUnit == .lb ? PlateCalculator.defaultBarLb : PlateCalculator.defaultBarKg }
    private var plates: [Double] { weightUnit == .lb ? PlateCalculator.lbPlates : PlateCalculator.kgPlates }
    private var unit: String { weightUnit == .lb ? "lb" : "kg" }

    private var result: PlateCalculator.Result? {
        guard let target = Double(targetText.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return PlateCalculator.compute(target: target, bar: bar, available: plates)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.lg) {
                HStack {
                    TextField("Target (\(unit))", text: $targetText)
                        .keyboardType(.decimalPad)
                        .font(.display(Theme.FontSize.title, weight: .bold))
                        .monospacedDigit()
                    Text("Bar \(Int(bar)) \(unit)")
                        .font(.rounded(Theme.FontSize.caption, weight: .regular))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .padding()
                .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                if let result {
                    VStack(spacing: Theme.Space.sm) {
                        Text("Per side")
                            .font(.rounded(Theme.FontSize.label, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(Theme.inkTertiary)
                        if result.perSide.isEmpty {
                            Text("Just the bar").foregroundStyle(Theme.inkSecondary)
                        } else {
                            FlowPlates(plates: result.perSide, unit: unit)
                        }
                        if !result.isExact {
                            Text("+\(String(format: "%.2f", result.totalShortfall)) \(unit) short")
                                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                }
                Spacer()
            }
            .padding()
            .background(Theme.background)
            .navigationTitle("Plate Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct FlowPlates: View {
    let plates: [PlateCalculator.Plate]
    let unit: String
    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(Array(plates.enumerated()), id: \.offset) { _, plate in
                VStack(spacing: 2) {
                    Text(plateString(plate.weight))
                        .font(.display(Theme.FontSize.headline, weight: .bold))
                        .monospacedDigit()
                    Text("×\(plate.count)")
                        .font(.rounded(Theme.FontSize.caption, weight: .regular))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .frame(minWidth: 56)
                .padding(.vertical, Theme.Space.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline))
            }
        }
    }
    private func plateString(_ w: Double) -> String {
        w == w.rounded() ? String(Int(w)) : String(format: "%.2f", w)
    }
}

#Preview { PlateCalculatorView(weightUnit: .kg) }
