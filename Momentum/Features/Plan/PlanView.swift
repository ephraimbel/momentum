import SwiftUI
import SwiftData

/// Plan — a calm weekly command center (PRD §7.7). A week hero with a completion ring, an optional
/// "tune this week" nudge from the coach, then each day as a date badge + quiet session cards. Tap a
/// session to adjust/move/remove it; tap its circle to check it off (earned iridescent). Missed work
/// moves with a one-line note. No red, no guilt.
struct PlanView: View {
    @Environment(\.modelContext) private var context
    @Environment(PaywallController.self) private var paywall
    @Query private var profiles: [UserProfile]
    @Query private var workouts: [Workout]
    @State private var weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    @State private var showingAdd = false
    @State private var addDay = Date()
    @State private var editing: EditingSession?
    @State private var adjusted = false
    @State private var launch: TodayLaunch?
    @State private var pendingStart: PlannedSession?     // start after the detail sheet dismisses
    @State private var locator = LocationService()
    @State private var showSettings = false

    /// Identifiable wrapper so `.sheet(item:)` works regardless of the model's own conformance.
    private struct EditingSession: Identifiable {
        let session: PlannedSession
        var id: PersistentIdentifier { session.persistentModelID }
    }

    private var plan: TrainingPlan? { profiles.first?.plan }
    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }

    /// Free tier sees the current week (the plan glimpse); other weeks are Pro (PRD §10/§13.10).
    private var isCurrentWeek: Bool {
        guard let cur = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start else { return true }
        return Calendar.current.isDate(weekStart, inSameDayAs: cur)
    }
    private var days: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        Group {
            if plan == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        header
                        weekHero
                        hybridCard
                        raceInsightSection
                        if isCurrentWeek { tuneSection }
                        VStack(spacing: Theme.Space.sm) {
                            ForEach(Array(days.enumerated()), id: \.element) { i, day in
                                dayRow(day).reveal(min(Double(i) * 0.04, 0.28))
                            }
                        }
                        .proLocked(.fullPlan, active: !isCurrentWeek)
                    }
                    .padding(Theme.Space.md)
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
        .sheet(item: $editing, onDismiss: {
            if let s = pendingStart { pendingStart = nil; start(s) }
        }) { item in
            SessionDetailSheet(session: item.session, distanceUnit: distanceUnit, profile: profiles.first,
                               onRemove: { delete(item.session) },
                               onStart: { pendingStart = $0 })
        }
        .workoutRunner(launch: $launch)
        .sheet(isPresented: $showSettings) {
            if let p = profiles.first { PlanSettingsSheet(profile: p) { showSettings = false } }
        }
        .onAppear {
            #if DEBUG
            // Open the first long run's detail (fuel-section verification; sim taps are unreliable).
            if ProcessInfo.processInfo.arguments.contains("--plan-detail-long"),
               let long = plan?.sessions.filter({ $0.runType == .long && $0.status == .planned })
                   .min(by: { $0.date < $1.date }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { editing = EditingSession(session: long) }
            }
            #endif
        }
    }

    /// Launch the right recorder for a planned session (uses its precise sport; requests GPS for cardio).
    private func start(_ session: PlannedSession) {
        let t = session.workoutType ?? workoutType(for: session.discipline)
        if t.isStrengthStyle { launch = .strength(type: t, planned: session) }
        else if t.isTimed { launch = .timed(type: t) }
        else {
            locator.requestAuthorization()
            launch = .cardio(type: t, goalMeters: session.targetDistanceM, planned: session, guideRoute: [])
        }
    }

    private func workoutType(for d: Discipline) -> WorkoutType {
        switch d { case .strength: .strength; case .cycling: .ride; case .walking: .walk; case .running: .run }
    }

    private func presentAdd(for day: Date) { addDay = day; showingAdd = true }

    /// R4 coach intelligence: a race-day projection (when a race goal is set) + a Pace Insight reading
    /// "Your week, sequenced" — surfaces the cross-discipline coaching moment: how the week's runs and
    /// lifts are spaced so hard efforts land on fresh legs. Shown only on genuinely hybrid weeks.
    @ViewBuilder
    private var hybridCard: some View {
        if let insight = hybridWeekInsight {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: "figure.run.circle").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("YOUR WEEK, SEQUENCED").font(.rounded(Theme.FontSize.label, weight: .bold))
                        .tracking(1.2).foregroundStyle(Theme.inkTertiary)
                    Text(insight).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your week, sequenced. \(insight)")
        }
    }

    /// The cross-discipline read for the displayed week — nil unless it pairs a leg day with a hard/long
    /// run. Infers "leg day" from a strength session's lower-body primary muscles.
    private var hybridWeekInsight: String? {
        guard let plan else { return nil }
        let cal = Calendar.current
        let items: [HybridSequencing.Item] = plan.sessions.compactMap { s in
            guard let dayIndex = cal.dateComponents([.day], from: weekStart, to: cal.startOfDay(for: s.date)).day,
                  (0...6).contains(dayIndex) else { return nil }
            if s.discipline == .running {
                let hard = s.runType.map { $0.isQuality || $0 == .long } ?? false
                return .init(dayIndex: dayIndex, runType: s.runType, isHardRun: hard, isLegDay: false)
            }
            if s.discipline == .strength {
                let isLeg = s.strengthTargets.contains { pe in
                    (pe.exercise?.primaryMuscles ?? []).contains { HybridSequencing.Item.legMuscles.contains($0) }
                }
                return .init(dayIndex: dayIndex, runType: nil, isHardRun: false, isLegDay: isLeg)
            }
            return nil
        }
        return HybridSequencing.weekInsight(items)
    }

    /// the athlete's recent quality-session pacing. Both are quiet reads above the week.
    @ViewBuilder
    private var raceInsightSection: some View {
        if let plan {
            if let raceM = profiles.first?.raceDistanceM, raceM > 0, plan.p5kSPerKm > 0 {
                RacePredictionCard(raceDistanceM: raceM,
                                   raceDate: profiles.first?.raceDate ?? plan.raceDate,
                                   p5kSPerKm: plan.p5kSPerKm, distanceUnit: distanceUnit)
            }
            let runs = PaceInsights.recentQualityRuns(plan)
            if !runs.isEmpty {
                PaceInsightCard(result: PaceInsights.evaluate(runs))
            }
        }
    }

    private func delete(_ session: PlannedSession) {
        withAnimation(Motion.standard) {
            context.delete(session)
            try? context.save()
        }
        Haptics.light()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Plan").font(.display(34, weight: .black)).foregroundStyle(Theme.ink)
            Spacer()
            if plan != nil {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Plan settings")
            }
            addButton
        }
        .padding(.top, Theme.Space.sm)
    }

    private var addButton: some View {
        Button { presentAdd(for: isCurrentWeek ? Date() : weekStart) } label: {
            Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.background)
                .frame(width: 40, height: 40).background(Circle().fill(Theme.ink))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add session")
    }

    // MARK: Week hero — completion ring + switcher

    private var weekHero: some View {
        let (done, total) = weekProgress
        return HStack(spacing: Theme.Space.md) {
            chevron("chevron.left") { shiftWeek(-1) }
            ZStack {
                ProgressRing(progress: total == 0 ? 0 : Double(done) / Double(total), lineWidth: 7)
                    .frame(width: 60, height: 60)
                VStack(spacing: -2) {
                    Text("\(done)").font(.display(22, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text("of \(total)").font(.rounded(9, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(weekTitle).font(.display(20, weight: .black)).foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
                if let phase = weekPhase {
                    Text(phase.label.uppercased())
                        .font(.rounded(9, weight: .black)).tracking(1)
                        .fixedSize()
                        .foregroundStyle(phase == .taper ? Theme.background : Theme.inkSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background {
                            Capsule().fill(phase == .taper ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                            if phase != .taper { Capsule().stroke(Theme.hairline) }
                        }
                }
                Text(weekPhase?.intent ?? weekSummary)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            chevron("chevron.right") { shiftWeek(1) }
        }
        .padding(Theme.Space.lg)
        .background(card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(weekTitle), \(weekPhase.map { "\($0.label) phase — \($0.intent)" } ?? weekSummary)")
    }

    /// The macrocycle phase of the displayed week (nil off-plan or for legacy plans without phases).
    private var weekPhase: PlanPhase? {
        guard let plan = profiles.first?.plan, !plan.weekPhases.isEmpty,
              let first = plan.sessions.map(\.date).min(),
              let firstWeek = Calendar.current.dateInterval(of: .weekOfYear, for: first)?.start else { return nil }
        let idx = Calendar.current.dateComponents([.weekOfYear], from: firstWeek, to: weekStart).weekOfYear ?? -1
        guard idx >= 0, idx < plan.weekPhases.count else { return nil }
        return PlanPhase(rawValue: plan.weekPhases[idx])
    }

    private func chevron(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: system).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36).background(Circle().fill(Theme.background)).overlay(Circle().stroke(Theme.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Tune this week (coach proposal)

    @ViewBuilder
    private var tuneSection: some View {
        if adjusted {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ink)
                Text("Plan updated for this week.").font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .background(card)
        } else if let proposal = PlanCoaching.proposeAdjustment(plan, workouts: workouts) {
            Button {
                let changed = PlanCoaching.apply(proposal.rec, to: plan, in: context)
                if changed > 0 { Haptics.success(); withAnimation(Motion.standard) { adjusted = true } }
            } label: {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "wand.and.stars").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 38, height: 38).background(Circle().fill(IridescentMaterial()).opacity(0.32))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proposal.headline).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(proposal.detail).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Text("Apply").font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.background)
                        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.ink))
                }
                .padding(Theme.Space.md)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(IridescentMaterial()).opacity(0.12)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Day rows

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
                                Button { PlanCoaching.setCompletion(session, done: session.status != .completed, in: context); Haptics.success() } label: {
                                    Label(session.status == .completed ? "Mark not done" : "Mark done",
                                          systemImage: session.status == .completed ? "arrow.uturn.left" : "checkmark")
                                }
                                Button { editing = EditingSession(session: session) } label: { Label("Adjust…", systemImage: "slider.horizontal.3") }
                                Button(role: .destructive) { delete(session) } label: { Label("Remove", systemImage: "trash") }
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
                .font(.display(18, weight: .heavy)).monospacedDigit()
        }
        // Hierarchy: today fills ink; days with sessions read full-ink; rest days recede.
        .foregroundStyle(isToday ? Theme.background : (hasSessions ? Theme.ink : Theme.inkTertiary))
        .frame(width: 46, height: 54)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(isToday ? Theme.ink : Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(isToday ? Color.clear : Theme.hairline)
        }
    }

    private func sessionCard(_ session: PlannedSession) -> some View {
        let done = session.status == .completed
        return HStack(spacing: Theme.Space.md) {
            // The card body opens the detail/adjust sheet…
            Button { editing = EditingSession(session: session) } label: {
                HStack(spacing: Theme.Space.sm + 2) {
                    Image(systemName: PlanCoaching.icon(for: session))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
                        .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PlanCoaching.brief(for: session, distanceUnit: distanceUnit))
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                        if session.status == .moved, let why = session.rationale {
                            Text(why).font(.rounded(Theme.FontSize.caption, weight: .regular)).foregroundStyle(Theme.inkTertiary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // …and the trailing circle is a quick check-off.
            checkButton(session, done: done)
        }
        .padding(Theme.Space.sm + 2)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            if done { RoundedRectangle(cornerRadius: Theme.Radius.card).fill(IridescentMaterial()).opacity(0.16) }
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
        .frame(maxWidth: .infinity)
    }

    private func checkButton(_ session: PlannedSession, done: Bool) -> some View {
        Button {
            Haptics.success()
            withAnimation(Motion.standard) { PlanCoaching.setCompletion(session, done: !done, in: context) }
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(done ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.inkTertiary))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Completed. Tap to undo." : "Mark done")
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
            .frame(height: 42)
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

    // MARK: Derived

    private var weekSessions: [PlannedSession] {
        days.flatMap { PlanCoaching.todaySessions(plan, on: $0) }
    }
    private var weekProgress: (done: Int, total: Int) {
        let s = weekSessions
        return (s.filter { $0.status == .completed }.count, s.count)
    }

    private var weekTitle: String {
        let cur = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
        if let cur, Calendar.current.isDate(weekStart, inSameDayAs: cur) { return "This week" }
        return weekLabel
    }

    private var weekSummary: String {
        let (done, total) = weekProgress
        guard total > 0 else { return "Open week · tap + to plan" }
        if done == total { return "All done — strong week." }
        return "\(done) done · \(total - done) to go"
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

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }
}
