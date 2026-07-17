import SwiftUI

/// A tappable selection card (PRD §5.5) — used by the activity chooser and onboarding. Press uses
/// the lively spring + selection haptic (§6.2); selected state shifts border/fill (monochrome).
struct SelectionCard: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var isSelected: Bool = false
    /// When non-nil, a star toggle appears on the trailing edge (used by the activity picker to let
    /// users favorite activities). `onToggleFavorite` fires without selecting the card.
    var isFavorite: Bool? = nil
    var onToggleFavorite: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: Theme.Space.md) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(isSelected ? Color.white.opacity(0.16) : Theme.background))
                        .symbolEffect(.bounce, value: isSelected)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(isSelected ? Theme.background.opacity(0.7) : Theme.inkTertiary)
                    }
                }
                Spacer(minLength: 0)
                if let isFavorite, let onToggleFavorite {
                    Button { Haptics.selection(); onToggleFavorite() } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isFavorite ? Theme.purple
                                             : (isSelected ? Theme.background.opacity(0.55) : Theme.inkTertiary))
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                            .symbolEffect(.bounce, value: isFavorite)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite ? "Unfavorite \(title)" : "Favorite \(title)")
                }
                // The selected state flips to a confident ink fill; a check-circle springs in (no
                // empty indicator when unselected, so plain pickers like the activity chooser stay clean).
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .foregroundStyle(isSelected ? Theme.background : Theme.ink)
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(isSelected ? Theme.ink : Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(isSelected ? Color.clear : Theme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(PressableScaleStyle())
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: isSelected)
    }
}

/// Scales a button's label on press using the button's OWN press state, so the press cancels the
/// instant the user starts scrolling. Replaces a `.simultaneousGesture(DragGesture(minimumDistance:
/// 0))` that recognized on touch-down and fired the tap on a light scroll (the scroll-vs-tap bug:
/// scrolling a list of these cards would select whichever one the finger started on).
struct PressableScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.lively, value: configuration.isPressed)
    }
}

#Preview {
    VStack(spacing: 12) {
        SelectionCard(title: "Strength", subtitle: "Log a lifting session",
                      systemImage: "dumbbell.fill", isSelected: true) {}
        SelectionCard(title: "Run", systemImage: "figure.run") {}
    }.padding()
}
