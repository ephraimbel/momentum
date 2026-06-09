import SwiftUI
import SwiftData

/// Plan — a clean, beautiful weekly planner (PRD §7.7). A calm week mixing disciplines, each day a
/// date badge + quiet session cards with discipline glyphs and status. Completed earns a soft
/// iridescent tint; missed simply moves with a one-line note. No red, no guilt.
struct PlanView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @State private var weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    @State private var showingAdd = false
    @State private var addDay = Date()

    private var plan: TrainingPlan? { profiles.first?.plan }
    private var days: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        Group {
            if plan == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        header
                        ForEach(days, id: \.self) { dayRow($0) }
                    }
                    .padding(Theme.Space.lg)
                    .padding(.bottom, Theme.Space.xxl)
                }
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .sheet(isPresented: $showingAdd) {
            if let plan {
                AddSessionSheet(plan: plan, defaultDate: addDay) { showingAdd = false }
            }
        }
    }

    private func presentAdd(for day: Date) { addDay = day; showingAdd = true }

    private func delete(_ session: PlannedSession) {
        withAnimation(Motion.standard) {
            context.delete(session)
            try? context.save()
        }
        Haptics.light()
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plan").font(.display(32, weight: .black)).foregroundStyle(Theme.ink)
                Text(weekLabel).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            HStack(spacing: Theme.Space.sm) {
                navButton("plus") { presentAdd(for: Date()) }
                navButton("chevron.left") { shiftWeek(-1) }
                navButton("chevron.right") { shiftWeek(1) }
            }
        }
        .padding(.top, Theme.Space.sm)
    }

    private func dayRow(_ day: Date) -> some View {
        let sessions = PlanCoaching.todaySessions(plan, on: day)
        let isToday = Calendar.current.isDateInToday(day)
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            dateBadge(day, isToday: isToday)
            VStack(spacing: Theme.Space.sm) {
                if sessions.isEmpty {
                    restRow(day)
                } else {
                    ForEach(sessions, id: \.persistentModelID) { session in
                        sessionCard(session)
                            .contextMenu {
                                Button(role: .destructive) { delete(session) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
    }

    private func dateBadge(_ day: Date, isToday: Bool) -> some View {
        VStack(spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
            Text(day.formatted(.dateTime.day()))
                .font(.display(18, weight: .heavy)).monospacedDigit()
        }
        .foregroundStyle(isToday ? Theme.background : Theme.ink)
        .frame(width: 46, height: 56)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(isToday ? Theme.ink : Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)
        }
    }

    private func sessionCard(_ session: PlannedSession) -> some View {
        let done = session.status == .completed
        return HStack(spacing: Theme.Space.md) {
            Image(systemName: disciplineIcon(session.discipline))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.background))
            VStack(alignment: .leading, spacing: 2) {
                Text(PlanCoaching.brief(for: session))
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if session.status == .moved, let why = session.rationale {
                    Text(why).font(.rounded(Theme.FontSize.caption, weight: .regular)).foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: statusIcon(session.status))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(done ? Theme.ink : Theme.inkTertiary)
        }
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            if done { RoundedRectangle(cornerRadius: Theme.Radius.card).fill(IridescentMaterial()).opacity(0.16) }
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(PlanCoaching.brief(for: session)), \(session.status.rawValue)")
    }

    private func restRow(_ day: Date) -> some View {
        Button { presentAdd(for: day) } label: {
            HStack {
                Text("Rest").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                Spacer()
                Image(systemName: "plus.circle").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.lg) {
            IridescentOrb(size: 72)
            Text("No plan yet").font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Finish onboarding to get a unified weekly plan.")
                .font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background { Circle().fill(Theme.surface); Circle().stroke(Theme.hairline) }
        }
        .buttonStyle(.plain)
    }

    private func statusIcon(_ status: SessionStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .moved, .missed: "arrow.turn.up.right"
        case .planned: "circle"
        }
    }

    private func disciplineIcon(_ d: Discipline) -> String {
        switch d { case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill" }
    }

    private var weekLabel: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(weekStart.formatted(.dateTime.month().day())) – \(end.formatted(.dateTime.month().day()))"
    }

    private func shiftWeek(_ delta: Int) {
        withAnimation(Motion.standard) {
            if let d = Calendar.current.date(byAdding: .weekOfYear, value: delta, to: weekStart) { weekStart = d }
        }
    }
}
