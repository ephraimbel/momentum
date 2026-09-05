import Foundation
import SwiftData
import Observation

/// Holds onboarding answers and turns them into a `UserProfile` + generated plan (PRD §4.1, §26).
@MainActor
@Observable
final class OnboardingViewModel {
    // Answers
    /// What to call the athlete (prefilled from Sign in with Apple; editable). Fills the profile.
    var name: String = ""
    /// The claimed @handle (identity step) — normalized on entry, unique-enforced at claim.
    var handle: String = ""
    /// Optional onboarding avatar (identity step) — already downscaled to ≤512px.
    var avatarData: Data?
    /// Everything the athlete chose to do (source of truth for the picker). Running is the fixed
    /// foundation; the question is what else belongs around it.
    var activities: Set<ActivityChoice> = [.run]
    /// Engine-facing disciplines — the programmable subset of the chosen activities.
    var disciplines: Set<Discipline> { Set(activities.compactMap(\.discipline)).union([.running]) }
    /// Chosen activities the engine can't program yet — added to the plan as tracked sessions.
    var extraActivities: [ActivityChoice] {
        ActivityChoice.allCases.filter { activities.contains($0) && $0.discipline == nil }
    }
    var goal: Goal = .generalFitness
    var experience: ExperienceLevel = .some          // running / general
    /// Past injury areas — the plan starts protective around these (ENDURANCE-FOCUS §8.2). Empty → none.
    var injuryAreas: Set<InjuryArea> = []
    var liftExperience: ExperienceLevel = .some      // used when hybrid (run + lift)
    var daysPerWeek: Int = 3
    var equipment: Equipment = .fullGym
    var sessionMinutes: Int = 45
    var hasRace = false
    var raceDate: Date = Calendar.current.date(byAdding: .weekOfYear, value: 8, to: Date()) ?? Date()
    var reason: String = "health"

    // Deeper tailoring (PRD §26 — goal-branched)
    var raceDistance: RaceDistance? = nil           // for "run a race"
    var muscleFocus: Set<MuscleGroup> = []          // for "build muscle" — areas to emphasize
    var preferredDays: Set<Int> = []                // Calendar weekday 1…7; empty → auto-spread
    var sex: BiologicalSex? = nil
    var heightCm: Double? = nil
    /// Explicit unit choices from the metrics page (owner ask 2026-07-30) — nil = locale default.
    /// Weight choice persists to the profile at finish; height choice is a display preference.
    var weightUnitChoice: String? = nil     // WeightUnit rawValue ("kg" | "lb")
    /// `DistanceUnit` rawValue ("metric" | "imperial"), nil until the athlete answers, at which
    /// point the units step seeds it from their locale. Before this existed the flow read the
    /// locale directly and the athlete could not correct it anywhere in onboarding.
    var distanceUnitChoice: String? = nil
    var heightMetricChoice: Bool? = nil     // true = cm, false = ft·in
    var birthYear: Int? = nil
    var bodyMassKg: Double? = nil

    // Current running load (meters) — seeds the plan's starting volume so it meets the athlete where
    // they are. nil until the `runVolume` step sets it (shown only to non-beginner runners).
    var weeklyRunVolumeM: Double? = nil
    var longestRunM: Double? = nil
    /// The athlete's own weekly-mileage ceiling (meters); nil = "coach's call".
    var targetWeeklyRunVolumeM: Double? = nil

    // Hybrid emphasis (run + lift athletes) — biases the run/lift day split.
    var hybridPriority: HybridPriority = .balanced
    /// The step a saved draft resumed onto, nil for a fresh flow. Lets per-step prefills (the
    /// intensity recommendation) tell "first arrival" from "re-entering a step the athlete already
    /// answered before the interruption" — `touchedSteps` is view @State and doesn't survive.
    var restoredStep: Step?
    /// True when a draft resumed at or past `s` — the athlete already saw and answered it.
    func restoredAtOrPast(_ s: Step) -> Bool {
        guard let restoredStep,
              let restored = steps.firstIndex(of: restoredStep),
              let target = steps.firstIndex(of: s) else { return false }
        return restored >= target
    }
    // How the lifting week composes — coach's pick, full body, upper/lower, or push/pull/legs.
    var strengthSplit: StrengthSplitStyle = .coach
    // How hard to push toward the goal (Take your time / Balanced / Aggressive). Pre-set to the honest
    // recommendation when the intensity step appears; the athlete can override.
    var intensity: PlanIntensity = .balanced

