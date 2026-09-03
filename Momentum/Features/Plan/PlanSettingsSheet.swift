import SwiftUI
import SwiftData

/// Change the plan's fundamentals — or point it at a whole new race — and rebuild. Running-first
/// (the app's identity): name the block, pick the focus, choose the race distance and date (any
/// timeframe — race week to next year), set an optional goal time, and get the HONEST feasibility
/// read live before committing. Edits are buffered and only applied on save, which regenerates the
/// upcoming plan (calibrated pace + completed work are kept). Cancel changes nothing.
struct PlanSettingsSheet: View {
    /// Two intents, one complete form. `.adjust` tunes the current plan (buffered, rename-only
    /// never rebuilds); `.create` is a fresh start — blank name, always rebuilds, honest about
    /// replacing the current block. Goals change; beginning again is a first-class flow.
    enum Mode { case adjust, create }

    let profile: UserProfile
    var mode: Mode = .adjust
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    /// A new plan has no silently inherited objective: the athlete actively chooses what this block
    /// is for. Adjusting an existing plan starts from its current goal, ready to confirm or change.
    @State private var goal: Goal?
    @State private var raceDistance: RaceDistance?
    @State private var hasRaceDate: Bool
    @State private var raceDate: Date
    @State private var hasGoalTime: Bool
    @State private var goalHours: Int
    @State private var goalMinutes: Int
    @State private var intensity: PlanIntensity
    /// The athlete's weekly-mileage ceiling (meters); nil = the coach builds to the goal.
    @State private var targetWeekly: Double?
    @State private var hybridPriority: HybridPriority
    @State private var strengthSplit: StrengthSplitStyle
    @State private var days: Int
    @State private var minutes: Int
    @State private var equipment: Equipment
    @State private var showRacePicker = false
    @State private var saveFailed = false
    /// The live starting point used by the generator. Seeded immediately through the same staleness
    /// rules as generation, then refreshed once from Momentum-logged workouts when the sheet appears.
    @State private var currentWeeklyM: Double?
    @State private var currentLongestM: Double?
    @State private var baselineUsesLoggedRuns = false
    /// The season's tune-up races (B/C), buffered like everything else; `loadedTuneUps` is what
    /// the records held when the sheet opened, so `structural` can tell an edit from a look.
    @State private var tuneUps: [TuneUpEvent] = []
    @State private var loadedTuneUps: [TuneUpEvent] = []
    @State private var tuneUpsLoaded = false
    @State private var editingTuneUp: TuneUpEvent?
    @State private var addingTuneUp = false

    init(profile: UserProfile, mode: Mode = .adjust, onDone: @escaping () -> Void) {
        self.profile = profile
        self.mode = mode
        self.onDone = onDone
        // A new plan starts with a blank name (its own occasion); adjusting keeps the current one.
        _name = State(initialValue: mode == .create ? "" : (profile.plan?.name ?? ""))
        _goal = State(initialValue: mode == .create ? nil : profile.goal)
        let defaultRaceDate = Calendar.current.date(byAdding: .weekOfYear, value: 12, to: Date()) ?? Date()
        // Beginning again keeps useful coaching context (availability, equipment, current fitness),
        // but not the previous finish line. Distance, date, and time are decisions about THIS goal.
        _raceDistance = State(initialValue: mode == .create
            ? nil : profile.raceDistanceM.map(RaceDistance.nearest(toMeters:)))
        _hasRaceDate = State(initialValue: mode == .adjust && profile.raceDate != nil)
        _raceDate = State(initialValue: mode == .adjust ? (profile.raceDate ?? defaultRaceDate) : defaultRaceDate)
        let goalS = mode == .create ? nil : profile.goalFinishTimeS
        _hasGoalTime = State(initialValue: goalS != nil)
        _goalHours = State(initialValue: goalS.map { Int($0) / 3600 } ?? 4)
        _goalMinutes = State(initialValue: goalS.map { (Int($0) % 3600) / 60 } ?? 0)
        _intensity = State(initialValue: profile.planIntensity.flatMap(PlanIntensity.init(rawValue:)) ?? .balanced)
        _targetWeekly = State(initialValue: profile.targetWeeklyRunVolumeM)
        _hybridPriority = State(initialValue: profile.hybridPriority.flatMap(HybridPriority.init(rawValue:)) ?? .balanced)
        _strengthSplit = State(initialValue: StrengthSplitStyle(rawValue: profile.strengthSplit) ?? .coach)
        _days = State(initialValue: profile.daysPerWeek)
        _minutes = State(initialValue: profile.sessionMinutes)
        _equipment = State(initialValue: profile.equipment)
        // Do not flash a months-old onboarding peak while the bounded background query runs. The
        // empty-evidence snapshot preserves fresh declarations and applies the conservative returning
        // baseline for established athletes; the task below then replaces it with recent run evidence.
        let startingFitness = PlanFitnessEvidence.snapshot(
            runs: [],
            declaredWeeklyM: profile.weeklyRunVolumeM,
            declaredLongestM: profile.longestRunM,
            profileCreatedAt: profile.createdAt,
            endingAt: Date(),
            calendar: .current
        )
        _currentWeeklyM = State(initialValue: startingFitness.weeklyM)
        _currentLongestM = State(initialValue: startingFitness.longestM)
    }

