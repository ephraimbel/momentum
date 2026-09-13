import SwiftUI

/// The step before Apple's Manage Subscriptions page (2026-09-07; weekly since 2026-09-13).
/// Cancelling itself happens in Apple's UI and cannot be intercepted; what the app can do is put
/// the smaller commitment in front of someone on their way there. Shown only to an athlete whose
/// live subscription is the yearly: switching to the weekly is a crossgrade inside the group (both
/// are level 2), so it takes effect at the next renewal and nothing is charged today. The offer is one screen with a
/// plain way past it, never a wall, and the Manage link is always right there.
struct SubscriptionSwitchSheet: View {
    @Environment(PaywallController.self) private var paywall
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let manageURL: URL

    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Before you go")
                .font(.display(24, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Prefer not to commit to a year? Switch to weekly at \(paywall.offering.weekly.priceText) a week from your next renewal. Nothing is charged today, and you can cancel anytime.")
                .font(.rounded(15, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(.rounded(13, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                switchToWeekly()
            } label: {
                Text(working ? "One moment…" : "Switch to weekly · \(paywall.offering.weekly.priceText)/week")
                    .font(.rounded(15, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .raised(Capsule(), tone: .ink)
            }
            .buttonStyle(RaisedPressStyle(scale: 0.97))
            .disabled(working)
            .accessibilityIdentifier("subscription.switchToWeekly")
            Button("Manage in the App Store") {
                dismiss()
                openURL(manageURL)
            }
            .font(.rounded(15, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityIdentifier("subscription.manage")
            Button("Not now") { dismiss() }
                .font(.rounded(15, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .padding(Theme.Space.md)
        .padding(.top, Theme.Space.sm)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func switchToWeekly() {
        guard !working else { return }
        working = true
        Task {
            let outcome = await paywall.purchase(paywall.offering.weekly)
            working = false
            switch outcome {
            case .purchased: dismiss()
            case .cancelled: break
            case .failed(let text): message = text
            }
        }
    }
}
