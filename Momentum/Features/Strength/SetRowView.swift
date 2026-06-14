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
            // The logged set's data dims back; the ✓ itself stays full-brightness so "done" reads.
            HStack(spacing: Theme.Space.sm) {
                marker
                field(.weight, placeholder: vm.weightUnitLabel, binding: bind(\.weight), width: 60)
                Text("×").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                field(.reps, placeholder: "reps", binding: bind(\.reps), width: 50)
                field(.rpe, placeholder: "rpe", binding: bind(\.rpe), width: 42)
                Spacer(minLength: 0)
            }
            .opacity(set.isComplete ? 0.5 : 1)
            logButton
        }
        .padding(.vertical, 6)
        .animation(Motion.lively, value: set.isComplete)
    }

    /// Set number / type marker + ghosted previous-session value (one VoiceOver element).
    private var marker: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(set.type == .warmup ? "W" : "\(set.index + 1)")
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 22)
            Text(vm.ghost(rowId: rowId, setIndex: set.index) ?? "—")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(markerLabel)
        .accessibilityValue(markerValue)
    }

    private var markerLabel: String {
        self.set.type == .warmup ? "Warmup set" : "Set \(self.set.index + 1)"
    }

    private var markerValue: String {
        if let ghost = vm.ghost(rowId: rowId, setIndex: set.index) { return "Previous \(ghost)" }
        return "No previous"
    }

    private var logButton: some View {
        Button {
            focused = nil
            // Toggle: tap to log, tap again to un-log (correct a mis-tap mid-workout).
            Task {
                if set.isComplete { await vm.uncompleteSet(rowId: rowId, setId: set.id) }
                else { await vm.completeSet(rowId: rowId, setId: set.id) }
            }
        } label: {
            Image(systemName: set.isComplete ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 26, weight: set.isComplete ? .bold : .regular))
                .foregroundStyle(set.isComplete ? Theme.success : Theme.inkTertiary)
                .symbolEffect(.bounce, value: set.isComplete)
                .frame(width: 44, height: 44)   // ≥44pt hit area (HIG / quality bar) for a mid-set tap
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(set.isComplete ? "Set logged. Double-tap to undo." : "Log set")
    }

    @ViewBuilder
    private func field(_ f: Field, placeholder: String, binding: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: binding)
            .keyboardType(f == .reps ? .numberPad : .decimalPad)
            .multilineTextAlignment(.center)
            .font(.rounded(Theme.FontSize.body, weight: .bold))
            .monospacedDigit()
            .focused($focused, equals: f)
            .frame(width: width, height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.background))
            .disabled(set.isComplete)
            .accessibilityLabel(fieldLabel(f))
    }

    private func fieldLabel(_ f: Field) -> String {
        switch f {
        case .weight: "Weight in \(vm.weightUnitLabel)"
        case .reps: "Reps"
        case .rpe: "RPE"
        }
    }

    private func bind(_ keyPath: WritableKeyPath<StrengthViewModel.Draft, String>) -> Binding<String> {
        Binding(
            get: { vm.drafts[set.id]?[keyPath: keyPath] ?? "" },
            set: { vm.drafts[set.id, default: .init()][keyPath: keyPath] = $0 }
        )
    }
}
