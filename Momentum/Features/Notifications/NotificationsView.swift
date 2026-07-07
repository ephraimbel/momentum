import SwiftUI
import SwiftData

/// The bell inbox — everything momentum has told the athlete (reminders, coaching nudges, streak alerts,
/// achievements) in one place, newest first. Opening it clears the unread badge.
struct NotificationsView: View {
    @Query(sort: \AppNotification.date, order: .reverse) private var notifications: [AppNotification]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if notifications.isEmpty { emptyState } else { list }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.rounded(Theme.FontSize.body, weight: .semibold))
                }
            }
            .onAppear(perform: markAllRead)   // seeing the inbox clears the badge
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: Theme.Space.sm) {
                ForEach(notifications) { row($0) }
            }
            .padding(Theme.Space.md)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ n: AppNotification) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: n.kind.systemImage)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40)
                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(n.title).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    if !n.read {
                        Circle().fill(IridescentMaterial()).frame(width: 7, height: 7)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Text(relativeDay(n.date)).font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                Text(n.body).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "bell.slash").font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            Text("You're all caught up").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Reminders and coaching notes will show up here.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.xl)
    }

    private func markAllRead() {
        for n in notifications where !n.read { n.read = true }
        try? context.save()
    }

    private func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        return days < 7 ? "\(days)d ago" : date.formatted(.dateTime.month().day())
    }
}
