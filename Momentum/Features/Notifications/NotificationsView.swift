import SwiftUI
import SwiftData

/// The bell inbox — everything momentum has told the athlete (reminders, coaching nudges, streak
/// alerts, achievements) in one place, newest first. Opening it clears the unread badge.
///
/// Speaks the house sheet grammar (2026-07-29 pass): a display-face masthead with the X-circle
/// close (the Add-a-session pattern) instead of a stock nav bar, and the notifications grouped by
/// day into ONE hairline-separated card per group — the Plan board's one-card treatment — instead
/// of a stack of identical bordered tiles. The unread dot is plain ink: iridescence marks earned
/// progress, and an unread reminder isn't an achievement.
struct NotificationsView: View {
    @Query(sort: \AppNotification.date, order: .reverse) private var notifications: [AppNotification]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(CoachPresenter.self) private var coach
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            header
            if notifications.isEmpty {
                emptyState.frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Theme.background)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .onAppear(perform: markAllRead)   // seeing the inbox clears the badge
    }

    // MARK: Masthead — the app's page grammar (owner call 2026-08-20): the lowercase title
    // CENTERED in the display face, accessories flanking — exactly how progress and fuel read.

    private var header: some View {
        ZStack {
            Text("notifications")
                .font(.display(20, weight: .bold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.surface))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
    }

    // MARK: The inbox — day groups, each ONE card of hairline-separated rows

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(grouped, id: \.label) { group in
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(group.label)
                            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                            .foregroundStyle(Theme.inkTertiary)
                            .accessibilityAddTraits(.isHeader)
                        groupCard(group.items)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl)
        }
        .scrollIndicators(.hidden)
    }

    /// One surface per day-group; rows split by inset hairlines (the week board's language), so
    /// the inbox reads as a few calm objects instead of a wall of tiles.
    private func groupCard(_ items: [AppNotification]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, n in
                row(n)
                if i < items.count - 1 {
                    Rectangle().fill(Theme.hairline)
                        .frame(height: 0.5)
                        .padding(.leading, 36 + Theme.Space.md * 2)
                }
            }
        }
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// Newest-first day buckets: Today · Yesterday · This week · Earlier. Grouping is what makes
    /// a full inbox scannable — the timestamps become one label instead of forty.
    private var grouped: [(label: String, items: [AppNotification])] {
        let cal = Calendar.current
        var today: [AppNotification] = [], yesterday: [AppNotification] = []
        var week: [AppNotification] = [], earlier: [AppNotification] = []
        for n in notifications {
            if cal.isDateInToday(n.date) { today.append(n) }
            else if cal.isDateInYesterday(n.date) { yesterday.append(n) }
            else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: n.date),
                                                  to: cal.startOfDay(for: Date())).day, days < 7 {
                week.append(n)
            } else { earlier.append(n) }
        }
        return [("TODAY", today), ("YESTERDAY", yesterday),
                ("THIS WEEK", week), ("EARLIER", earlier)].filter { !$0.1.isEmpty }
    }

    // MARK: Rows

    /// A notification is a promise — tapping it keeps it. Coaching notes open the coach chat,
    /// reminders and streak nudges land on Today, achievements open Progress. System notes are
    /// informational and stay put (no chevron, no dead tap).
    private enum Destination { case coach, today, progress, communityPost(UUID), athlete(String) }

    private func destination(for notification: AppNotification) -> Destination? {
        switch notification.kind {
        case .coaching: .coach
        case .reminder, .streak, .nudge: .today
        case .achievement: .progress
        case .system: nil
        case .respect, .comment:
            notification.targetPostID.map(Destination.communityPost)
        case .follow:
            notification.targetHandle.map(Destination.athlete)
        }
    }

    private func open(_ destination: Destination) {
        Haptics.light()
        dismiss()
        switch destination {
        case .coach:
            // Let the sheet's dismissal settle before presenting the cover — presenting during
            // a dismissal transition drops the presentation on the floor.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { coach.open() }
        case .today:
            coach.navigate(.startToday)
        case .progress:
            coach.navigate(.viewProgress)
        case .communityPost(let id):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                router.pendingCommunityPostID = id
                router.pendingTab = .profile
            }
        case .athlete(let handle):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                router.pendingCommunityAthleteHandle = handle
                router.pendingTab = .profile
            }
        }
    }

    @ViewBuilder
    private func row(_ n: AppNotification) -> some View {
        if let destination = destination(for: n) {
            Button { open(destination) } label: { rowContent(n, chevron: true) }
                .buttonStyle(.plain)
        } else {
            rowContent(n, chevron: false)
        }
    }

    private func rowContent(_ n: AppNotification, chevron: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: n.kind.systemImage)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36)
                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(n.title)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    // Unread marker in plain ink — iridescence is for earned moments, not backlog.
                    if !n.read {
                        Circle().fill(Theme.ink).frame(width: 6, height: 6)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Text(relativeDay(n.date))
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize()
                }
                Text(n.body)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary.opacity(0.7))
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(n.title). \(n.body). \(relativeDay(n.date))\(n.read ? "" : ". Unread")")
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "bell.slash")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                .frame(width: 64, height: 64)
                .background { Circle().fill(Theme.surface); Circle().stroke(Theme.hairline) }
            Text("You're all caught up")
                .font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
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

    /// Inside a day group the stamp stays short: a clock time under TODAY and YESTERDAY, the
    /// weekday under THIS WEEK, a date under EARLIER — the group label already carries the rest.
    private func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) || cal.isDateInYesterday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        return days < 7 ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.month().day())
    }
}