    /// The honest read on the athlete's goal vs. the calendar + their current fitness — drives the
    /// intensity step's headline, recommendation, and any "here's the truth" alternatives.
    /// Memoized on its inputs (perf audit 2026-08-13): the intensity step reads this from `body`,
    /// so every flow-wide invalidation re-ran the full assessment (two engine read passes + string
    /// building) even when nothing it depends on had moved.
    @ObservationIgnored private var feasibilityCache: (key: String, value: PlanFeasibility)?
    var feasibility: PlanFeasibility {
        let key = [String(describing: calibration), String(describing: goal),
                   String(describing: raceDistance), "\(goalHours):\(goalMinutes)",
                   "\(weeklyRunVolumeM ?? -1)", "\(targetWeeklyRunVolumeM ?? -1)", "\(hasRace):\(weeksToRace ?? -1)",
                   String(describing: experience), "\(injuryAreas.count)",
                   "\(plannedRunDays)", String(describing: intensity)].joined(separator: "|")
        if let c = feasibilityCache, c.key == key { return c.value }
        let value = computeFeasibility()
        feasibilityCache = (key, value)
        return value
    }

    private func computeFeasibility() -> PlanFeasibility {
        let p5k = calibration.recentRun.map { PlanEngine.riegelP5k(distanceM: $0.distanceM, timeS: $0.timeS) }
            ?? calibration.estimatedP5kSPerKm
        // If they gave a time AT the race distance (a marathoner's own marathon, say), that's the
        // honest "now" — passing it lets feasibility skip the lossy 5K round-trip that would
        // over-tax their fitness and make a real PR look unreachable.
        let raceTimeS: Double? = {
            guard goal == .raceDistance, let rd = raceDistance, let rr = calibration.recentRun,
                  abs(rr.distanceM - rd.meters) < 100 else { return nil }
            return rr.timeS
        }()
        return PlanFeasibility.assess(
            raceDistanceM: goal == .raceDistance ? raceDistance?.meters : nil,
            goalFinishTimeS: goalFinishTimeS,
            currentP5kSPerKm: p5k,
            currentWeeklyVolumeM: weeklyRunVolumeM ?? 0,
            weeksAvailable: hasRace ? (weeksToRace ?? 16) : 999,   // no date → no time pressure
            experience: experience,
            injuryProne: !injuryAreas.isEmpty,
            daysPerWeek: plannedRunDays,
            intensity: intensity,   // the banner reacts to how hard they choose to push
            currentRaceTimeS: raceTimeS,
            targetWeeklyVolumeM: targetWeeklyRunVolumeM)
    }
    // Race goal finish time (race goals) — held as h/m for the picker; 0/0 → no target.
    var goalHours = 0
    var goalMinutes = 0
    var goalFinishTimeS: Double? { (goalHours == 0 && goalMinutes == 0) ? nil : Double(goalHours * 3600 + goalMinutes * 60) }

    // Calibration — how we seed running paces (works for total beginners, not just 5K racers)
    var calibrationMode: CalibrationMode = .none
    var paceFeel: PaceFeel? = nil
    var benchmark: RunBenchmark = .fiveK
    var recentRunSeconds: Double = 1800     // time for the chosen benchmark
    /// Resting HR read from Apple Health at the `health` step's consent moment — persisted at finish
    /// so HR zones use Karvonen from the very first plan instead of the much cruder %-of-max fallback.
    var healthRestingHR: Int?

    /// A catalog race picked on the race step ("Chicago Marathon") — becomes the plan's name at
    /// finish, so the season is branded with its occasion from day one.
    var plannedRaceName: String?

    // Health-derived pace estimation was removed from onboarding (2026-07-24): a baseline inferred
    // from mixed Health run history was too unreliable to seed a plan's paces. Athletes now enter
    // their fitness directly — by feel or a recent time (experience step) and their weekly volume
    // (runVolume step). Nor does anything backfill: since `d419f0f` (2026-08-15) Health creates no
    // `Workout` rows at all, so the training log begins empty and fills only from what the athlete
    // records in the app.

