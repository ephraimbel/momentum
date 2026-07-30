import SwiftUI

/// A single set row (PRD §4.4 / §5.5) with two faces:
///
/// **Checklist** (the planned-lift headline path, 2026-07-23): a prefilled set reads as a target
/// — "135 lb × 10" in one quiet pill — and the ✓ logs it exactly as shown. Going down the plan
/// is tap · tap · tap; the fields never appear unless the athlete asks for them.
///
/// **Form**: anything not yet answerable as one tap — an empty free-session set, an edit the
/// athlete opened by tapping the target, or a weighted exercise still missing its weight —
/// shows the weight × reps (+ RPE) fields, exactly the old row.
///
/// The ✓ logs the set, fires a haptic, and starts the rest timer. Tabular figures everywhere.
struct SetRowView: View {
    let vm: StrengthViewModel
    let rowId: UUID
    let set: StrengthSessionEngine.LiveSet
    /// Position among the WORKING sets (1…N) — warm-ups pass nil and wear the W marker.
    var displayNumber: Int? = nil

    @Environment(Services.self) private var services
    @State private var isEditing = false
    @FocusState private var focused: Field?
    private enum Field { case weight, reps, rpe }

    private var draft: StrengthViewModel.Draft { vm.drafts[set.id] ?? .init() }
    /// A weighted exercise with no weight yet can't be one-tap logged (it would record as
    /// bodyweight) — the row asks for the weight instead.
    private var needsWeight: Bool {
        !set.isComplete && draft.weight.isEmpty && vm.weightExpected(rowId: rowId)
    }
    /// Prefilled rows read as a checklist; anything missing reads as the form.
    private var showsForm: Bool {
        !set.isComplete && (isEditing || draft.reps.isEmpty)
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                marker
                if set.isComplete {
                    loggedLine
                } else if showsForm {
                    formFields
                } else {
                    targetPill
                }
                Spacer(minLength: 0)
            }
            .opacity(set.isComplete ? 0.5 : 1)
            logButton
        }
        .padding(.vertical, 6)
        .animation(Motion.lively, value: set.isComplete)
        .onChange(of: set.isComplete) { _, complete in
            if complete { isEditing = false }
        }
    }

    // MARK: Value area

    /// The logged set, as it was performed — fields collapse back to one line of fact.
    private var loggedLine: some View {
        Text(valueText)
            .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
            .foregroundStyle(Theme.ink)
            .accessibilityLabel("Logged \(valueText)")
    }

    /// The target as one tappable pill — tap to adjust weight/reps before checking it off.
    private var targetPill: some View {
        Button {
            isEditing = true
            focused = needsWeight ? .weight : .reps
        } label: {
            HStack(spacing: 6) {
                if needsWeight {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                    Text("weight").font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                    Text("× \(draft.reps)")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                } else {
                    Text(valueText)
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(needsWeight ? "Target \(draft.reps) reps, weight not set"
                                        : "Target \(valueText)")
        .accessibilityHint(needsWeight ? "Adds the weight for this set" : "Adjusts weight or reps")
    }

    /// "135 lb × 10" from the draft — bodyweight sets read as just the reps.
    private var valueText: String {
        let reps = draft.reps.isEmpty ? "—" : draft.reps
        if draft.weight.isEmpty { return "\(reps) reps" }
        return "\(draft.weight) \(vm.weightUnitLabel) × \(reps)"
    }

    private var formFields: some View {
        HStack(spacing: Theme.Space.sm) {
            field(.weight, placeholder: vm.weightUnitLabel, binding: bind(\.weight), width: 60)
            Text("×").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            field(.reps, placeholder: "reps", binding: bind(\.reps), width: 50)
            field(.rpe, placeholder: "rpe", binding: bind(\.rpe), width: 42)
        }
    }

    // MARK: Marker

    /// Set number / type marker + ghosted previous-session value (one VoiceOver element).
    private var marker: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(set.type == .warmup ? "W" : "\(displayNumber ?? set.index + 1)")
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
        self.set.type == .warmup ? "Warmup set" : "Set \(displayNumber ?? self.set.index + 1)"
    }

    private var markerValue: String {
        if let ghost = vm.ghost(rowId: rowId, setIndex: set.index) { return "Previous \(ghost)" }
        return "No previous"
    }

    // MARK: Check

    private var logButton: some View {
        Button {
            focused = nil
            if needsWeight {
                // Checking a weighted set with no weight would log a lie — open the weight
                // field instead, so the tap still moves the athlete forward.
                isEditing = true
                focused = .weight
                Haptics.light()
                return
            }
            // Toggle: tap to log, tap again to un-log (correct a mis-tap mid-workout).
            Task {
                if set.isComplete { await vm.uncompleteSet(rowId: rowId, setId: set.id) }
                else {
                    // Log-a-set latency is a §13.1 quality bar (< 3s) — measure the persist round trip.
                    let started = Date()
                    await vm.completeSet(rowId: rowId, setId: set.id)
                    services.analytics.log(.setLogged(latencyMs: Int(Date().timeIntervalSince(started) * 1000)))
                }
            }
        } label: {
            Image(systemName: set.isComplete ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 26, weight: set.isComplete ? .bold : .regular))
                .foregroundStyle(set.isComplete ? Theme.success
                                 : needsWeight ? Theme.inkTertiary.opacity(0.45) : Theme.inkTertiary)
                .symbolEffect(.bounce, value: set.isComplete)
                .frame(width: 44, height: 44)   // ≥44pt hit area (HIG / quality bar) for a mid-set tap
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(set.isComplete ? "Set logged. Double-tap to undo."
                            : needsWeight ? "Add a weight to log this set" : "Log set")
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
            set: {
                vm.drafts[set.id, default: .init()][keyPath: keyPath] = $0
                // A keystroke is the athlete speaking — see StrengthViewModel.userEditedSets.
                vm.markEdited(set.id)
            }
        )
    }
}