    private var lifting: Bool {
        goal == .buildMuscle || goal == .getStronger
            || profile.disciplines.contains(Discipline.strength.rawValue)
    }
    private var racing: Bool { goal == .raceDistance }
    /// Momentum sells running coaching. The selected goal changes the destination and the role of
    /// supporting strength; it never turns this sheet into a generic non-running plan builder.
    private var runningFocus: Bool {
        true
    }
    /// Only athletes who both run AND lift get the balance dial — it's the one control that
    /// splits the training week between the two (the engine reads it only when both are present).
    private var hybrid: Bool {
        runningFocus && lifting
    }

    /// Anything the generator reads changed → save rebuilds the upcoming weeks.
    /// The race-date comparison is DAY-granular: `newRaceDate` is normalized to startOfDay, but a
    /// stored `profile.raceDate` can carry a time component (onboarding's date math) — comparing
    /// raw dates made an untouched sheet read "Rebuild plan" and rebuild on a rename.
    private var structural: Bool {
        goal != profile.goal || days != profile.daysPerWeek
            || minutes != profile.sessionMinutes || equipment != profile.equipment
            || newRaceDistanceM != profile.raceDistanceM
            || newRaceDate != profile.raceDate.map { Calendar.current.startOfDay(for: $0) }
            || newGoalFinishTimeS != profile.goalFinishTimeS
            || intensity.rawValue != (profile.planIntensity ?? PlanIntensity.balanced.rawValue)
            || targetWeekly != profile.targetWeeklyRunVolumeM
            || (hybrid && hybridPriority.rawValue != (profile.hybridPriority ?? HybridPriority.balanced.rawValue))
            || (lifting && strengthSplit.rawValue != profile.strengthSplit)
            || tuneUpsChanged
    }

    private var tuneUpsChanged: Bool {
        tuneUpsLoaded && Set(activeTuneUps) != Set(loadedTuneUps)
    }

    /// The tune-ups that reach the plan: only while racing, and only the ones before the goal race.
    private var activeTuneUps: [TuneUpEvent] {
        guard racing else { return [] }
        let goalDate = newRaceDate
        return tuneUps.filter { event in goalDate.map { event.date < $0 } ?? true }
            .sorted { $0.date < $1.date }
    }

