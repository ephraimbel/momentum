import SwiftUI
import SwiftData

/// Plan — a calm weekly command center (PRD §7.7). A week hero with a completion ring, an optional
/// "tune this week" nudge from the coach, then each day as a date badge + quiet session cards. Tap a
/// session to adjust/move/remove it; tap its circle to check it off (earned iridescent). Missed work
/// moves with a one-line note. No red, no guilt.
struct PlanView: View {
    @Environment(\.modelContext) private var context
    @Environment(PaywallController.self) private var paywall
    @Environment(CoachPresenter.self) private var coach
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
    @State private var showNewPlan = false

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
                        weekStrip
                        if isCurrentWeek { tuneSection }
                        weekBoard
                            .reveal(0.06)
                            .proLocked(.fullPlan, active: !isCurrentWeek)
                        coachsRead
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
        // "Start a new plan" — the same complete form, framed as a beginning: blank name, always
        // rebuilds, honest about replacing the current block (completed work + calibration carry).
        .sheet(isPresented: $showNewPlan) {
            if let p = profiles.first { PlanSettingsSheet(profile: p, mode: .create) { showNewPlan = false } }
        }
        // A coach nav card asked for plan settings — open the sheet the shell steered us toward
        // (onChange covers the case where Plan was already the visible tab).
        .onChange(of: coach.wantsPlanSettings) { _, wants in
            guard wants else { return }
            coach.wantsPlanSettings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showSettings = true }
        }
        .onAppear {
            if coach.wantsPlanSettings {
                coach.wantsPlanSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showSettings = true }
            }
            #if DEBUG
            // --plan-settings: open the plan-settings sheet (screenshot verification; sim can't tap).
            if ProcessInfo.processInfo.arguments.contains("--plan-settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSettings = true }
            }
            // --plan-new: open the start-a-new-plan flow directly.
            if ProcessInfo.processInfo.arguments.contains("--plan-new") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showNewPlan = true }
            }
            // --plan-locked-week: land on next week (the Pro-locked state) for lock-pill verification.
            if ProcessInfo.processInfo.arguments.contains("--plan-locked-week"),
               let next = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: weekStart) {
                weekStart = next
            }
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

    /// The coach's read, grouped BELOW the week (the schedule is the page's job; analysis supports
    /// it): race projection, quality-pace verdict, and the hybrid sequencing note.
    @ViewBuilder
    private var coachsRead: some View {
        if hasCoachsRead {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("COACH'S READ")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, Theme.Space.sm)
                if let plan, let raceM = profiles.first?.raceDistanceM, raceM > 0, plan.p5kSPerKm > 0 {
                    RacePredictionCard(raceDistanceM: raceM,
                                       raceDate: profiles.first?.raceDate ?? plan.raceDate,
                                       p5kSPerKm: plan.p5kSPerKm, distanceUnit: distanceUnit)
                }
                if let plan {
                    let runs = PaceInsights.recentQualityRuns(plan)
                    if !runs.isEmpty {
                        PaceInsightCard(result: PaceInsights.evaluate(runs))
                    }
                }
                hybridCard
            }
        }
    }

    private var hasCoachsRead: Bool {
        guard let plan else { return false }
        if let raceM = profiles.first?.raceDistanceM, raceM > 0, plan.p5kSPerKm > 0 { return true }
        if !PaceInsights.recentQualityRuns(plan).isEmpty { return true }
        return hybridWeekInsight != nil
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(planDisplayName)
                    .font(.display(34, weight: .black)).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.55)
                Spacer()
                if plan != nil {
                    // Two distinct intents, named plainly: tune what exists, or begin again.
                    // Goals change — starting over is a first-class move, never buried.
                    Menu {
                        Button { showSettings = true } label: {
                            Label("Adjust this plan", systemImage: "slider.horizontal.3")
                        }
                        Button { showNewPlan = true } label: {
                            Label("Start a new plan", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Plan options")
                }
                addButton
            }
            if let context = planContextLine {
                Text(context)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.top, Theme.Space.sm)
    }

    /// One quiet line of what this plan is FOR — the race and its countdown when one is set, else
    /// the goal. The plan page should never make you wonder what it's building toward.
    private var planContextLine: String? {
        guard let profile = profiles.first else { return nil }
        if let raceM = profile.raceDistanceM, raceM > 0, let raceDate = profile.raceDate, raceDate > Date() {
            let label = RaceDistance.nearest(toMeters: raceM).label
            let weeks = Calendar.current.dateComponents([.weekOfYear], from: Date(), to: raceDate).weekOfYear ?? 0
            let day = raceDate.formatted(.dateTime.month(.abbreviated).day())
            return weeks >= 2 ? "\(label) · \(day) · \(weeks) weeks to go" : "\(label) · \(day) — race week"
        }
        guard let idx = planWeekIndex(of: currentWeekStart), planWeekStarts.count > 1 else { return nil }
        let prefix = (plan?.name.isEmpty ?? true) ? "Training plan · " : ""
        return "\(prefix)Week \(idx + 1) of \(planWeekStarts.count)"
    }

    /// The athlete's name for the block is the page title ("Austin Marathon"); unnamed plans stay "Plan".
    private var planDisplayName: String {
        let name = plan?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Plan" : name
    }

    private var currentWeekStart: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
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

    // MARK: Week strip + hero

    /// The plan's spine (Runna's signature): every training week as a chip — where you've been,
    /// where you are, what's left. Tap to jump; the strip auto-centers on the selection. Falls back
    /// to chevron paging when a plan has no derivable weeks (legacy/empty).
    @ViewBuilder
    private var weekStrip: some View {
        let weeks = planWeekStarts
        if weeks.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(Array(weeks.enumerated()), id: \.element) { i, start in
                            weekChip(index: i, start: start)
                                .id(i)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    if let idx = planWeekIndex(of: weekStart) { proxy.scrollTo(idx, anchor: .center) }
                }
                .onChange(of: weekStart) {
                    if let idx = planWeekIndex(of: weekStart) {
                        withAnimation(Motion.standard) { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
            }
        }
    }

    private func weekChip(index: Int, start: Date) -> some View {
        let selected = Calendar.current.isDate(start, inSameDayAs: weekStart)
        let isPast = start < currentWeekStart
        let isCurrent = Calendar.current.isDate(start, inSameDayAs: currentWeekStart)
        return Button {
            Haptics.selection()
            withAnimation(Motion.standard) { weekStart = start }
        } label: {
            VStack(spacing: 2) {
                Text("WK").font(.rounded(8, weight: .black)).tracking(0.8)
                Text("\(index + 1)").font(.display(15, weight: .heavy)).monospacedDigit()
            }
            .foregroundStyle(selected ? Theme.background : (isPast ? Theme.inkTertiary : Theme.ink))
            .frame(width: 44, height: 44)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.ink : Theme.surface)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.clear : Theme.hairline)
            }
            .overlay(alignment: .bottom) {
                // The current calendar week keeps a quiet anchor dot even when browsing elsewhere.
                if isCurrent && !selected {
                    Circle().fill(Theme.ink).frame(width: 3.5, height: 3.5).offset(y: -4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Week \(index + 1)\(isCurrent ? ", current" : "")\(selected ? ", selected" : "")")
    }

    /// The board's header: the week's story (title, phase, intent) and its progress. Lives INSIDE
    /// the board card now — no surface of its own — so the week reads as one object: story on top,
    /// schedule below, a single hairline between them.
    private var boardHeader: some View {
        let (done, total) = weekProgress
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
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
                Spacer(minLength: 0)
                if planWeekStarts.count <= 1 {
                    chevron("chevron.left") { shiftWeek(-1) }
                    chevron("chevron.right") { shiftWeek(1) }
                }
            }
            Text(weekPhase?.intent ?? weekSummary)
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .contentTransition(.opacity)
            // One slim bar tells the week's completion story; the numbers make it exact.
            if total > 0 {
                HStack(spacing: Theme.Space.sm) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline.opacity(0.7))
                            Capsule()
                                .fill(done == total ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                                .frame(width: max(5, geo.size.width * CGFloat(done) / CGFloat(total)))
                        }
                    }
                    .frame(height: 5)
                    Text("\(done) of \(total)")
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize()
                    if let volume = weekVolumeText {
                        Text("· \(volume)")
                            .font(.rounded(Theme.FontSize.label, weight: .bold))
                            .foregroundStyle(Theme.inkTertiary)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(weekTitle), \(weekPhase.map { "\($0.label) phase — \($0.intent)" } ?? weekSummary), \(done) of \(total) sessions done")
    }

    /// The displayed week's planned running volume ("18.6 mi planned").
    private var weekVolumeText: String? {
        let meters = weekSessions.compactMap(\.targetDistanceM).reduce(0, +)
        guard meters > 0 else { return nil }
        return "\(Formatters.distance(meters: meters, unit: distanceUnit)) planned"
    }

    /// The Monday of every week the plan spans — the strip's data.
    private var planWeekStarts: [Date] {
        guard let plan, let first = plan.sessions.map(\.date).min(),
              let last = plan.sessions.map(\.date).max(),
              let start = Calendar.current.dateInterval(of: .weekOfYear, for: first)?.start else { return [] }
        var out: [Date] = []
        var d = start
        while d <= last, out.count < 64 {
            out.append(d)
            guard let next = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    private func planWeekIndex(of week: Date) -> Int? {
        planWeekStarts.firstIndex { Calendar.current.isDate($0, inSameDayAs: week) }
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

    // MARK: The week board — the whole week as one organized object

    /// A single card holding all seven days as rows, hairline-separated, today banded and pilled.
    /// Zooming the week out into one surface makes the schedule read at a glance and binds every
    /// session unmistakably to its day (same row, date anchored left). Replaces the old free-floating
    /// day rows.
    private var weekBoard: some View {
        VStack(spacing: 0) {
            boardHeader
            // A full-bleed hairline splits the week's story from its schedule.
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            ForEach(Array(days.enumerated()), id: \.element) { i, day in
                boardDayRow(day)
                if i < days.count - 1 {
                    Rectangle().fill(Theme.hairline)
                        .frame(height: 0.5)
                        .padding(.leading, Self.dateColWidth + Theme.Space.md * 2)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private static let dateColWidth: CGFloat = 42

    private func boardDayRow(_ day: Date) -> some View {
        let sessions = PlanCoaching.todaySessions(plan, on: day)
        let isToday = Calendar.current.isDateInToday(day)
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            boardDateColumn(day, isToday: isToday, hasSessions: !sessions.isEmpty)
            Group {
                if sessions.isEmpty {
                    boardRestLine(day)
                } else {
                    VStack(spacing: Theme.Space.sm + 2) {
                        ForEach(sessions, id: \.persistentModelID) { session in
                            sessionLine(session)
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
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, sessions.isEmpty ? 11 : 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Today wears a whisper of tint so the eye lands on it inside the week.
        .background(isToday ? Theme.ink.opacity(0.045) : Color.clear)
    }

    /// The day's anchor: weekday + date, left-aligned. Today fills an ink pill; days with work read
    /// full-ink; rest days recede to tertiary. Sits slightly below the divider so it aligns with the
    /// first session's title rather than the icon top.
    private func boardDateColumn(_ day: Date, isToday: Bool, hasSessions: Bool) -> some View {
        VStack(spacing: 0) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.rounded(9.5, weight: .black)).tracking(0.4)
            Text(day.formatted(.dateTime.day()))
                .font(.display(19, weight: .heavy)).monospacedDigit()
        }
        .foregroundStyle(isToday ? Theme.background : (hasSessions ? Theme.ink : Theme.inkTertiary))
        .frame(width: Self.dateColWidth, height: 44)
        .background {
            if isToday {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.ink)
            }
        }
        .padding(.top, 1)
    }

    /// A session, flattened onto the board (no card of its own — the board provides the surface).
    /// Tap the body to adjust/move; tap the trailing circle to check it off. Completed reads with a
    /// soft strike so the week's progress is legible at a glance.
    private func sessionLine(_ session: PlannedSession) -> some View {
        let done = session.status == .completed
        return HStack(spacing: Theme.Space.sm + 2) {
            Button { editing = EditingSession(session: session) } label: {
                HStack(spacing: Theme.Space.sm + 2) {
                    Image(systemName: PlanCoaching.icon(for: session))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(done ? Theme.inkTertiary : Theme.ink)
                        .frame(width: 34, height: 34)
                        .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                    VStack(alignment: .leading, spacing: 2) {
                        if let kind = sessionKindLabel(session) {
                            Text(kind)
                                .font(.rounded(9, weight: .black)).tracking(1)
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        Text(PlanCoaching.brief(for: session, distanceUnit: distanceUnit))
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(done ? Theme.inkTertiary : Theme.ink)
                            .strikethrough(done, color: Theme.inkTertiary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .multilineTextAlignment(.leading)
                        if session.status == .moved, let why = session.rationale {
                            Text(why).font(.rounded(Theme.FontSize.caption, weight: .regular))
                                .foregroundStyle(Theme.inkTertiary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            checkButton(session, done: done)
        }
        .frame(maxWidth: .infinity)
    }

    /// The session's TYPE as a quiet eyebrow ("TEMPO RUN", "LONG RUN", "STRENGTH") — the Runna
    /// pattern: what KIND of day it is reads before the numbers do.
    private func sessionKindLabel(_ session: PlannedSession) -> String? {
        if session.discipline == .strength { return "STRENGTH" }
        if let wt = session.workoutType, wt != .run, !wt.isStrengthStyle { return wt.title.uppercased() }
        if let rt = session.runType {
            return rt == .intervals ? "INTERVALS" : "\(rt.rawValue.uppercased()) RUN"
        }
        return nil
    }

    private func checkButton(_ session: PlannedSession, done: Bool) -> some View {
        Button {
            Haptics.success()
            withAnimation(Motion.standard) { PlanCoaching.setCompletion(session, done: !done, in: context) }
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(done ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.inkTertiary.opacity(0.7)))
                .frame(width: 34, height: 44, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Completed. Tap to undo." : "Mark done")
    }

    /// A rest day is a non-event by design — one quiet line that recedes, so the four or five of
    /// them in a normal week never dominate the board. Still tappable to add a session.
    private func boardRestLine(_ day: Date) -> some View {
        Button { presentAdd(for: day) } label: {
            HStack(spacing: Theme.Space.sm) {
                Text("Rest day")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary.opacity(0.75))
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary.opacity(0.55))
            }
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rest day — tap to add a session")
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.lg) {
            BrandMark(size: 72)
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
