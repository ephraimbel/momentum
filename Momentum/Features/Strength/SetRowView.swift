import SwiftUI

/// A single set row (PRD §4.4 / §5.5): set #, ghosted previous, weight × reps, optional RPE, and a
/// one-tap ✓ that logs the set, fires a light haptic, and starts the rest timer. Tabular figures.
struct SetRowView: View {
    let vm: StrengthViewModel
    let rowId: UUID
    let set: StrengthSessionEngine.LiveSet

    @FocusState private var focused: Field?
    private enum Field { case weight, reps, rpe }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            // Set number / type marker
            Text(set.type == .warmup ? "W" : "\(set.index + 1)")
                .font(.system(size: Theme.FontSize.caption, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 22)

            // Ghosted previous-session value
            Text(vm.ghost(rowId: rowId, setIndex: set.index) ?? "—")
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)

            field(.weight, placeholder: vm.weightUnitLabel, binding: bind(\.weight), width: 60)
            Text("×").foregroundStyle(Theme.inkTertiary)
            field(.reps, placeholder: "reps", binding: bind(\.reps), width: 50)
            field(.rpe, placeholder: "rpe", binding: bind(\.rpe), width: 42)

            Spacer(minLength: 0)

            Button {
                focused = nil
                Task { await vm.completeSet(rowId: rowId, setId: set.id) }
            } label: {
                Image(systemName: set.isComplete ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(set.isComplete ? Theme.ink : Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .disabled(set.isComplete)
        }
        .padding(.vertical, 6)
        .opacity(set.isComplete ? 0.55 : 1)
        .animation(Motion.lively, value: set.isComplete)
    }

    @ViewBuilder
    private func field(_ f: Field, placeholder: String, binding: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: binding)
            .keyboardType(f == .reps ? .numberPad : .decimalPad)
            .multilineTextAlignment(.center)
            .font(.system(size: Theme.FontSize.body, weight: .semibold))
            .monospacedDigit()
            .focused($focused, equals: f)
            .frame(width: width, height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.background))
            .disabled(set.isComplete)
    }

    private func bind(_ keyPath: WritableKeyPath<StrengthViewModel.Draft, String>) -> Binding<String> {
        Binding(
            get: { vm.drafts[set.id]?[keyPath: keyPath] ?? "" },
            set: { vm.drafts[set.id, default: .init()][keyPath: keyPath] = $0 }
        )
    }
}
