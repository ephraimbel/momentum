import Foundation

/// A serialized snapshot of in-progress onboarding — every answer plus the current step — so a
/// flow interrupted mid-way (backgrounded and evicted by iOS, an incoming call, a crash) resumes
/// exactly where the athlete left off instead of restarting from the first question. Written on
/// each step change and whenever the app leaves the foreground; cleared the instant the profile is
/// created (onboarding done) or the athlete signs out (so a draft never leaks across accounts).
///
/// Enum answers are stored by rawValue, never as the enum types, so the draft is resilient to the
/// onboarding model evolving: a renamed or removed case (like `CalibrationMode.imported`, removed
/// 2026-07-24) falls back to its default on restore rather than failing the whole decode and
/// wiping every answer. Every field is best-effort — an unreadable draft is simply discarded.
///
/// Deliberately excluded: the optional profile photo. It's re-addable, changes rarely, and
/// base64-inflating an image into UserDefaults on every step would be wasteful for a decorative
/// field that doesn't shape the plan.
struct OnboardingDraft: Codable {
    var version = 1
    /// The current step, stored by its CASE NAME (not the Int rawValue) so reordering the flow in a
    /// future build can't resume someone onto the wrong screen — an unrecognized name is discarded.
    var savedStep: String

    var name = ""
    var handle = ""
    var activities: [String] = []
    var goal: String?
    var experience: String?
    var liftExperience: String?
    var injuryAreas: [String] = []
    var daysPerWeek: Int?
    var equipment: String?
    var sessionMinutes: Int?
    var hasRace = false
    var raceDate: Date?
    var reason = "health"
    var raceDistance: String?
    var muscleFocus: [String] = []
    var preferredDays: [Int] = []
    var hybridPriority: String?
    var strengthSplit: String?
    var intensity: String?
    var goalHours = 0
    var goalMinutes = 0
    var sex: String?
    var heightCm: Double?
    var weightUnitChoice: String?
    var distanceUnitChoice: String?
    var heightMetricChoice: Bool?
    var birthYear: Int?
    var bodyMassKg: Double?
    var weeklyRunVolumeM: Double?
    var longestRunM: Double?
    var targetWeeklyRunVolumeM: Double?
    var calibrationMode: String?
    var paceFeel: String?
    var benchmark: String?
    var recentRunSeconds: Double?
    /// Legacy JSON key retained for v1 draft compatibility. This is a current Health signal, not an
    /// imported workout or workout-history value.
    var importedRestingHR: Int?
    var plannedRaceName: String?
}

/// Persists the onboarding draft to `UserDefaults` (JSON). Small (< 2 KB) and written a handful of
/// times per flow, so the store is trivially cheap; a corrupt or version-incompatible payload
/// decodes to nil and is treated as "no draft".
enum OnboardingDraftStore {
    private static let key = "onboarding.draft.v1"