    /// The anatomy the muscle-focus step lights: EXACTLY the chosen areas, full-burn. Empty until
    /// the athlete picks — the figure starts as a quiet chart and each tap ignites its region
    /// (user call 2026-08-05: no pre-filled body; selection IS the light).
    func targetMuscles() -> [MuscleGroup: Double] {
        Dictionary(uniqueKeysWithValues: muscleFocus.map { ($0, 1.0) })
    }
    /// Whether this athlete's plan includes lifting (drives the anatomy beats vs. the route beat).
    var includesStrength: Bool { disciplines.contains(.strength) }
    /// The body figure to render in the anatomy beats (female warps the silhouette).
    var bodySex: BodySex { BodySex(profileSex: sex?.rawValue) }

    /// A tasteful default bio derived from the goal (the athlete can edit it later).
    var bioForGoal: String {
        switch goal {
        case .raceDistance: return raceDistance.map { "Training for a \($0.label)" } ?? "Chasing a finish line"
        case .buildMuscle: return "Building muscle for stronger running"
        case .getStronger: return "Becoming a stronger runner"
        case .loseFat: return "Running fitter, one week at a time"
        case .endurance: return "Building endurance"
        case .generalFitness, .stayConsistent: return "Keep moving."
        }
    }

    var step: Step = .name

    /// Profile first, then a branching interview relevant to the athlete's goal and disciplines.
    enum Step: Int, CaseIterable {
        // Raw values are historical analytics IDs. Retired standalone pages remain decodable
        // for draft migration; `computeSteps` owns the live order, never this declaration.
        // Profile → goal → starting point → training week → approach → reveal → checkout → account.
        case name, identity, goal, disciplines, units, experience, injuries, metrics, race, raceGoalTime,
             muscleFocus, runVolume, days, preferredDays, session, equipment, strengthSplit,
             hybridFocus, why,
             health, intensity, building, reveal, notifications, primers, account
    }

    var lifting: Bool { disciplines.contains(.strength) }
    var running: Bool { disciplines.contains(.running) }
    var hybrid: Bool { running && lifting }

    /// How many of the chosen days will actually be RUNS — the number every running verdict has
    /// to be read against (2026-08-30). A hybrid athlete's week splits between the two
    /// disciplines, so a five-day balanced athlete gets three runs; telling them a half-marathon
    /// build wants four days and then calling five days enough was the flow agreeing with itself
    /// while the plan did something else. One definition, in `PlanEngine.hybridSplit`.
    var plannedRunDays: Int {
        guard running else { return 0 }
        guard lifting else { return daysPerWeek }
        return PlanEngine.hybridSplit(days: daysPerWeek, priority: hybridPriority, goal: goal,
                                      raceDistanceM: (goal == .raceDistance && hasRace) ? raceDistance?.meters : nil).runDays
    }

    /// Cache for `steps`/`questionSteps` (perf audit 2026-08-13): the flow's chrome reads these
    /// ~8× per body pass (every keystroke in the name field re-filters `Step.allCases` repeatedly).
    /// Keyed on the only answers that branch the list; `@ObservationIgnored` so the cache itself
    /// never participates in invalidation.
    @ObservationIgnored private var stepsCache: (key: String, steps: [Step], questions: [Step])?
    private var stepsBranchKey: String {
        "\(String(describing: goal))|\(String(describing: disciplines))|\(String(describing: experience))"
    }
    private var cachedStepLists: (steps: [Step], questions: [Step]) {
        let key = stepsBranchKey
        if let c = stepsCache, c.key == key { return (c.steps, c.questions) }
        let all = computeSteps()
        let questions = all.filter {
            ![.health, .building, .reveal, .notifications, .primers, .account].contains($0)
        }
        stepsCache = (key, all, questions)
        return (all, questions)
    }

    /// The ordered steps for this user — branches on goal + disciplines.
    var steps: [Step] { cachedStepLists.steps }

