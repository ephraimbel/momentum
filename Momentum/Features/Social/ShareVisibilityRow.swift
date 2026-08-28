import SwiftUI

/// Per-workout visibility control — the share moment (PRD §11, docs/SOCIAL-LAYER.md). Lives on the
/// save screens (where the choice is made, seeded from the profile default) and on the workout
/// detail (where it can be changed later). Private-by-default ethos: the picker never nags, and the
/// hint says plainly what each level exposes.
struct ShareVisibilityRow: View {
    @Binding var privacy: WorkoutPrivacy
    /// Draw the standalone card chrome (detail view). Off when embedded in an editor card.
    var boxed: Bool = true
    /// Show the one-line "what others will see" explanation (save screens).
    var showsHint: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Menu {
                Picker("Visibility", selection: $privacy) {
                    ForEach(WorkoutPrivacy.allCases, id: \.self) { p in
                        Label(p.label, systemImage: p.icon).tag(p)
                    }
                }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: privacy.icon).font(.system(size: 13, weight: .semibold))
                    Text("Visible to \(privacy.label.lowercased())")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, boxed ? Theme.Space.md : 0).padding(.vertical, boxed ? 10 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(BoxedRaise(on: boxed))
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Workout visibility, \(privacy.label)")
            if showsHint {
                Text(hint)
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hint: String {
        switch privacy {
        case .private: "Only you. Nothing leaves your history."
        case .friends: "People who follow you see your title, stats, and photos — never your exact start point."
        case .public: "Anyone on Momentum sees your title, stats, and photos — never your exact start point."
        }
    }
}

private struct BoxedRaise: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)) } else { content }
    }
}
