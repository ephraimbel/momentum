import SwiftUI

/// The calm empty state — the brand orb, a title, optional message, and an optional primary action.
/// Replaces the inline `IridescentOrb` + headline blocks repeated in Plan/Progress/History.
struct EmptyState: View {
    var orbSize: CGFloat = 72
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            IridescentOrb(size: orbSize)
            VStack(spacing: Theme.Space.xs) {
                Text(title)
                    .font(.display(Theme.FontSize.headline, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.rounded(Theme.FontSize.body, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle, let action {
                OversizedButton(title: actionTitle, action: action)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
    }
}