    private func computeSteps() -> [Step] {
        // Stable enum values preserve analytics and old drafts. Related inputs now share a page:
        // name and username first, distance units in the header, race time with race setup, preferred
        // days with frequency, and lifting split with equipment. Profile styling stays in Profile.
        let ordered: [Step] = [
            .name, .goal, .disciplines, .race, .experience, .runVolume, .injuries, .metrics,
            .muscleFocus, .days, .session, .equipment, .hybridFocus, .health, .intensity,
            .notifications, .primers, .building, .reveal, .account,
        ]
        return ordered.filter { step in
            switch step {
            case .race:        return goal == .raceDistance && running
            case .raceGoalTime: return goal == .raceDistance && running
            case .muscleFocus: return goal == .buildMuscle && lifting
            case .equipment:   return lifting
            // Session length shapes every discipline now, so everyone is asked (2026-08-30).
            // It was hidden from pure runners on the grounds that it only set how many exercises
            // fit in a lifting day — but since the 2026-08-29 audit running honours it too
            // (`PlanEngine.cardioSessions` caps a midweek session at the stated time), which
            // meant a runner's plan was quietly shaped by an answer they were never allowed to
            // give: the untouched 45-minute default. A coach asks how long you have.
            case .session:     return true
            // How to split the lifting week — only meaningful to athletes who lift (2026-08-20).
            case .strengthSplit: return lifting
            case .hybridFocus: return hybrid          // run + lift → ask where the emphasis sits
            // Anything to train around — a conservative history modifier, never a diagnosis.
            case .injuries:    return running
            // The recovery-tracking consent beat (HealthKit) — shown to everyone; wearables sync there.
            case .health:      return true
            // How hard to push — a running decision (endurance focus); paired with the honesty check.
            case .intensity:   return running
            // Current mileage only makes sense once you have some — beginners keep the gentle default.
            case .runVolume:   return running && experience != .new
            default:           return true
            }
        }
    }

    /// The answerable steps (drives the progress bar + the question chrome).
    /// `.health` is an opt-in consent beat (like notifications), not an answerable question.
    /// `.account` isn't either — it may not add a phantom notch to the progress
    /// bar (which would then never reach 100% on the last question). The filter lives in
    /// `cachedStepLists` alongside `steps`.
    private var questionSteps: [Step] { cachedStepLists.questions }
    var isQuestionStep: Bool { questionSteps.contains(step) }

    var progress: Double {
        guard let qIdx = questionSteps.firstIndex(of: step) else {
            guard let index = steps.firstIndex(of: step) else { return 0 }
            return Double(steps.prefix(index).filter { questionSteps.contains($0) }.count)
                / Double(max(1, questionSteps.count))
        }
        return Double(qIdx + 1) / Double(max(1, questionSteps.count))
    }

    /// A quiet chapter label makes the shorter interview read as one continuous conversation.
    var chapterTitle: String {
        switch step {
        case .goal, .disciplines, .units, .race, .raceGoalTime: "YOUR GOAL"
        case .name, .identity: "YOUR PROFILE"
        case .experience, .runVolume, .injuries, .metrics, .muscleFocus: "YOUR STARTING POINT"
        case .days, .preferredDays, .session, .equipment, .strengthSplit, .hybridFocus: "YOUR TRAINING WEEK"
        default: "YOUR APPROACH"
        }
    }

    /// Relocate removed pages without changing or discarding the athlete's saved answers.
    static func currentStep(for saved: Step) -> Step {
        switch saved {
        case .identity: .name
        case .units: .disciplines
        case .raceGoalTime: .race
        case .preferredDays: .days
        case .strengthSplit: .equipment
        case .why: .health
        default: saved
        }
    }

    var canAdvance: Bool {
        switch step {
        case .name:
            let username = SocialPrivacy.normalizedHandle(handle)
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !username.isEmpty && !SocialPrivacy.isReservedHandle(username)
        // Handle, photo and avatar look are all optional here — the handle is seeded from the name,
        // and the database's unique index is the real arbiter at claim time, not this gate.
        case .identity: return true
        // Running is the non-optional foundation; this step only asks what belongs around it.
        case .disciplines: return true
        case .race: return raceDistance != nil
        // The goal shapes everything after it, and `.generalFitness` has NO card on the goal
        // screen: it is the untouched default, so advancing on it meant a plan built for a goal
        // the athlete never saw, let alone chose (found in the 2026-08-28 bug sweep — the screen
        // showed no selection with Continue enabled).
        case .goal: return goal != .generalFitness
        case .experience: return calibrationMode == .time || (calibrationMode == .feel && paceFeel != nil)
        default: return true
        }
    }

