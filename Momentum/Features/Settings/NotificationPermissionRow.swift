import SwiftUI
import UserNotifications

/// Settings → Notifications tells the truth about the system switch (notification pass
/// 2026-09-06): when the athlete said no to iOS, five toggles that silently do nothing are worse
/// than one honest line with the door to where the switch actually lives. Renders nothing while
/// notifications are allowed (or not yet asked), and re-checks on every return to the foreground,
/// so flipping the switch in iOS Settings and coming back clears it.
struct NotificationPermissionRow: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var denied = false

    var body: some View {
        // A zero-height anchor rather than nothing: `.task` on an empty view never runs
        // (bug hunt 2026-07-28), and the check must run even while the row is hidden.
        VStack(spacing: 0) {
            if denied { row }
        }
        .task(id: scenePhase) {
            guard scenePhase != .background else { return }
            denied = await NotificationService.authorizationStatus() == .denied
        }
    }

    private var row: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.background))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notifications are off for momentum in iOS Settings")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Reminders and coaching updates can't reach you until they're on.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.sm)
                Button("Turn on") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            .padding(.vertical, 12)
            Divider().overlay(Theme.hairline).padding(.leading, 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notifications-denied")
    }
}