    /// Where a new tune-up may land: a week out at the earliest, three days before the goal race
    /// at the latest (the command enforces the same rules on Save).
    private var tuneUpDateRange: ClosedRange<Date> {
        let cal = Calendar.current
        let earliest = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: Date())) ?? Date()
        let latest = newRaceDate.flatMap { cal.date(byAdding: .day, value: -3, to: $0) }
            ?? cal.date(byAdding: .year, value: 1, to: earliest) ?? earliest
        return earliest...max(earliest, latest)
    }

    private var newRaceDistanceM: Double? { racing ? raceDistance?.meters : nil }
    private var newRaceDate: Date? {
        guard racing && hasRaceDate else { return nil }
        let d = Calendar.current.startOfDay(for: raceDate)
        // A race date in the past is stale (the race elapsed and no new plan was made). Feeding it to
        // the generator yields a degenerate 1-week plan (weeksToRace clamps to 1), so treat it as "no
        // date" — the feasibility card prompts for a fresh one instead of racing toward yesterday.
        return d > Calendar.current.startOfDay(for: Date()) ? d : nil
    }
    private var newGoalFinishTimeS: Double? {
        let seconds = Double(goalHours * 3600 + goalMinutes * 60)
        return racing && hasGoalTime && seconds > 0 ? seconds : nil
    }

    private var canCommit: Bool {
        guard goal != nil else { return false }
        if racing && raceDistance == nil { return false }
        if racing && hasGoalTime && newGoalFinishTimeS == nil { return false }
        return true
    }

    /// The honest read for the race + date on screen right now — same engine as onboarding.
    private var feasibility: PlanFeasibility? {
        guard racing, let distanceM = newRaceDistanceM, let date = newRaceDate else { return nil }
        let weeks = PlanEngine.weeksToRace(startDate: Date(), raceDate: date, calendar: .current) ?? 0
        let experience = ExperienceLevel(rawValue: profile.experience[Discipline.running.rawValue] ?? "") ?? .some
        return PlanFeasibility.assess(raceDistanceM: distanceM,
                                      goalFinishTimeS: newGoalFinishTimeS,
                                      currentP5kSPerKm: profile.plan?.p5kSPerKm,
                                      currentWeeklyVolumeM: currentWeeklyM ?? 0,
                                      weeksAvailable: weeks,
                                      experience: experience,
                                      injuryProne: !profile.injuryHistory.isEmpty,
                                      daysPerWeek: days,   // the BUFFERED picker value — verdict updates live
                                      intensity: intensity,
                                      targetWeeklyVolumeM: targetWeekly)
    }

    private var recommendedIntensity: PlanIntensity {
        if let recommendation = feasibility?.recommended { return recommendation }
        let experience = ExperienceLevel(rawValue: profile.experience[Discipline.running.rawValue] ?? "")
            ?? ExperienceLevel(rawValue: profile.experience[Discipline.strength.rawValue] ?? "")
            ?? .some
        return experience == .new || !profile.injuryHistory.isEmpty ? .gentle : .balanced
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    nameSection
                    goalSection
                    if racing { raceSection }
                    if racing { tuneUpSection }
                    startingPointSection
                    if hybrid { balanceSection }
                    intensitySection
                    if racing { ceilingSection }
                    daysSection
                    sessionSection
                    if lifting { splitSection }
                    if lifting { equipmentSection }
                    Text(footerNote)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationTitle(mode == .create ? "New plan" : "Plan settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { apply() }
                        .fontWeight(.semibold)
                        .disabled(!canCommit)
                        .accessibilityValue(commitAccessibilityValue)
                }
            }
            // Hosted at stack level so the catalog can open from ANY state — picking a race is
            // allowed to be the thing that switches the plan's focus to racing.
            .alert("Couldn't save your plan", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Something went wrong writing to storage. Your settings are still here — try Save again.")
            }
            .sheet(isPresented: $showRacePicker) {
                RacePickerSheet { race, pickedDistance, date in
                    withAnimation(Motion.standard) {
                        goal = .raceDistance
                        name = race.name
                        raceDistance = pickedDistance
                        hasRaceDate = true
                        raceDate = date
                    }
                }
            }
            .task {
                loadTuneUps()
                await refreshStartingPoint()
            }
            .sheet(isPresented: $addingTuneUp) {
                TuneUpEditorSheet(event: nil, range: tuneUpDateRange, others: activeTuneUps) { saved in
                    withAnimation(Motion.standard) { tuneUps.append(saved) }
                }
            }
            .sheet(item: $editingTuneUp) { editing in
                TuneUpEditorSheet(event: editing, range: tuneUpDateRange,
                                  others: activeTuneUps.filter { $0.id != editing.id }) { saved in
                    withAnimation(Motion.standard) {
                        if let i = tuneUps.firstIndex(where: { $0.id == saved.id }) { tuneUps[i] = saved }
                    }
                }
            }
            .onAppear {
                #if DEBUG
                // --race-picker: open the catalog directly (screenshot verification; sim can't tap).
                if ProcessInfo.processInfo.arguments.contains("--race-picker") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showRacePicker = true }
                }
                // --tuneup-editor: open the tune-up editor directly (screenshot verification).
                if ProcessInfo.processInfo.arguments.contains("--tuneup-editor") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { addingTuneUp = true }
                }
                #endif
            }
            .onChange(of: hasGoalTime) { _, enabled in
                // Never open a 5K target-time picker at the old generic 4:00 default. Start from the
                // athlete's current fitness estimate (or a distance-appropriate fallback), then let
                // them make the actual goal decision minute by minute.
                if enabled, mode == .create || profile.goalFinishTimeS == nil { seedGoalTime() }
            }
            .onChange(of: raceDistance) { _, _ in
                if hasGoalTime, mode == .create || profile.goalFinishTimeS == nil { seedGoalTime() }
            }
        }
        .presentationBackground(Theme.background)
    }

    // MARK: Sections

    /// Name the block after what it's FOR ("Austin Marathon") — the name becomes the Plan page
    /// title and marks plan sessions wherever they surface.
    private var nameSection: some View {
        section("PLAN NAME · OPTIONAL") {
            TextField("e.g. Austin Marathon", text: $name)
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .padding(Theme.Space.md)
                .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    /// One explicit objective anchors every generated block. A new-plan flow intentionally has no
    /// preselected card: tapping Create without deciding used to rebuild the old goal under a new name.
    private var goalSection: some View {
        let goals: [Goal] = [
            .raceDistance, .endurance, .stayConsistent, .generalFitness,
            .loseFat, .buildMuscle, .getStronger]
        return section("YOUR GOAL") {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(mode == .create
                     ? "Choose the outcome first. We’ll build the training load, recovery, and week around it."
                     : "This is the anchor for every upcoming session. Change it and we’ll re-point the block from today.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Theme.Space.xs)
                ForEach(goals, id: \.self) { item in
                    SelectionCard(title: item.planLabel, subtitle: item.planSubtitle,
                                  systemImage: item.planSystemImage, isSelected: goal == item) {
                        withAnimation(Motion.standard) { goal = item }
                    }
                }
            }
        }
    }

    /// The coaching hand-off: show the exact baseline regeneration will use before asking how hard
    /// to push. This is not editable here because it is evidence, not preference — the controls below
    /// are the athlete's decisions; this card is the coach saying "here is where we are starting."
    @ViewBuilder
    private var startingPointSection: some View {
        if runningFocus {
            section("WHERE YOU ARE NOW") {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    if currentWeeklyM != nil || currentLongestM != nil {
                        HStack(spacing: 0) {
                            baselineMetric(currentWeeklyM.map { Formatters.distance(meters: $0, unit: distanceUnit) } ?? "—",
                                           "PER WEEK")
                            Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
                            baselineMetric(currentLongestM.map { Formatters.distance(meters: $0, unit: distanceUnit) } ?? "—",
                                           "LONGEST RUN")
                            if let p5k = profile.plan?.p5kSPerKm, p5k > 0 {
                                Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
                                baselineMetric(PlanFeasibility.hms(p5k * 5), "5K FITNESS")
                            }
                        }
                    } else {
                        Text("Not enough running history yet")
                            .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text("We’ll start conservatively and recalibrate from the runs you log in Momentum.")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(baselineUsesLoggedRuns
                         ? "Based on your recent Momentum workouts, with your saved starting point as a guardrail."
                         : "Based on your saved starting point. Momentum workouts will replace the estimate as your history grows.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
            }
        } else {
            section("WHERE YOU ARE NOW") {
                HStack(spacing: 0) {
                    baselineMetric(experienceLabel(for: .strength), "EXPERIENCE")
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
                    baselineMetric("\(profile.daysPerWeek)", "DAYS / WEEK")
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
                    baselineMetric("\(profile.sessionMinutes)m", "SESSION")
                }
                .padding(Theme.Space.md)
                .background(cardBackground)
            }
        }
    }

    private func baselineMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.display(17, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(label)
                .font(.rounded(9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    /// The heart of the sheet: which race, when, and how fast — with the honest verdict live.
    private var raceSection: some View {
        section("YOUR RACE") {
            VStack(spacing: Theme.Space.sm) {
                // The occasion, first: pick a real race from the catalog — name, distance, and
                // date land in one tap (and stay editable below).
                Button { showRacePicker = true } label: {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Find your race")
                                .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                            Text("Boston, Chicago, Hong Kong — the big ones, with dates")
                                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    }
                    .padding(Theme.Space.md)
                    .background(cardBackground)
                }
                .buttonStyle(.plain)

                ForEach(RaceDistance.allCases) { d in
                    SelectionCard(title: d.label, isSelected: raceDistance == d) {
                        withAnimation(Motion.standard) { raceDistance = d }
                    }
                }

                Toggle(isOn: $hasRaceDate.animation(Motion.standard)) {
                    Text("I have a race date")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                .padding(Theme.Space.md)
                .background(cardBackground)

                if hasRaceDate {
                    DatePicker("Race day", selection: $raceDate,
                               in: Date()..., displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding(Theme.Space.sm)
                        .background(cardBackground)
                }

                Toggle(isOn: $hasGoalTime.animation(Motion.standard)) {
                    Text("Target finish time")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                .padding(Theme.Space.md)
                .background(cardBackground)

                if hasGoalTime {
                    HStack(spacing: 0) {
                        Picker("Hours", selection: $goalHours) {
                            ForEach(0..<10, id: \.self) { Text("\($0) hr").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        Picker("Minutes", selection: $goalMinutes) {
                            ForEach(0..<60, id: \.self) { Text(String(format: "%02d min", $0)).tag($0) }
                        }
                        .pickerStyle(.wheel)
                    }
                    .frame(height: 110)
                    .background(cardBackground)
                }

                if let f = feasibility {
                    feasibilityCard(f)
                }
            }
        }
    }

    // MARK: Tune-up races (2026-09-03)

    /// The season's other races. A B race is raced (two easy days in, the race in place of that
    /// week's quality, easy days out); a C race is trained through. Neither touches the block
    /// toward the goal race — only the week it lands in bends.
    private var tuneUpSection: some View {
        section("TUNE-UP RACES") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(activeTuneUps) { event in
                    // Two buttons side by side, never nested: the row edits, the cross removes.
                    HStack(spacing: Theme.Space.sm) {
                        Button { editingTuneUp = event } label: {
                            HStack(spacing: Theme.Space.md) {
                                Image(systemName: event.priority == .b ? "flag.fill" : "flag")
                                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tuneUpTitle(event))
                                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                                    Text(tuneUpSubtitle(event))
                                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tuneup-row")
                        Button {
                            withAnimation(Motion.standard) { tuneUps.removeAll { $0.id == event.id } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18)).foregroundStyle(Theme.inkTertiary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(tuneUpTitle(event))")
                    }
                    .padding(Theme.Space.md)
                    .background(cardBackground)
                }
                if activeTuneUps.count < 4 {
                    Button { addingTuneUp = true } label: {
                        HStack(spacing: Theme.Space.md) {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add a tune-up race")
                                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                                Text(activeTuneUps.isEmpty
                                     ? "A shorter race on the way to the goal. Race it, or train through it."
                                     : "Up to four on a season.")
                                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                        }
                        .padding(Theme.Space.md)
                        .background(cardBackground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("add-tuneup")
                }
            }
        }
    }

    private func tuneUpTitle(_ event: TuneUpEvent) -> String {
        let distance = RaceDistance.nearest(toMeters: event.distanceM).label
        let name = event.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? distance : "\(name) · \(distance)"
    }

    private func tuneUpSubtitle(_ event: TuneUpEvent) -> String {
        let when = event.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(when) · \(event.priority == .b ? "Race it" : "Train through")"
    }

    /// The season's planned B/C events, once, when the sheet opens.
    private func loadTuneUps() {
        guard !tuneUpsLoaded else { return }
        tuneUpsLoaded = true
        guard mode == .adjust, let season = PlanService.activeSeason(for: profile, in: context) else {
            loadedTuneUps = []
            return
        }
        let seasonID = season.id
        let records = (try? context.fetch(FetchDescriptor<RunningEventRecord>(
            predicate: #Predicate { $0.seasonID == seasonID }))) ?? []
        let loaded = records.compactMap { record -> TuneUpEvent? in
            guard record.statusRaw == RunningEventStatus.planned.rawValue,
                  let priority = RunningEventPriority(rawValue: record.priorityRaw), priority != .a,
                  let distance = record.distanceM, distance > 0 else { return nil }
            return TuneUpEvent(id: record.id, name: record.name, date: record.date, distanceM: distance,
                               priority: priority, goalTimeS: record.durationS)
        }
        .sorted { $0.date < $1.date }
        loadedTuneUps = loaded
        tuneUps = loaded
    }

    /// The same honesty moment as onboarding — verdict first, never a fantasy.
    private func feasibilityCard(_ f: PlanFeasibility) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: f.verdict == .onTrack ? "checkmark.seal.fill"
                  : f.verdict == .tight ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.headline)
                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Text(f.detail)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The honest alternatives ("push the race out", "aim for the half first") — the
                // same guidance onboarding shows with a tight verdict; dropping it here left the
                // settings sheet saying "that's tight" with no way forward.
                if !f.options.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(f.options, id: \.self) { opt in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.purple).padding(.top, 2)
                                Text(opt).font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
    }

    /// Run & lift balance — the same three-way emphasis the onboarding offers, so a hybrid athlete
    /// can re-weight the week (run-first / even / lift-first) anytime. Drives the day split in the
    /// engine (`HybridPriority.liftFraction`); only shown when the athlete both runs and lifts.
    /// The athlete's strength split (2026-08-20, user call): coach's pick by default, or an
    /// explicit full-body / upper-lower / push-pull-legs week. Structural — changing it rebuilds
    /// the upcoming strength days with the new day templates.
    private var splitSection: some View {
        let opts: [(StrengthSplitStyle, String, String, String)] = [
            (.coach, "Coach's pick", "Full body, splitting as your lift days grow", "wand.and.stars"),
            (.fullBody, "Full body", "Every lift day trains everything", "figure.strengthtraining.traditional"),
            (.upperLower, "Upper · Lower", "Alternating upper-body and lower-body days", "figure.arms.open"),
            (.pushPullLegs, "Push · Pull · Legs", "The classic three-day rotation", "dumbbell.fill")]
        return section("STRENGTH SPLIT") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(opts, id: \.0) { o in
                    SelectionCard(title: o.1, subtitle: o.2, systemImage: o.3,
                                  isSelected: strengthSplit == o.0) {
                        withAnimation(Motion.standard) { strengthSplit = o.0 }
                    }
                }
                if strengthSplit != .coach && strengthSplit != .fullBody {
                    Text("A split needs at least two lift days a week — with fewer, sessions stay full body.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
        }
    }

    private var balanceSection: some View {
        let opts: [(HybridPriority, String, String, String)] = [
            (.running, "Running comes first", "Lift to support the miles", "figure.run"),
            (.balanced, "Balanced runner", "More strength, with running still leading", "figure.run.circle"),
            (.lifting, "More strength support", "Near-even split; the extra day stays a run", "dumbbell.fill")]
        return section("RUN & LIFT BALANCE") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(opts, id: \.0) { o in
                    SelectionCard(title: o.1, subtitle: o.2, systemImage: o.3,
                                  isSelected: hybridPriority == o.0) {
                        withAnimation(Motion.standard) { hybridPriority = o.0 }
                    }
                }
            }
        }
    }

    /// How hard to push — explicitly framed as the route to the selected goal, not a generic effort
    /// preference. The engine's recommendation is visible here just as it is during onboarding.
    private var intensitySection: some View {
        section("THE PATH TO YOUR GOAL") {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Intensity changes how quickly volume grows, the peak load, and how much quality work fits. Recovery guardrails never switch off.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Theme.Space.xs)
                ForEach(PlanIntensity.allCases) { level in
                    SelectionCard(title: level == recommendedIntensity ? "\(level.label)  ·  Recommended" : level.label,
                                  subtitle: level.subtitle,
                                  isSelected: intensity == level,
                                  iridescent: level == .podium) {
                        intensity = level
                        // Podium's structure needs the week to hold it — lift days to the floor.
                        if days < level.floorDays { days = level.floorDays }
                    }
                }
                if intensity == .podium {
                    Text("Podium trains \(PlanIntensity.podium.floorDays)+ days a week — your week is set to \(days). Every recovery guardrail still applies.")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let note = intensity.riskNote {
                    Text(note)
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Space.xs)
                }
            }
        }
    }

    // MARK: Mileage ceiling (2026-08-28)

    private var distanceUnit: DistanceUnit {
        (DistanceUnit(rawValue: profile.distanceUnit) ?? .auto).resolved()
    }
    private var metersPerUnit: Double {
        distanceUnit == .metric ? 1_000 : 1609.344
    }
    private var unitLabel: String {
        distanceUnit == .metric ? "km" : "mi"
    }
    /// Ceiling choices in the athlete's unit: the coach's call, then four steps above their
    /// current weekly volume. The current cap is always offered so an odd value isn't lost.
    private var ceilingChoices: [Int] {
        let weekly = Int(((currentWeeklyM ?? 0) / metersPerUnit / 5).rounded()) * 5
        var out = [0] + [10, 20, 30, 40].map { weekly + $0 }
        if let t = targetWeekly {
            let v = Int((t / metersPerUnit).rounded())
            if !out.contains(v) { out.append(v); out.sort() }
        }
        return out
    }
    private var ceilingSection: some View {
        section("BUILD UP TO") {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                segmented(ceilingChoices, current: targetWeekly.map { Int(($0 / metersPerUnit).rounded()) } ?? 0,
                          label: { $0 == 0 ? "Coach" : "\($0)" }) { v in
                    targetWeekly = v == 0 ? nil : Double(v) * metersPerUnit
                }
                Text(ceilingNote)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var ceilingNote: String {
        if let need = feasibility?.weeklyCapShortfallM {
            let n = Int((need / metersPerUnit).rounded())
            return "Your cap is under this goal's usual \(n) \(unitLabel) a week. We hold at your cap."
        }
        return targetWeekly == nil
            ? "The most you're willing to run in a week (\(unitLabel)). Left to us, the plan builds to what your goal needs."
            : "The plan will not build past this. Every recovery guardrail still applies below it."
    }

    private var daysSection: some View {
        section("DAYS / WEEK") {
            segmented([2, 3, 4, 5, 6], current: days, label: { "\($0)" }) { days = $0 }
        }
    }

    private var sessionSection: some View {
        section("SESSION LENGTH") {
            segmented([30, 45, 60, 75], current: minutes, label: { "\($0)m" }) { minutes = $0 }
        }
    }

    private var equipmentSection: some View {
        let opts: [(Equipment, String, String)] = [
            (.fullGym, "Full gym", "building.2"), (.dumbbellsOnly, "Dumbbells only", "dumbbell"),
            (.homeMinimal, "Home minimal", "house"), (.bodyweight, "Bodyweight", "figure.cooldown")]
        return section("EQUIPMENT") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(opts, id: \.0) { o in
                    SelectionCard(title: o.1, systemImage: o.2, isSelected: equipment == o.0) { equipment = o.0 }
                }
            }
        }
    }

    // MARK: Current-goal coaching context

    @MainActor
    private func refreshStartingPoint() async {
        let now = Date()
        let worker = PlanFitnessWorker(modelContainer: context.container)
        guard let snapshot = try? await worker.snapshot(
            declaredWeeklyM: profile.weeklyRunVolumeM,
            declaredLongestM: profile.longestRunM,
            profileCreatedAt: profile.createdAt,
            endingAt: now
        ), !Task.isCancelled else { return }
        baselineUsesLoggedRuns = snapshot.usesLoggedRuns
        currentWeeklyM = snapshot.weeklyM
        currentLongestM = snapshot.longestM
    }

    private func experienceLabel(for discipline: Discipline) -> String {
        let level = ExperienceLevel(rawValue: profile.experience[discipline.rawValue] ?? "") ?? .some
        return switch level {
        case .new: "New"
        case .some: "Some"
        case .experienced: "Experienced"
        }
    }

    /// Seed the time control with a coherent starting point for the selected distance. This is only
    /// a convenience when the athlete turns the optional target ON; it is never saved until they
    /// commit, and every minute remains editable.
    private func seedGoalTime() {
        guard let distance = raceDistance else { return }
        let seconds: Double
        if let p5k = profile.plan?.p5kSPerKm, p5k > 0 {
            seconds = PlanFeasibility.predictedFinishS(distanceM: distance.meters, p5kSPerKm: p5k)
        } else {
            seconds = switch distance {
            case .fiveK: 30 * 60
            case .tenK: 60 * 60
            case .half: 2 * 3_600
            case .marathon: 4 * 3_600
            case .fiftyK: 5.5 * 3_600
            }
        }
        let totalMinutes = min(9 * 60 + 59, max(1, Int((seconds / 60).rounded())))
        goalHours = totalMinutes / 60
        goalMinutes = totalMinutes % 60
    }

    // MARK: Building blocks

    private var cardBackground: some View {
        ZStack {
            Color.clear.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private func segmented(_ values: [Int], current: Int, label: @escaping (Int) -> String, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(values, id: \.self) { v in
                let on = current == v
                Button { Haptics.selection(); set(v) } label: {
                    Text(label(v))
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                            if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            content()
        }
    }

    private var confirmTitle: String {
        mode == .create ? "Create plan" : (structural ? "Rebuild plan" : "Save")
    }

    private var commitAccessibilityValue: String {
        if goal == nil { return "Choose a goal" }
        if racing && raceDistance == nil { return "Choose a race distance" }
        if racing && hasGoalTime && newGoalFinishTimeS == nil { return "Choose a valid goal time" }
        return mode == .create ? "Ready to create" : "Ready to save"
    }

    private var footerNote: String {
        switch mode {
        case .create:
            return "Creating a new plan replaces your current block from today. Completed workouts, records, and your calibrated pace all carry over."
        case .adjust:
            return structural
                ? "Saving rebuilds your upcoming plan from today. Completed workouts and your calibrated pace are kept."
                : "Nothing structural changed — saving keeps your current plan exactly as it is."
        }
    }

    private func apply() {
        guard let goal, canCommit else { return }
        // Resolve the season/event identity while the current plan is still attached. The command is
        // buffered like the form: cancel never constructs or writes it; Save is the only dual-write
        // path for the legacy goal fields and their running-domain sidecars.
        let configuration: PlanConfigurationCommand
        do {
            configuration = try PlanConfigurationCommand.legacyUICommand(
                id: UUID(),
                profile: profile,
                startsNewSeason: mode == .create,
                planName: name,
                goal: goal,
                raceDate: newRaceDate,
                raceDistanceM: newRaceDistanceM,
                goalFinishTimeS: newGoalFinishTimeS,
                tuneUps: tuneUpsLoaded ? activeTuneUps : nil,
                in: context
            )
            try configuration.preflightValidation()
        } catch {
            saveFailed = true
            return
        }
        // Rename-only edits must NOT rebuild — regenerating the upcoming weeks is for structural
        // changes. A NEW plan always rebuilds: that's the point of beginning again. Autosave stays
        // off until every profile, plan, season, event, metadata, and intent mutation is staged.
        let rebuild = structural || mode == .create
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }
        do {
            profile.goal = goal
            profile.daysPerWeek = days
            profile.sessionMinutes = minutes
            profile.equipment = equipment
            profile.raceDistanceM = newRaceDistanceM
            profile.raceDate = newRaceDate
            profile.goalFinishTimeS = newGoalFinishTimeS
            profile.planIntensity = intensity.rawValue
            profile.targetWeeklyRunVolumeM = targetWeekly
            if hybrid { profile.hybridPriority = hybridPriority.rawValue }
            if lifting { profile.strengthSplit = strengthSplit.rawValue }
            if rebuild {
                // The buffered tune-ups reach the generator directly: the records are written by
                // the command AFTER the rebuild (the season keeps its identity that way), so the
                // engine would otherwise bend the weeks around last time's list.
                let events = activeTuneUps.map {
                    PlanRaceEvent(id: $0.id, date: $0.date, distanceM: $0.distanceM,
                                  priority: $0.priority, goalTimeS: $0.goalTimeS)
                }
                _ = try PlanService.stageRebuild(for: profile, tuneUps: tuneUpsLoaded ? events : nil, in: context)
            }
            _ = try configuration.apply(in: context, now: Date())
            if rebuild {
                _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: context)
            }
            try context.save()
        } catch {
            context.rollback()
            saveFailed = true
            return
        }
        Haptics.success()
        onDone()
    }
}
