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
                        VStack(spacing: Theme.Space.md) {
                            ForEach(Array(days.enumerated()), id: \.element) { i, day in
                                dayRow(day).reveal(min(Double(i) * 0.04, 0.28))
                            }
                        }
                    }
                    .padding(Theme.Space.lg)
                    .padding(.bottom, Theme.Space.xxl)
                }
                .scrollIndicators(.hidden)
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
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan").font(.display(34, weight: .black)).foregroundStyle(Theme.ink)
                Spacer()
                addButton
            }
            weekBar
        }
        .padding(.top, Theme.Space.sm)
    }

    /// Elegant week switcher — the range/“This week” + a live summary, flanked by chevrons.
    private var weekBar: some View {
        HStack(spacing: Theme.Space.sm) {
            chevron("chevron.left") { shiftWeek(-1) }
            VStack(spacing: 1) {
                Text(weekTitle).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Text(weekSummary).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .contentTransition(.opacity)
            chevron("chevron.right") { shiftWeek(1) }
        }
        .padding(.vertical, Theme.Space.sm)
        .padding(.horizontal, Theme.Space.sm)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    private var addButton: some View {
        Button { presentAdd(for: Date()) } label: {
            Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.background)
                .frame(width: 40, height: 40).background(Circle().fill(Theme.ink))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add session")
    }

    private func chevron(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: system).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dayRow(_ day: Date) -> some View {
        let sessions = PlanCoaching.todaySessions(plan, on: day)
        let isToday = Calendar.current.isDateInToday(day)
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            dateBadge(day, isToday: isToday, hasSessions: !sessions.isEmpty)
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

    private func dateBadge(_ day: Date, isToday: Bool, hasSessions: Bool) -> some View {
        VStack(spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(0.5)
            Text(day.formatted(.dateTime.day()))
                .font(.display(20, weight: .heavy)).monospacedDigit()
        }
        // Hierarchy: today fills ink; days with sessions read full-ink; rest days recede.
        .foregroundStyle(isToday ? Theme.background : (hasSessions ? Theme.ink : Theme.inkTertiary))
        .frame(width: 52, height: 62)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(isToday ? Theme.ink : Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(isToday ? Color.clear : Theme.hairline)
        }
    }

    private func sessionCard(_ session: PlannedSession) -> some View {
        let done = session.status == .completed
        return HStack(spacing: Theme.Space.md) {
            Image(systemName: disciplineIcon(session.discipline))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40)
                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
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

    /// A calm, low-emphasis rest day — slimmer than a session card so planned days stand out. No guilt.
    private func restRow(_ day: Date) -> some View {
        Button { presentAdd(for: day) } label: {
            HStack(spacing: Theme.Space.sm) {
                Text("Rest day").font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                Spacer()
                Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface.opacity(0.55))
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline.opacity(0.7))
            }
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

    private var weekSessions: [PlannedSession] {
        days.flatMap { PlanCoaching.todaySessions(plan, on: $0) }
    }

    private var weekTitle: String {
        let cur = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
        if let cur, Calendar.current.isDate(weekStart, inSameDayAs: cur) { return "This week" }
        return weekLabel
    }

    private var weekSummary: String {
        let sessions = weekSessions
        guard !sessions.isEmpty else { return "Open week · tap + to plan" }
        let done = sessions.filter { $0.status == .completed }.count
        let unit = sessions.count == 1 ? "session" : "sessions"
        return done > 0 ? "\(sessions.count) \(unit) · \(done) done" : "\(sessions.count) \(unit)"
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