    static func save(_ draft: OnboardingDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    static func load() -> OnboardingDraft? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(OnboardingDraft.self, from: data)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

extension OnboardingViewModel {

    /// Snapshot every stored answer + the current step for interruption recovery.
    func draft() -> OnboardingDraft {
        OnboardingDraft(
            savedStep: String(describing: step),
            name: name,
            handle: handle,
            activities: activities.map(\.rawValue),
            goal: goal.rawValue,
            experience: experience.rawValue,
            liftExperience: liftExperience.rawValue,
            injuryAreas: injuryAreas.map(\.rawValue),
            daysPerWeek: daysPerWeek,
            equipment: equipment.rawValue,
            sessionMinutes: sessionMinutes,
            hasRace: hasRace,
            raceDate: raceDate,
            reason: reason,
            raceDistance: raceDistance?.rawValue,
            muscleFocus: muscleFocus.map(\.rawValue),
            preferredDays: Array(preferredDays),
            hybridPriority: hybridPriority.rawValue,
            strengthSplit: strengthSplit.rawValue,
            intensity: intensity.rawValue,
            goalHours: goalHours,
            goalMinutes: goalMinutes,
            sex: sex?.rawValue,
            heightCm: heightCm,
            weightUnitChoice: weightUnitChoice,
            distanceUnitChoice: distanceUnitChoice,
            heightMetricChoice: heightMetricChoice,
            birthYear: birthYear,
            bodyMassKg: bodyMassKg,
            weeklyRunVolumeM: weeklyRunVolumeM,
            longestRunM: longestRunM,
            targetWeeklyRunVolumeM: targetWeeklyRunVolumeM,
            calibrationMode: calibrationMode.rawValue,
            paceFeel: paceFeel?.rawValue,
            benchmark: benchmark.rawValue,
            recentRunSeconds: recentRunSeconds,
            importedRestingHR: healthRestingHR,
            plannedRaceName: plannedRaceName)
    }

    /// Rehydrate from a draft. Returns false — and mutates nothing that matters — when the saved
    /// step can't be placed (an incompatible/older draft), so the caller discards it and starts
    /// clean rather than resuming someone into a half-valid flow. Unknown enum rawValues fall back
    /// to the field's default (non-optional) or nil (optional).
    @discardableResult
    func restore(from d: OnboardingDraft) -> Bool {
        guard let placedStep = Step.allCases.first(where: { String(describing: $0) == d.savedStep }) else { return false }
        // Never resume onto an output beat. Those drafts describe an onboarding whose plan
        // generation already ran (or should have), and restoring there with no profile strands
        // the athlete on a screen that cannot create one — the infinite "Save your progress"
        // loop after Delete-all-data (audit 2026-08-11). This is an explicit set, not an
        // `allCases` position check: the stable enum order intentionally differs from the live
        // flow order, where Notifications and Primers now come BEFORE Building.
        if [Step.building, .reveal, .account].contains(placedStep) { return false }
        name = d.name
        handle = d.handle
        activities = Set(d.activities.compactMap(ActivityChoice.init(rawValue:))).union([.run])
        goal = d.goal.flatMap(Goal.init(rawValue:)) ?? goal
        experience = d.experience.flatMap(ExperienceLevel.init(rawValue:)) ?? experience
        liftExperience = d.liftExperience.flatMap(ExperienceLevel.init(rawValue:)) ?? liftExperience
        injuryAreas = Set(d.injuryAreas.compactMap(InjuryArea.init(rawValue:)))
        daysPerWeek = d.daysPerWeek ?? daysPerWeek
        equipment = d.equipment.flatMap(Equipment.init(rawValue:)) ?? equipment
        sessionMinutes = d.sessionMinutes ?? sessionMinutes
        hasRace = d.hasRace
        raceDate = d.raceDate ?? raceDate
        reason = d.reason
        raceDistance = d.raceDistance.flatMap(RaceDistance.init(rawValue:))
        muscleFocus = Set(d.muscleFocus.compactMap(MuscleGroup.init(rawValue:)))
        preferredDays = Set(d.preferredDays)
        hybridPriority = d.hybridPriority.flatMap(HybridPriority.init(rawValue:)) ?? hybridPriority
        strengthSplit = d.strengthSplit.flatMap(StrengthSplitStyle.init(rawValue:)) ?? strengthSplit
        intensity = d.intensity.flatMap(PlanIntensity.init(rawValue:)) ?? intensity
        goalHours = d.goalHours
        goalMinutes = d.goalMinutes
        sex = d.sex.flatMap(BiologicalSex.init(rawValue:))
        heightCm = d.heightCm
        weightUnitChoice = d.weightUnitChoice
        distanceUnitChoice = d.distanceUnitChoice
        heightMetricChoice = d.heightMetricChoice
        birthYear = d.birthYear
        bodyMassKg = d.bodyMassKg
        weeklyRunVolumeM = d.weeklyRunVolumeM
        longestRunM = d.longestRunM
        targetWeeklyRunVolumeM = d.targetWeeklyRunVolumeM
        calibrationMode = d.calibrationMode.flatMap(CalibrationMode.init(rawValue:)) ?? calibrationMode
        paceFeel = d.paceFeel.flatMap(PaceFeel.init(rawValue:))
        benchmark = d.benchmark.flatMap(RunBenchmark.init(rawValue:)) ?? benchmark
        recentRunSeconds = d.recentRunSeconds ?? recentRunSeconds
        healthRestingHR = d.importedRestingHR
        plannedRaceName = d.plannedRaceName
        step = placedStep
        // Cross-version skew guard: single fields fall back to defaults on unknown rawValues
        // (that's the draft's resilience design), which can leave `placedStep` gated OFF under
        // the restored answers — e.g. resumed onto `.race` with the goal defaulted away from
        // racing. `advance()`/`back()` both no-op silently when the current step isn't in
        // `steps`, a permanent dead Continue. Refuse the draft instead; the restored answers
        // stay as harmless prefills for the fresh run-through.
        guard steps.contains(placedStep) else {
            step = Step.allCases.first ?? step
            return false
        }
        // Answers restored up to here were the athlete's own — per-step prefills (the intensity
        // recommendation) must not overwrite them on re-entry. See `restoredAtOrPast`.
        restoredStep = placedStep
        return true
    }

    /// One decode per process: `OnboardingFlow` holds its VM in `@State`, whose initial-value
    /// expression re-runs on every re-init of the view (each RootView body pass while the cover is
    /// up) and is immediately discarded. The draft only matters on the FIRST construction after a
    /// process start — later passes skip the UserDefaults read + JSON decode entirely.
    @MainActor private static var resumeAttempted = false

    /// A fresh view model, or one restored from a saved draft when a previous onboarding was
    /// interrupted before the profile was created. Deep-link launches (`--onboarding-*`) drive the
    /// step themselves and never resume; the base flow and a plain launch do.
    static func resuming() -> OnboardingViewModel {
        let vm = OnboardingViewModel()
        guard !Self.resumeAttempted else { return vm }
        Self.resumeAttempted = true
        #if DEBUG
        // Verification hook: seed a mid-flow draft so the launch resumes onto it (RootView shows
        // onboarding on its own — signed in via AuthController's --resume-demo, no profile yet).
        if ProcessInfo.processInfo.arguments.contains("--resume-demo") { OnboardingDraftStore.save(.demo) }
        #endif
        let deepLinked = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--onboarding-") }
        guard !deepLinked else { return vm }
        if let draft = OnboardingDraftStore.load(), vm.restore(from: draft) { return vm }
        OnboardingDraftStore.clear()   // absent or incompatible → start clean
        return vm
    }
}

#if DEBUG
extension OnboardingDraft {
    /// A representative mid-flow draft (caught on the "days" step) for verifying resume on device
    /// via `--resume-demo`.
    static var demo: OnboardingDraft {
        var d = OnboardingDraft(savedStep: "days")
        d.name = "Maya"
        d.activities = [ActivityChoice.run.rawValue]
        d.goal = Goal.raceDistance.rawValue
        d.raceDistance = RaceDistance.marathon.rawValue
        d.experience = ExperienceLevel.some.rawValue
        d.hasRace = true
        d.daysPerWeek = 4
        d.sex = BiologicalSex.male.rawValue
        d.birthYear = Calendar.current.component(.year, from: Date()) - 30
        return d
    }
}
#endif
