import SwiftUI
import SwiftData

/// Plan — the unified weekly calendar (PRD §7.7): a calm week mixing disciplines, each a quiet
/// card with type + target + status. Completed gets a soft check; missed simply moved, no red.
struct PlanView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @State private var weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()

    private var plan: TrainingPlan? { profiles.first?.plan }

    private var days: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        Group {
            if plan == nil {
                ContentUnavailableView("No plan yet", systemImage: "calendar",
                                       description: Text("Finish onboarding to get a unified weekly plan."))
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.md) {
                        weekHeader
                        ForEach(days, id: \.self) { day in
                            dayRow(day)
                        }
                    }
                    .padding(Theme.Space.md)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Plan")
    }

    private var weekHeader: some View {
        HStack {
            Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(weekLabel).font(.system(size: Theme.FontSize.body, weight: .semibold))
            Spacer()
            Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
        }
        .foregroundStyle(Theme.ink)
        .padding(.vertical, Theme.Space.sm)
    }

    private func dayRow(_ day: Date) -> some View {
        let sessions = PlanCoaching.todaySessions(plan, on: day)
        let isToday = Calendar.current.isDateInToday(day)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: Theme.FontSize.caption, weight: .bold))
                    .foregroundStyle(isToday ? Theme.ink : Theme.inkTertiary)
                if isToday {
                    Text("TODAY").font(.system(size: 10, weight: .bold)).tracking(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.ink)).foregroundStyle(Theme.background)
                }
            }
            if sessions.isEmpty {
                Text("Rest").font(.system(size: Theme.FontSize.body)).foregroundStyle(Theme.inkTertiary)
            } else {
                ForEach(sessions, id: \.persistentModelID) { session in
                    sessionCard(session)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .fill(isToday ? Theme.surface : Theme.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }

    private func sessionCard(_ session: PlannedSession) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: statusIcon(session.status))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(PlanCoaching.brief(for: session))
                    .font(.system(size: Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if session.status == .moved, let why = session.rationale {
                    Text(why).font(.system(size: Theme.FontSize.caption)).foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(PlanCoaching.brief(for: session)), \(session.status.rawValue)")
    }

    private func statusIcon(_ status: SessionStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .moved: "arrow.turn.up.right"
        case .missed: "arrow.turn.up.right"
        case .planned: "circle"
        }
    }

    private var weekLabel: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(weekStart.formatted(.dateTime.month().day())) – \(end.formatted(.dateTime.month().day()))"
    }

    private func shiftWeek(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: .weekOfYear, value: delta, to: weekStart) { weekStart = d }
    }
}