    /// Keep an untouched suggested username in step with the name; preserve a deliberate edit.
    func suggestHandle(afterEditing previousName: String) {
        let oldSuggestion = SocialPrivacy.normalizedHandle(HandleSuggester.baseHandle(name: previousName, email: nil))
        guard handle.isEmpty || handle == oldSuggestion else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            handle = ""
            return
        }
        handle = SocialPrivacy.normalizedHandle(HandleSuggester.baseHandle(name: name, email: nil))
    }

    func advance() {
        guard let idx = steps.firstIndex(of: step), idx + 1 < steps.count else { return }
        step = steps[idx + 1]
    }

    /// Whether there's a previous step to return to. The header hides its back chevron on the first
    /// step rather than showing a control whose tap does nothing.
    var canGoBack: Bool { (steps.firstIndex(of: step) ?? 0) > 0 }

    func back() {
        guard let idx = steps.firstIndex(of: step), idx > 0 else { return }
        step = steps[idx - 1]
    }

    var calibration: CalibrationSeed {
        var seed = CalibrationSeed()
        switch calibrationMode {
        case .time: seed.recentRun = (benchmark.meters, recentRunSeconds)
        case .feel: if let f = paceFeel { seed.estimatedP5kSPerKm = f.p5kSPerKm }
        case .none: break
        }
        return seed
    }

    /// Personalized status lines for the "building your plan" beat — each reflects an answer back so
    /// the analysis feels bespoke (research: the loader should mirror the user's own inputs).
    func buildingLines() -> [String] {
        var lines = ["Balancing your \(daysPerWeek)-day week"]
        if disciplines.contains(.strength) {
            lines.append("Spacing your runs and lifts")
        } else {
            lines.append("Building your running base")
        }
        switch goal {
        case .buildMuscle:   lines.append("Building muscle around your miles")
        case .getStronger:   lines.append("Loading strength for running durability")
        case .loseFat:       lines.append("Supporting body composition")
        case .raceDistance:  lines.append("Pointing it at your distance")
        case .endurance:     lines.append("Stretching your endurance")
        default:             lines.append("Making it easy to keep")
        }
        lines.append("Setting your starting paces")
        lines.append("Finalizing your plan")
        return lines
    }

    /// Short "tuned to you" reflections shown on the reveal — the inputs the plan was built around.
    func reflections() -> [String] {
        var chips = ["\(daysPerWeek) days / week"]
        if goal == .raceDistance, let r = raceDistance { chips.append(r.label) } else { chips.append(goalLabel) }
        if let g = goalTimeLabel { chips.append("Goal \(g)") }
        if hybrid, hybridPriority != .balanced {
            chips.append(hybridPriority == .running ? "Run-focused" : "More strength support")
        }
        if goal == .buildMuscle, !muscleFocus.isEmpty { chips.append("Focus: \(muscleFocus.count) area\(muscleFocus.count == 1 ? "" : "s")") }
        if disciplines.contains(.strength) {
            chips.append(equipmentLabel)
            // Session length only shapes strength days; pure runners were never asked, so the
            // default "45 min" read as an answer they didn't give.
            chips.append("\(sessionMinutes) min")
        }
        return chips
    }

    /// The race goal time as "h:mm" (or "mm min"), nil when no target was set.
    var goalTimeLabel: String? {
        guard let t = goalFinishTimeS else { return nil }
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
        return h > 0 ? "\(h):\(String(format: "%02d", m))" : "\(m) min"
    }

    private var goalLabel: String {
        goal.planLabel
    }

    private var equipmentLabel: String {
        switch equipment {
        case .fullGym: "Full gym"; case .dumbbellsOnly: "Dumbbells"; case .homeMinimal: "Home"; case .bodyweight: "Bodyweight"
        }
    }

    /// Projected outcome copy for the reveal (PRD §4.1).
    func projectedOutcome() -> String {
        // Race goals lead with the athlete's exact target, framed as a pursuit rather than a
        // guaranteed outcome. The feasibility verdict owns what the current runway supports.
        if goal == .raceDistance, let r = raceDistance {
            if hasRace {
                let date = raceDate.formatted(.dateTime.month().day())
                if let goalTimeLabel { return "Chasing \(goalTimeLabel) for your \(r.label) on \(date)" }
                return "Building toward your \(r.label) on \(date)"
            }
            if let goalTimeLabel { return "Chasing \(goalTimeLabel) for your \(r.label)" }
            return "Building toward your \(r.label), one week at a time"
        }
        // Every other goal still resolves through the running promise: the athlete's chosen outcome
        // changes what the miles and supporting strength are trying to accomplish.
        let phrase: String
        switch goal {
        case .endurance:
            phrase = running && lifting ? "Farther and stronger everywhere" : "Going farther, running stronger"
        case .loseFat:        phrase = "Fitter, leaner, running stronger"
        case .buildMuscle:    phrase = "More muscle, stronger running"
        case .getStronger:    phrase = "A stronger, more durable runner"
        case .stayConsistent: phrase = "A running habit that lasts"
        case .generalFitness:
            phrase = "A fitter, stronger runner"
        case .raceDistance:   phrase = "Building toward race day"   // handled above; exhaustive fallback
        }
        if hasRace { return "\(phrase) by \(raceDate.formatted(.dateTime.month().day()))" }
        return "\(phrase), one week at a time"
    }

    /// Whole weeks until race day (for the reveal countdown), if a dated race was set. Delegates to
    /// the canonical `PlanEngine.weeksToRace` (inclusive of race week) so the feasibility verdict here
    /// matches Plan Settings for the same race + date — they used to differ by one week.
    var weeksToRace: Int? {
        guard goal == .raceDistance, hasRace else { return nil }
        return PlanEngine.weeksToRace(startDate: Date(), raceDate: raceDate, calendar: .current)
    }

    /// Create the profile + plan. Returns the persisted profile.
    @discardableResult
    func finish(in context: ModelContext) -> UserProfile {
        let profile = UserProfile()
        let chosen = Array(disciplines)
        // Identity from onboarding fills the profile (no more blank "Athlete").
        profile.displayName = name.trimmingCharacters(in: .whitespaces)
        profile.handle = SocialPrivacy.normalizedHandle(handle)
        if let avatarData { profile.avatarData = avatarData }
        if profile.bio.isEmpty { profile.bio = bioForGoal }
        profile.disciplines = chosen.map(\.rawValue)
        profile.goal = goal
        // Per-discipline experience: lifting uses its own level when hybrid; everything else the general one.
        profile.experience = Dictionary(uniqueKeysWithValues: chosen.map {
            ($0.rawValue, ($0 == .strength ? liftExperience : experience).rawValue)
        })
        profile.daysPerWeek = daysPerWeek
        profile.equipment = equipment
        profile.sessionMinutes = sessionMinutes
        // Day-granular (races have a DAY, not a time) — a time component here made Plan Settings'
        // structural comparison read an untouched sheet as changed.
        // Guard on the GOAL, not just `hasRace`. Picking a race and then switching the goal away
        // (Run a race → Lose fat) used to leave `raceDate` set — the sibling fields below all guard
        // on `goal == .raceDistance`, so the engine periodized the whole block toward a phantom race
        // and the reveal promised "race-ready by <date>" for a goal that isn't racing.
        // …and on `running` too: the goal step precedes disciplines, so "Run a race" with running
        // deselected afterwards is reachable — the race steps are gated on BOTH (see `computeSteps`),
        // and the writes must match or a lift-only athlete ships phantom race periodization.
        let racing = goal == .raceDistance && running
        profile.raceDate = (racing && hasRace) ? Calendar.current.startOfDay(for: raceDate) : nil
        profile.raceDistanceM = racing ? raceDistance?.meters : nil
        // Only carried when the runVolume step applies (running, non-beginner); otherwise nil → the
        // engine's experience-tier defaults. Guarded so flipping back to "new" can't leak a seeded value.
        if running, experience != .new {
            profile.weeklyRunVolumeM = weeklyRunVolumeM
            profile.longestRunM = longestRunM
            profile.targetWeeklyRunVolumeM = targetWeeklyRunVolumeM
        }
        if hybrid { profile.hybridPriority = hybridPriority.rawValue }
        if lifting { profile.strengthSplit = strengthSplit.rawValue }
        if running { profile.planIntensity = intensity.rawValue }
        profile.injuryHistory = injuryAreas.map(\.rawValue).sorted()
        if racing { profile.goalFinishTimeS = goalFinishTimeS }
        // Same stale-answer guard as the race fields: the muscle-focus step only shows for
        // build-muscle lifters, so picks made under an abandoned goal must not leak into the plan.
        profile.muscleFocus = (goal == .buildMuscle && lifting) ? muscleFocus.map(\.rawValue) : []
        profile.preferredDays = Array(preferredDays).sorted()
        profile.crossTraining = extraActivities.map { $0.workoutType.rawValue }
        // Display units: the athlete's explicit choice from the metrics page wins; otherwise the
        // locale default (lb + miles in the US/UK) so the app matches the figures they entered.
        // Distance stays `auto` (locale-resolved).
        profile.weightUnit = weightUnitChoice ?? WeightUnit.default().rawValue
        // Onboarding never wrote this: the profile kept "auto" and re-derived from the locale on
        // every read, so a choice made in the flow was silently dropped at the door.
        profile.distanceUnit = distanceUnitChoice ?? DistanceUnit.auto.resolved().rawValue
        profile.sex = sex?.rawValue
        profile.heightCm = heightCm
        profile.birthYear = birthYear
        if let bodyMassKg { profile.bodyMassKg = bodyMassKg }
        // Resting HR from Apple Health (when connected) → Karvonen HR zones from day one.
        if let rhr = healthRestingHR { profile.restingHR = rhr }
        // Estimate max HR from age (Tanaka) when we have it and nothing better.
        if profile.maxHR == nil, let year = birthYear {
            let age = Calendar.current.component(.year, from: Date()) - year
            if age > 0 { profile.maxHR = Int((208 - 0.7 * Double(age)).rounded()) }
        }
        profile.reason = reason
        context.insert(profile)
        // Build the plan (shared day budget + cross-training) — same path as the edit-settings rebuild.
        PlanService.rebuild(for: profile, calibration: calibration, in: context)
        // A catalog race picked during onboarding names the season after its occasion.
        if racing, let raceName = plannedRaceName, profile.plan?.name.isEmpty != false {
            profile.plan?.name = raceName
        }
        // Seed the Athlete Model so the AI isn't starting from a blank slate (ATHLETE-MODEL.md §5).
        AthleteModelService().seedOnboarding(for: profile, in: context)
        return profile
    }
}

