import SwiftUI

/// A tappable selection card (PRD §5.5) — used by the activity chooser and onboarding. Press uses
/// the lively spring + selection haptic (§6.2); selected state shifts border/fill (monochrome).
struct SelectionCard: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var isSelected: Bool = false
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: Theme.Space.md) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: Theme.FontSize.body, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: Theme.FontSize.caption))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(isSelected ? Theme.ink : Theme.hairline, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.98 : 1)
        .animation(Motion.lively, value: pressed)
        .animation(Motion.lively, value: isSelected)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

#Preview {
    VStack(spacing: 12) {
        SelectionCard(title: "Strength", subtitle: "Log a lifting session",
                      systemImage: "dumbbell.fill", isSelected: true) {}
        SelectionCard(title: "Run", systemImage: "figure.run") {}
    }.padding()
}
