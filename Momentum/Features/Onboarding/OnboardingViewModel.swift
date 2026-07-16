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
    /// Everything the athlete chose to do (source of truth for the picker).
    var activities: Set<ActivityChoice> = []
    /// Engine-facing disciplines — the programmable subset of the chosen activities.
    var disciplines: Set<Discipline> { Set(activities.compactMap(\.discipline)) }
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
    var birthYear: Int? = nil
    var bodyMassKg: Double? = nil

    // Current running load (meters) — seeds the plan's starting volume so it meets the athlete where
    // they are. nil until the `runVolume` step sets it (shown only to non-beginner runners).
    var weeklyRunVolumeM: Double? = nil
    var longestRunM: Double? = nil

    // Hybrid emphasis (run + lift athletes) — biases the run/lift day split.
    var hybridPriority: HybridPriority = .balanced
    // How hard to push toward the goal (Take your time / Balanced / Aggressive). Pre-set to the honest
    // recommendation when the intensity step appears; the athlete can override.
    var intensity: PlanIntensity = .balanced

    /// The honest read on the athlete's goal vs. the calendar + their current fitness — drives the
    /// intensity step's headline, recommendation, and any "here's the truth" alternatives.
    var feasibility: PlanFeasibility {
        let p5k = calibration.recentRun.map { PlanEngine.riegelP5k(distanceM: $0.distanceM, timeS: $0.timeS) }
            ?? calibration.estimatedP5kSPerKm
        return PlanFeasibility.assess(
            raceDistanceM: goal == .raceDistance ? raceDistance?.meters : nil,
            goalFinishTimeS: goalFinishTimeS,
            currentP5kSPerKm: p5k,
            currentWeeklyVolumeM: weeklyRunVolumeM ?? 0,
            weeksAvailable: hasRace ? (weeksToRace ?? 16) : 999,   // no date → no time pressure
            experience: experience,
            injuryProne: !injuryAreas.isEmpty)
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
    /// Resting HR read from Apple Health at either consent moment (calibration import or the health
    /// step) — persisted at finish so HR zones use Karvonen from the very first plan instead of the
    /// much cruder %-of-max fallback.
    var importedRestingHR: Int?

    /// A catalog race picked on the race step ("Chicago Marathon") — becomes the plan's name at
    /// finish, so the season is branded with its occasion from day one.
    var plannedRaceName: String?

    // Health import (ENDURANCE-FOCUS §4) — the baseline estimated from their recent runs. Set by the
    // calibration step's import card; feeds the pace seed AND the current-volume inputs.
    var importedBaseline: BaselineEstimator.RunningBaseline? {
        didSet {
            guard let b = importedBaseline else { return }
            calibrationMode = .imported
            // Real measured load beats self-report — feeds the plan's starting volume + feasibility.
            weeklyRunVolumeM = b.weeklyVolumeM
            longestRunM = b.longestRunM
        }
    }

    /// A balanced full-body activation for the anatomy animation, emphasized by the chosen focus.
    func targetMuscles() -> [MuscleGroup: Double] {
        let balanced: [MuscleGroup: Double] = [
            .chest: 0.85, .back: 0.85, .shoulders: 0.6, .biceps: 0.5, .triceps: 0.5,
            .quads: 0.9, .hamstrings: 0.7, .glutes: 0.75, .calves: 0.4, .core: 0.6]
        guard !muscleFocus.isEmpty else { return balanced }
        var m = balanced.mapValues { _ in 0.35 }
        for f in muscleFocus { m[f] = 1.0 }
        return m
    }
    /// Whether this athlete's plan includes lifting (drives the anatomy beats vs. the route beat).
    var includesStrength: Bool { disciplines.contains(.strength) }
    /// The body figure to render in the anatomy beats (female warps the silhouette).
    var bodySex: BodySex { BodySex(profileSex: sex?.rawValue) }

    /// A tasteful default bio derived from the goal (the athlete can edit it later).
    var bioForGoal: String {
        switch goal {
        case .raceDistance: return raceDistance.map { "Training for a \($0.label)" } ?? "Chasing a finish line"
        case .buildMuscle: return "Building muscle"
        case .getStronger: return "Getting stronger"
        case .loseFat: return "Getting lean"
        case .endurance: return "Building endurance"
        case .generalFitness, .stayConsistent: return "Keep moving."
        }
    }

    var step: Step = .name

    /// Goal-first, branching order — each user only sees the steps relevant to their goal/disciplines.
    enum Step: Int, CaseIterable {
        // `metrics` (incl. sex) sits before `muscleFocus` so the anatomy figure is the right body
        // everywhere it appears (focus step, building beat, reveal).
        // No cold-open — the welcome page (SignInView) is the brand entry; onboarding opens on the
        // first question. Order flows broad→specific: who → goal → what you do → experience → about you
        // → race specifics → schedule → equipment/focus → motivation → pace → build → reveal → opt-ins.
        // `metrics` (incl. sex) stays before `muscleFocus`/building/reveal so the anatomy figure is the
        // right body everywhere it appears.
        // `identity` (the profile photo — the @handle claim left with the community back-burner,
        // 2026-07-16) follows `name`, both before any training questions.
        case name, identity, goal, disciplines, experience, injuries, metrics, race, raceGoalTime,
             muscleFocus, runVolume, days, preferredDays, session, equipment, hybridFocus, why,
             calibration, health, intensity, building, reveal, notifications, primers
    }

    var lifting: Bool { disciplines.contains(.strength) }
    var running: Bool { disciplines.contains(.running) }
    var hybrid: Bool { running && lifting }

    /// The ordered steps for this user — branches on goal + disciplines.
    var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .race:        return goal == .raceDistance && running
            case .raceGoalTime: return goal == .raceDistance && running
            case .muscleFocus: return goal == .buildMuscle && lifting
            case .equipment:   return lifting
            case .hybridFocus: return hybrid          // run + lift → ask where the emphasis sits
            case .calibration: return running
            // Anything to train around — endurance athletes only (drives the protective ramp).
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
    private var questionSteps: [Step] {
        // `.health` is an opt-in consent beat (like notifications), not an answerable question.
        steps.filter { ![.health, .building, .reveal, .notifications, .primers].contains($0) }
    }
    var isQuestionStep: Bool { questionSteps.contains(step) }

    var progress: Double {
        guard let qIdx = questionSteps.firstIndex(of: step) else {
            return step.rawValue < Step.building.rawValue ? 0 : 1
        }
        return Double(qIdx + 1) / Double(max(1, questionSteps.count))
    }

    var canAdvance: Bool {
        switch step {
        case .identity: return true   // photo-only since the handle left (2026-07-16) — always optional
        // Require at least one PROGRAMMABLE discipline (run/strength/…), not just any activity: extras
        // like yoga/swim/row map to `discipline == nil`, and advancing on those alone made finish()
        // silently inject a running plan the user never asked for. A training plan needs something the
        // engine actually programs; the extras still ride along as cross-training.
        case .disciplines: return !disciplines.isEmpty
        case .race: return raceDistance != nil
        default: return true
        }
    }

    func advance() {
        guard let idx = steps.firstIndex(of: step), idx + 1 < steps.count else { return }
        step = steps[idx + 1]
    }

    func back() {
        guard let idx = steps.firstIndex(of: step), idx > 0 else { return }
        step = steps[idx - 1]
    }

    var calibration: CalibrationSeed {
        var seed = CalibrationSeed()
        switch calibrationMode {
        case .time: seed.recentRun = (benchmark.meters, recentRunSeconds)
        case .feel: if let f = paceFeel { seed.estimatedP5kSPerKm = f.p5kSPerKm }
        case .imported: seed.estimatedP5kSPerKm = importedBaseline?.p5kSPerKm
        case .none: break
        }
        return seed
    }

    /// Personalized status lines for the "building your plan" beat — each reflects an answer back so
    /// the analysis feels bespoke (research: the loader should mirror the user's own inputs).
    func buildingLines() -> [String] {
        var lines = ["Balancing your \(daysPerWeek)-day week"]
        if disciplines.contains(.running) && disciplines.contains(.strength) {
            lines.append("Spacing your runs and lifts")
        } else if disciplines.contains(.strength) {
            lines.append("Sequencing your strength work")
        } else if disciplines.contains(.running) {
            lines.append("Building your running base")
        } else {
            lines.append("Spacing your efforts")
        }
        switch goal {
        case .buildMuscle:   lines.append("Tuning volume for muscle")
        case .getStronger:   lines.append("Loading for strength")
        case .loseFat:       lines.append("Shaping it for fat loss")
        case .raceDistance:  lines.append("Pointing it at your distance")
        case .endurance:     lines.append("Stretching your endurance")
        default:             lines.append("Making it easy to keep")
        }
        lines.append(disciplines.contains(.strength) && !disciplines.contains(.running)
                     ? "Setting your starting loads" : "Setting your starting paces")
        lines.append("Finalizing your plan")
        return lines
    }

    /// Short "tuned to you" reflections shown on the reveal — the inputs the plan was built around.
    func reflections() -> [String] {
        var chips = ["\(daysPerWeek) days / week"]
        if goal == .raceDistance, let r = raceDistance { chips.append(r.label) } else { chips.append(goalLabel) }
        if let g = goalTimeLabel { chips.append("Goal \(g)") }
        if hybrid, hybridPriority != .balanced { chips.append(hybridPriority == .running ? "Run-focused" : "Lift-focused") }
        if !muscleFocus.isEmpty { chips.append("Focus: \(muscleFocus.count) area\(muscleFocus.count == 1 ? "" : "s")") }
        if disciplines.contains(.strength) { chips.append(equipmentLabel) }
        chips.append("\(sessionMinutes) min")
        return chips
    }

    /// The race goal time as "h:mm" (or "mm min"), nil when no target was set.
    var goalTimeLabel: String? {
        guard let t = goalFinishTimeS else { return nil }
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
        return h > 0 ? "\(h):\(String(format: "%02d", m))" : "\(m) min"
    }

    private var goalLabel: String {
        switch goal {
        case .loseFat: "Fat loss"; case .buildMuscle: "Build muscle"; case .getStronger: "Get stronger"
        case .raceDistance: "Race ready"; case .endurance: "Endurance"; default: "Consistency"
        }
    }

    private var equipmentLabel: String {
        switch equipment {
        case .fullGym: "Full gym"; case .dumbbellsOnly: "Dumbbells"; case .homeMinimal: "Home"; case .bodyweight: "Bodyweight"
        }
    }

    /// Projected outcome copy for the reveal (PRD §4.1).
    func projectedOutcome() -> String {
        // Race goals lead with the race itself — the clearest promise, with the goal time when set.
        if goal == .raceDistance, let r = raceDistance {
            let subject = goalTimeLabel.map { "\($0) \(r.label.lowercased())" } ?? "\(r.label)-ready"
            if hasRace { return "\(subject) by \(raceDate.formatted(.dateTime.month().day()))" }
            return goalTimeLabel != nil ? "Chasing a \(subject)" : "Built for your \(r.label) — whenever you toe the line"
        }
        // Running-first phrasing (Phase 0): the runner identity leads; strength reads as the support.
        let phrase: String
        if running && lifting {
            phrase = hasRace ? "Race-ready — and stronger everywhere" : "A faster runner — stronger everywhere"
        } else if running {
            phrase = hasRace ? "Race-ready" : "A faster, stronger runner"
        } else if lifting {
            phrase = goal == .getStronger ? "Stronger" : "Leaner & stronger"
        } else {
            phrase = "Fitter"
        }
        if hasRace { return "\(phrase) by \(raceDate.formatted(.dateTime.month().day()))" }
        return "\(phrase) — one week at a time"
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
        let chosen = disciplines.isEmpty ? [Discipline.running] : Array(disciplines)
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
        profile.raceDate = hasRace ? Calendar.current.startOfDay(for: raceDate) : nil
        profile.raceDistanceM = (goal == .raceDistance) ? raceDistance?.meters : nil
        // Only carried when the runVolume step applies (running, non-beginner); otherwise nil → the
        // engine's experience-tier defaults. Guarded so flipping back to "new" can't leak a seeded value.
        if running, experience != .new {
            profile.weeklyRunVolumeM = weeklyRunVolumeM
            profile.longestRunM = longestRunM
        }
        if hybrid { profile.hybridPriority = hybridPriority.rawValue }
        if running { profile.planIntensity = intensity.rawValue }
        profile.injuryHistory = injuryAreas.map(\.rawValue).sorted()
        if goal == .raceDistance { profile.goalFinishTimeS = goalFinishTimeS }
        profile.muscleFocus = muscleFocus.map(\.rawValue)
        profile.preferredDays = Array(preferredDays).sorted()
        profile.crossTraining = extraActivities.map { $0.workoutType.rawValue }
        // Default display units to the athlete's locale (lb + miles in the US/UK) so the whole app
        // matches the imperial figures they just entered. Distance stays `auto` (locale-resolved).
        profile.weightUnit = WeightUnit.default().rawValue
        profile.sex = sex?.rawValue
        profile.heightCm = heightCm
        profile.birthYear = birthYear
        if let bodyMassKg { profile.bodyMassKg = bodyMassKg }
        // Resting HR from Apple Health (when connected) → Karvonen HR zones from day one.
        if let rhr = importedRestingHR { profile.restingHR = rhr }
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
        if goal == .raceDistance, let raceName = plannedRaceName, profile.plan?.name.isEmpty != false {
            profile.plan?.name = raceName
        }
        // Seed the Athlete Model so the AI isn't starting from a blank slate (ATHLETE-MODEL.md §5).
        AthleteModelService().seedOnboarding(for: profile, in: context)
        return profile
    }
}