// MARK: - Activity picker

/// A choice on the onboarding training-mix step. Running is the plan foundation and strength is the
/// programmable supporting pillar; the other sports remain trackable cross-training.
enum ActivityChoice: String, CaseIterable, Identifiable {
    case run, cycle, walk, hike, strength, hiit, swim, rowing, yoga
    var id: String { rawValue }

    var title: String {
        switch self {
        case .run: "Run"; case .cycle: "Cycle"; case .walk: "Walk"; case .hike: "Hike"
        case .strength: "Lift weights"; case .hiit: "HIIT"; case .swim: "Swim"
        case .rowing: "Row"; case .yoga: "Yoga"
        }
    }
    var icon: String {
        switch self {
        case .run: "figure.run"; case .cycle: "bicycle"; case .walk: "figure.walk"; case .hike: "figure.hiking"
        case .strength: "dumbbell.fill"; case .hiit: "figure.highintensity.intervaltraining"
        case .swim: "figure.pool.swim"; case .rowing: "figure.rower"; case .yoga: "figure.yoga"
        }
    }
    /// The engine discipline this maps to when programmable; nil → a tracked add-on.
    var discipline: Discipline? {
        switch self {
        case .run: .running
        case .strength, .hiit: .strength
        case .cycle, .walk, .hike, .swim, .rowing, .yoga: nil
        }
    }
    /// The concrete workout type for a tracked add-on session.
    var workoutType: WorkoutType {
        switch self {
        case .run: .run; case .cycle: .ride; case .walk: .walk; case .hike: .hike
        case .strength: .strength; case .hiit: .hiit; case .swim: .swimming
        case .rowing: .rowing; case .yoga: .yoga
        }
    }
    var isProgrammed: Bool { discipline != nil }
}

