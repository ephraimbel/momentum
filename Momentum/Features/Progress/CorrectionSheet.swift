import SwiftUI
import SwiftData

/// "Not quite right?" — lets the user correct a surfaced belief on the You surface. Saving writes a
/// pinned user note the AI must honor (ATHLETE-MODEL.md §5); "Forget this" retires the backing note.
struct CorrectionSheet: View {
    let belief: String
    let category: MemoryCategory
    let noteID: UUID?
    let profile: UserProfile

    @Environment(Services.self) private var services
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("MOMENTUM THINKS").font(.rounded(Theme.FontSize.label, weight: .bold))
                        .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                    Text(belief).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.lg)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))

                Text("SET ME STRAIGHT").font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                TextField("e.g. I actually train in the evenings", text: $text, axis: .vertical)
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(2...4)
                    .padding(Theme.Space.md)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))

                OversizedButton(title: "Save", systemImage: "checkmark") {
                    services.athleteModel.addCorrection(text, category: category, for: profile, in: context)
                    Haptics.success()
                    dismiss()
                }
                .opacity(canSave ? 1 : 0.4)
                .disabled(!canSave)

                if let noteID {
                    Button {
                        services.athleteModel.forget(noteID: noteID, in: context)
                        Haptics.light()
                        dismiss()
                    } label: {
                        Text("Forget this").font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(Theme.Space.lg)
            .background(Theme.background)
            .navigationTitle("Not quite right?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