// MARK: - Activity picker

/// A choice on the onboarding "what do you want to do?" step. Programmable activities map to a
/// `Discipline` the engine writes structured sessions for; the rest are tracked add-ons the plan
/// includes as simple recurring sessions you can check off.
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
        case .run: .running; case .cycle: .cycling; case .walk: .walking
        case .hike: .walking; case .strength: .strength; case .hiit: .strength
        case .swim, .rowing, .yoga: nil
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
/// `.imported` = estimated from their Apple Health run history (most precise, zero effort).
enum CalibrationMode { case none, feel, time, imported }

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
        case .newRunner: "Walk/jog — just building up"
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
}

/// A known recent effort the athlete can time, for a precise (Riegel) pace seed.
enum RunBenchmark: String, CaseIterable, Identifiable {
    case mile, fiveK, tenK
    var id: String { rawValue }
    var meters: Double { switch self { case .mile: 1_609.344; case .fiveK: 5_000; case .tenK: 10_000 } }
    var label: String { switch self { case .mile: "1 mile"; case .fiveK: "5K"; case .tenK: "10K" } }
    var defaultSeconds: Double { switch self { case .mile: 600; case .fiveK: 1_800; case .tenK: 3_600 } }
    /// Floors sit just under the world records (mile 3:43, 5K ~12:35, 10K ~26:11) so ANY real
    /// athlete — including an elite — can enter their true time; the engine's Daniels/VDOT zones are
    /// curvilinear and handle that fitness correctly. The old floors (5:00 / 15:00 / 30:00) silently
    /// capped a sub-elite's seed and started their whole plan 8–15% too slow.
    var range: ClosedRange<Double> { switch self { case .mile: 210...1_200; case .fiveK: 720...3_600; case .tenK: 1_500...7_200 } }
    var step: Double { switch self { case .mile: 15; case .fiveK: 30; case .tenK: 60 } }
}