// MARK: - Calibration model

/// How running paces get seeded in onboarding. `.none` = skipped (use experience default);
/// `.feel` = the by-feel self-assessment; `.time` = a manually entered recent race/benchmark time.
/// (Health-derived estimation was removed 2026-07-24 — too unreliable to seed paces from.)
/// String-raw so it serializes into the interruption-recovery draft like every other answer.
enum CalibrationMode: String { case none, feel, time }

/// A beginner-friendly "by feel" running self-assessment → an estimated 5k pace (s/km). Lets someone
/// who has never timed a run still give the plan a sensible starting pace.
enum PaceFeel: String, CaseIterable, Identifiable {
    case newRunner, easyJogger, regular, fast
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newRunner: "New to running"; case .easyJogger: "Easy jogger"
        case .regular: "Regular runner"; case .fast: "Fast / competitive"
        }
    }
    var subtitle: String {
        switch self {
        case .newRunner: "Walk/jog, just building up"
        case .easyJogger: "I can hold a conversation"
        case .regular: "Comfortable steady miles"
        case .fast: "I train and race hard"
        }
    }
    var icon: String {
        switch self {
        case .newRunner: "figure.walk"; case .easyJogger: "figure.run"
        case .regular: "figure.run.circle"; case .fast: "hare.fill"
        }
    }
    /// Estimated 5k pace in seconds per km (feeds `PlanEngine` pace offsets).
    var p5kSPerKm: Double {
        switch self { case .newRunner: 420; case .easyJogger: 360; case .regular: 315; case .fast: 270 }
    }
    /// The experience tier this running level implies — so a runner answers "how do you run" ONCE
    /// and it seeds both the starting pace AND the plan's experience tier, instead of a separate,
    /// redundant "how experienced are you?" page (2026-07-24).
    var experienceLevel: ExperienceLevel {
        switch self {
        case .newRunner: .new
        case .easyJogger, .regular: .some
        case .fast: .experienced
        }
    }
}

