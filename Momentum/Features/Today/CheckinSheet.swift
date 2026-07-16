import SwiftUI
import SwiftData

/// The 10-second morning check-in (ENDURANCE-FOCUS §8.2): energy, legs, pain. What the athlete says
/// stands equal to what the wearable measured — sore legs + low energy can ease today's session, and
/// pain routes straight into the injury loop. Fast, warm, zero judgment.
struct CheckinSheet: View {
    let profile: UserProfile?
    /// Called when the athlete says something hurts — the caller opens the injury report.
    var onPain: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var energy: DailyCheckin.Energy?
    @State private var legs: DailyCheckin.Legs?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("How are you feeling?")
                        .font(.serif(28, weight: .semibold)).foregroundStyle(Theme.ink)

                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        sectionLabel("ENERGY")
                        HStack(spacing: Theme.Space.sm) {
                            ForEach(DailyCheckin.Energy.allCases) { e in
                                choiceChip(e.label, icon: e.icon, on: energy == e) {
                                    withAnimation(Motion.lively) { energy = e }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        sectionLabel("LEGS")
                        HStack(spacing: Theme.Space.sm) {
                            ForEach(DailyCheckin.Legs.allCases) { l in
                                choiceChip(l.label, on: legs == l) {
                                    withAnimation(Motion.lively) { legs = l }
                                }
                            }
                        }
                    }

                    // Pain is never a rating — it's a door into the injury loop.
                    Button {
                        Haptics.light()
                        save()
                        dismiss()
                        onPain()
                    } label: {
                        HStack(spacing: Theme.Space.sm) {
                            Image(systemName: "bandage.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.purple)
                            Text("Something hurts").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                        }
                        .padding(Theme.Space.md)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.purple.opacity(0.08))
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.purple.opacity(0.25))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.Space.lg)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .navigationTitle("Morning check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Skip") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                OversizedButton(title: "Done", isEnabled: energy != nil && legs != nil) {
                    save()
                    Haptics.success()
                    dismiss()
                }
                .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                .background(Theme.background)
            }
        }
        // Tall enough that ENERGY, LEGS, "Something hurts", AND Done are all visible without
        // scrolling — at .medium the pain button hid below the fold, and a door you can't see is a
        // door that doesn't exist.
        .presentationDetents([.height(560), .large])
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
    }

    private func choiceChip(_ title: String, icon: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            VStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(on ? Theme.background : Theme.ink)
            .frame(maxWidth: .infinity).frame(height: icon == nil ? 44 : 58)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                if !on { RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).stroke(Theme.hairline) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Persist today's answers (partial answers still count — skip leaves nothing).
    private func save() {
        guard energy != nil || legs != nil else { return }
        let checkin = DailyCheckin(energy: energy ?? .ok, legs: legs ?? .ok)
        context.insert(checkin)
        try? context.save()
    }
}
