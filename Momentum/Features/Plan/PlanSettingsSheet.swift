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
    @State private var goal: Goal
    @State private var raceDistance: RaceDistance?
    @State private var hasRaceDate: Bool
    @State private var raceDate: Date
    @State private var hasGoalTime: Bool
    @State private var goalHours: Int
    @State private var goalMinutes: Int
    @State private var intensity: PlanIntensity
    @State private var hybridPriority: HybridPriority
    @State private var days: Int
    @State private var minutes: Int
    @State private var equipment: Equipment
    @State private var showRacePicker = false
    @State private var saveFailed = false

    init(profile: UserProfile, mode: Mode = .adjust, onDone: @escaping () -> Void) {
        self.profile = profile
        self.mode = mode
        self.onDone = onDone
        // A new plan starts with a blank name (its own occasion); adjusting keeps the current one.
        _name = State(initialValue: mode == .create ? "" : (profile.plan?.name ?? ""))
        _goal = State(initialValue: profile.goal)
        _raceDistance = State(initialValue: profile.raceDistanceM.map(RaceDistance.nearest(toMeters:)))
        _hasRaceDate = State(initialValue: profile.raceDate != nil)
        _raceDate = State(initialValue: profile.raceDate
            ?? Calendar.current.date(byAdding: .weekOfYear, value: 12, to: Date()) ?? Date())
        let goalS = profile.goalFinishTimeS
        _hasGoalTime = State(initialValue: goalS != nil)
        _goalHours = State(initialValue: goalS.map { Int($0) / 3600 } ?? 4)
        _goalMinutes = State(initialValue: goalS.map { (Int($0) % 3600) / 60 } ?? 0)
        _intensity = State(initialValue: profile.planIntensity.flatMap(PlanIntensity.init(rawValue:)) ?? .balanced)
        _hybridPriority = State(initialValue: profile.hybridPriority.flatMap(HybridPriority.init(rawValue:)) ?? .balanced)
        _days = State(initialValue: profile.daysPerWeek)
        _minutes = State(initialValue: profile.sessionMinutes)
        _equipment = State(initialValue: profile.equipment)
    }

    private var lifting: Bool { profile.disciplines.contains(Discipline.strength.rawValue) }
    private var racing: Bool { goal == .raceDistance }
    /// Only athletes who both run AND lift get the balance dial — it's the one control that
    /// splits the training week between the two (the engine reads it only when both are present).
    private var hybrid: Bool {
        profile.disciplines.contains(Discipline.running.rawValue)
            && profile.disciplines.contains(Discipline.strength.rawValue)
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
            || (hybrid && hybridPriority.rawValue != (profile.hybridPriority ?? HybridPriority.balanced.rawValue))
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
        racing && hasGoalTime ? Double(goalHours * 3600 + goalMinutes * 60) : nil
    }

    /// The honest read for the race + date on screen right now — same engine as onboarding.
    private var feasibility: PlanFeasibility? {
        guard racing, let distanceM = newRaceDistanceM, let date = newRaceDate else { return nil }
        let weeks = PlanEngine.weeksToRace(startDate: Date(), raceDate: date, calendar: .current) ?? 0
        let experience = ExperienceLevel(rawValue: profile.experience[Discipline.running.rawValue] ?? "") ?? .some
        return PlanFeasibility.assess(raceDistanceM: distanceM,
                                      goalFinishTimeS: newGoalFinishTimeS,
                                      currentP5kSPerKm: profile.plan?.p5kSPerKm,
                                      currentWeeklyVolumeM: profile.weeklyRunVolumeM ?? 0,
                                      weeksAvailable: weeks,
                                      experience: experience,
                                      injuryProne: !profile.injuryHistory.isEmpty,
                                      daysPerWeek: days)   // the BUFFERED picker value — verdict updates live
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    nameSection
                    goalSection
                    if racing { raceSection }
                    if hybrid { balanceSection }
                    intensitySection
                    daysSection
                    sessionSection
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
                    Button(confirmTitle) { apply() }.fontWeight(.semibold)
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
            .onAppear {
                #if DEBUG
                // --race-picker: open the catalog directly (screenshot verification; sim can't tap).
                if ProcessInfo.processInfo.arguments.contains("--race-picker") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showRacePicker = true }
                }
                #endif
            }
        }
        .presentationBackground(Theme.background)
    }

    // MARK: Sections

    /// Name the block after what it's FOR ("Austin Marathon") — the name becomes the Plan page
    /// title and marks plan sessions wherever they surface.
    private var nameSection: some View {
        section("PLAN NAME") {
            TextField("e.g. Austin Marathon", text: $name)
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .padding(Theme.Space.md)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
        }
    }

    /// Running-first, always — racing leads, strength supports (ENDURANCE-FOCUS §1).
    private var goalSection: some View {
        let goals: [(Goal, String, String)] = [
            (.raceDistance, "Run a race", "flag.checkered"),
            (.endurance, "Run farther & faster", "wind"),
            (.stayConsistent, "Stay consistent", "calendar"),
            (.buildMuscle, "Build muscle", "figure.strengthtraining.traditional"),
            (.getStronger, "Get stronger", "dumbbell.fill"),
            (.loseFat, "Lose fat / get fit", "flame")]
        return section("FOCUS") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(goals, id: \.0) { g in
                    SelectionCard(title: g.1, systemImage: g.2, isSelected: goal == g.0) {
                        withAnimation(Motion.standard) { goal = g.0 }
                    }
                }
            }
        }
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
                .tint(Theme.ink)
                .padding(Theme.Space.md)
                .background(cardBackground)

                if hasRaceDate {
                    DatePicker("Race day", selection: $raceDate,
                               in: Date()..., displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(Theme.ink)
                        .padding(Theme.Space.sm)
                        .background(cardBackground)
                }

                Toggle(isOn: $hasGoalTime.animation(Motion.standard)) {
                    Text("Target finish time")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                .tint(Theme.ink)
                .padding(Theme.Space.md)
                .background(cardBackground)

                if hasGoalTime {
                    HStack(spacing: 0) {
                        Picker("Hours", selection: $goalHours) {
                            ForEach(0..<10, id: \.self) { Text("\($0) hr").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        Picker("Minutes", selection: $goalMinutes) {
                            ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0) min").tag($0) }
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
    private var balanceSection: some View {
        let opts: [(HybridPriority, String, String, String)] = [
            (.running, "Running comes first", "Lift to support the miles", "figure.run"),
            (.balanced, "Balanced", "Both matter, side by side", "figure.run.circle"),
            (.lifting, "Lifting comes first", "Run to stay conditioned", "dumbbell.fill")]
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

    /// How hard to push — the athlete's dial (safety caps from injury history still apply).
    private var intensitySection: some View {
        section("HOW HARD TO PUSH") {
            VStack(spacing: Theme.Space.sm) {
                ForEach([PlanIntensity.gentle, .balanced, .aggressive], id: \.self) { level in
                    SelectionCard(title: level.label, subtitle: level.subtitle,
                                  isSelected: intensity == level) { intensity = level }
                }
            }
        }
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

    // MARK: Building blocks

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
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
        // Rename-only edits must NOT rebuild — regenerating the upcoming weeks is for structural
        // changes. A NEW plan always rebuilds: that's the point of beginning again.
        let rebuild = structural || mode == .create
        profile.goal = goal
        profile.daysPerWeek = days
        profile.sessionMinutes = minutes
        profile.equipment = equipment
        profile.raceDistanceM = newRaceDistanceM
        profile.raceDate = newRaceDate
        profile.goalFinishTimeS = newGoalFinishTimeS
        profile.planIntensity = intensity.rawValue
        if hybrid { profile.hybridPriority = hybridPriority.rawValue }
        if rebuild {
            PlanService.rebuild(for: profile, in: context)   // preserves calibrated pace + cross-training
        }
        profile.plan?.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A structural rebuild that silently fails to persist is the worst kind of ghost — the
        // athlete saw "success", and their plan reverts on next launch. Keep the sheet open.
        do { try context.save() } catch {
            context.rollback()
            saveFailed = true
            return
        }
        Haptics.success()
        onDone()
    }
}