/// A known recent effort the athlete can time, for a precise (Riegel) pace seed.
enum RunBenchmark: String, CaseIterable, Identifiable {
    case mile, fiveK, tenK, half, marathon
    var id: String { rawValue }
    var meters: Double {
        switch self {
        case .mile: 1_609.344; case .fiveK: 5_000; case .tenK: 10_000
        case .half: 21_097.5; case .marathon: 42_195
        }
    }
    var label: String {
        switch self {
        case .mile: "1 mile"; case .fiveK: "5K"; case .tenK: "10K"
        case .half: "Half"; case .marathon: "Marathon"
        }
    }
    var defaultSeconds: Double {
        switch self {
        case .mile: 600; case .fiveK: 1_800; case .tenK: 3_600
        case .half: 7_200; case .marathon: 14_400
        }
    }
    /// Floors sit just under the world records (mile 3:43, 5K ~12:35, 10K ~26:11, half ~57:31,
    /// marathon ~2:00:35) so ANY real athlete — including an elite — can enter their true time; the
    /// engine's Daniels/VDOT zones are curvilinear and handle that fitness correctly. The old floors
    /// (5:00 / 15:00 / 30:00) silently capped a sub-elite's seed and started their whole plan 8–15%
    /// too slow. Half/marathon added 2026-07-24: a marathoner's own race is the truest seed for a
    /// long-distance plan — a Riegel projection from their 5K systematically flatters marathon
    /// fitness (speed ≠ endurance), so letting them give the real number calibrates the whole
    /// block honestly.
    var range: ClosedRange<Double> {
        switch self {
        case .mile: 210...1_200; case .fiveK: 720...3_600; case .tenK: 1_500...7_200
        case .half: 3_300...12_600; case .marathon: 7_080...25_200
        }
    }
    var step: Double {
        switch self {
        case .mile: 15; case .fiveK: 30; case .tenK: 60; case .half: 60; case .marathon: 120
        }
    }
}
