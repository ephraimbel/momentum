import Foundation

enum PlanValidationCode: String, Codable, CaseIterable, Hashable, Sendable {
    case emptyPlan
    case horizonExceeded
    case unexpectedPlanLength
    case nonSequentialWeekIndex
    case emptyWeek
    case sessionsNotOrdered
    case invalidDayOffset
    case duplicateTrainingDay
    case frequencyBudgetMismatch
    case invalidPlanPace
    case invalidWeeklyVolume
    case invalidDistance
    case invalidDuration
    case invalidSessionPace
    case unsnappedPace
    case mixedSessionModalities
    case missingStrengthPrescription
    case invalidStrengthPrescription
    case hardRunAfterHardLowerLift
    case deloadContainsHardRun
    case downWeekDidNotReduce
    case recentToUsualLoadCapExceeded
    case autoPlanRequiresHills
    case historyRestrictionNotApplied
    case taperMissing
    case raceMissing
    case unexpectedRace
    case raceMisaligned
    case raceDistanceMismatch
    case trainingAfterTerminalRace
}

struct PlanValidationLocation: Codable, Equatable, Sendable {
    var weekIndex: Int?
    var dayOffset: Int?

    static let plan = PlanValidationLocation()
}

struct PlanValidationIssue: Codable, Equatable, Sendable {
    var code: PlanValidationCode
    var location: PlanValidationLocation
    /// Local developer detail. Never send exact prescriptions through product analytics.
    var detail: String
}

enum LegacyPlanExceptionCode: String, Codable, CaseIterable, Hashable, Sendable {
    case startReturnContinuityGateUnavailable
    case intervalPrescriptionIsUnstructured
    case strengthCalibrationUnused
    case automaticUnitUsesProcessLocale
    case dayBudgetIsSilentlyClamped
    case podiumFloorIsNotATypedConflict
    case raceGoalMissingDistanceIsNotATypedConflict
    case pastRaceDateIsClamped
    case postRoundingReductionsCanBreakDistanceGrid
}

struct LegacyPlanException: Codable, Equatable, Sendable {
    var code: LegacyPlanExceptionCode
    var detail: String
}

struct PlanValidationReport: Codable, Equatable, Sendable {
    var hardViolations: [PlanValidationIssue]
    var legacyExceptions: [LegacyPlanException]

    var isValid: Bool { hardViolations.isEmpty }
}

/// Read-only validation wrapper for the shipping plan engine. It does not repair a candidate and it
/// never touches SwiftData: a hard issue means the candidate must not be treated as qualified.
enum LegacyPlanInvariantValidator {
    static func validate(_ plan: GeneratedPlan,
                         inputs: PlanInputs,
                         calibration: CalibrationSeed = .none,
                         startDate: Date,
                         calendar: Calendar = .current) -> PlanValidationReport {
        var issues: [PlanValidationIssue] = []
        var exceptions: [LegacyPlanException] = []

        func record(_ code: PlanValidationCode,
                    week: Int? = nil,
                    day: Int? = nil,
                    _ detail: String) {
            issues.append(PlanValidationIssue(
                code: code,
                location: PlanValidationLocation(weekIndex: week, dayOffset: day),
                detail: detail
            ))
        }

        func legacy(_ code: LegacyPlanExceptionCode, _ detail: String) {
            guard !exceptions.contains(where: { $0.code == code }) else { return }
            exceptions.append(LegacyPlanException(code: code, detail: detail))
        }

        if inputs.runningExperience == .new {
            legacy(.startReturnContinuityGateUnavailable,
                   "Legacy PlanInputs has experience, but no continuity/response gate for start-return progression.")
        }
        if plan.weeks.contains(where: { $0.sessions.contains { $0.intervals != nil } }) {
            legacy(.intervalPrescriptionIsUnstructured,
                   "Interval structure exists only as text, so semantic replay must preserve the normalized prescription string.")
        }
        if !calibration.lifts.isEmpty {
            legacy(.strengthCalibrationUnused,
                   "Legacy generation accepts lift calibration but does not apply it to strength prescriptions.")
        }
        if inputs.distanceUnit == .auto {
            legacy(.automaticUnitUsesProcessLocale,
                   "Legacy rounding resolves .auto through the process locale rather than an injected replay locale.")
        }
        if !(1...7).contains(inputs.daysPerWeek) {
            legacy(.dayBudgetIsSilentlyClamped,
                   "Legacy generation clamps daysPerWeek into 1...7 instead of returning a typed input conflict.")
        }
        if inputs.intensity == .podium, inputs.daysPerWeek < PlanIntensity.podium.floorDays {
            legacy(.podiumFloorIsNotATypedConflict,
                   "Legacy generation degrades Podium below its five-day floor instead of returning a typed conflict.")
        }
        if inputs.goal == .raceDistance, (inputs.raceDistanceM ?? 0) <= 0 {
            legacy(.raceGoalMissingDistanceIsNotATypedConflict,
                   "A race goal without a positive distance falls through to a generic block instead of returning a typed conflict.")
        }
        if let raceDate = inputs.raceDate, raceDate < calendar.startOfDay(for: startDate) {
            legacy(.pastRaceDateIsClamped,
                   "A past race date is clamped to a one-week horizon instead of returning a typed conflict.")
        }
        if inputs.distanceUnit != .auto,
           plan.weeks.lazy.flatMap(\.sessions).contains(where: {
               guard let distance = $0.targetDistanceM, distance.isFinite, distance > 0 else {
                   return false
               }
               let canonical = $0.runType == .race
                   || $0.intervals?.contains("Time trial") == true
               let snapped = RunRounding.snap(
                   meters: distance,
                   unit: inputs.distanceUnit,
                   isRace: canonical
               )
               return abs(snapped - distance) > 0.01
           }) {
            legacy(.postRoundingReductionsCanBreakDistanceGrid,
                   "A load-cap or down-week pass can reduce already-rounded session distances off the display grid.")
        }

        guard !plan.weeks.isEmpty else {
            record(.emptyPlan, "Generated plan contains no weeks.")
            return PlanValidationReport(hardViolations: issues, legacyExceptions: sorted(exceptions))
        }
        if plan.weeks.count > 52 {
            record(.horizonExceeded, "Generated horizon is \(plan.weeks.count) weeks; maximum is 52.")
        }

        let expectedWeeks = PlanEngine.weeksToGenerate(
            startDate: startDate,
            raceDate: inputs.raceDate,
            calendar: calendar
        )
        if plan.weeks.count != expectedWeeks {
            record(.unexpectedPlanLength,
                   "Generated \(plan.weeks.count) weeks; the normalized runway requires \(expectedWeeks).")
        }
        if plan.weeks.map(\.index) != Array(0..<plan.weeks.count) {
            record(.nonSequentialWeekIndex,
                   "Week indices must be ordered and contiguous from zero.")
        }
        if !validPace(plan.p5kSPerKm) {
            record(.invalidPlanPace, "Plan 5K pace is non-finite or outside 120...1200 s/km.")
        }
        if let goalPace = plan.goalRacePaceSPerKm, !validPace(goalPace) {
            record(.invalidPlanPace, "Goal race pace is non-finite or outside 120...1200 s/km.")
        }

        let recognized = Set(inputs.disciplines).intersection([.running, .walking, .cycling, .strength])
        if recognized.isEmpty {
            record(.emptyWeek, "Request has no discipline the legacy planner can schedule.")
        }

        let dayBudget = max(1, min(7, inputs.daysPerWeek))
        let hasRunning = inputs.disciplines.contains(.running)
        let runDays: Int = {
            guard hasRunning else { return 0 }
            guard inputs.disciplines.contains(.strength) else { return dayBudget }
            return PlanEngine.hybridSplit(
                days: dayBudget,
                priority: inputs.hybridPriority,
                goal: inputs.goal,
                raceDistanceM: inputs.raceDate != nil ? inputs.raceDistanceM : nil
            ).runDays
        }()
        let podiumActive = inputs.intensity == .podium
            && hasRunning
            && runDays >= 5
            && inputs.injuryHistory.isEmpty
        var lastLoadingRunVolume: Double?

        for week in plan.weeks {
            let weekIndex = week.index
            if week.sessions.isEmpty {
                record(.emptyWeek, week: weekIndex, "Generated week has no sessions.")
            }
            let offsets = week.sessions.map(\.dayOffset)
            if offsets != offsets.sorted() {
                record(.sessionsNotOrdered, week: weekIndex,
                       "Sessions are not ordered by in-week day offset.")
            }
            for day in offsets where !(0...6).contains(day) {
                record(.invalidDayOffset, week: weekIndex, day: day,
                       "Session day offset must be inside 0...6.")
            }
            if Set(offsets).count != offsets.count {
                record(.duplicateTrainingDay, week: weekIndex,
                       "Legacy plans do not support two sessions on one day.")
            }

            let raceSessions = week.sessions.filter { $0.runType == .race }
            if raceSessions.isEmpty {
                let shakeout = podiumActive && dayBudget <= 6 && runDays <= 6
                    && !week.isDeload && !week.isTaper
                    && week.phase != .recovery ? 1 : 0
                let expected = dayBudget + shakeout
                if week.sessions.count != expected {
                    record(.frequencyBudgetMismatch, week: weekIndex,
                           "Week has \(week.sessions.count) sessions; expected \(expected) for this legacy request.")
                }
            } else if week.sessions.count > dayBudget + 1 {
                record(.frequencyBudgetMismatch, week: weekIndex,
                       "Race week exceeds the day budget plus its terminal race session.")
            }

            if !PlanEngine.scheduleSatisfiesRecovery(week.sessions) {
                record(.hardRunAfterHardLowerLift, week: weekIndex,
                       "A hard run follows a hard lower-body lift without a day between.")
            }
            if week.isDeload, week.sessions.contains(where: \.isHardRun) {
                record(.deloadContainsHardRun, week: weekIndex,
                       "A deload week contains a hard run.")
            }
            if !week.trainingVolumeM.isFinite || week.trainingVolumeM < 0 {
                record(.invalidWeeklyVolume, week: weekIndex,
                       "Weekly endurance volume is negative or non-finite.")
            }

            if hasRunning {
                if week.isDeload || week.isTaper {
                    if let previous = lastLoadingRunVolume, previous > 0,
                       !(week.runVolumeM < previous) {
                        record(.downWeekDidNotReduce, week: weekIndex,
                               "An eased week does not dip below the preceding loading week.")
                    }
                } else if week.runVolumeM > 0 {
                    lastLoadingRunVolume = week.runVolumeM
                }
            }

            for session in week.sessions {
                validateSession(
                    session,
                    week: weekIndex,
                    inputs: inputs,
                    record: record
                )
            }
        }

        if hasRunning, plan.weeks.allSatisfy({ $0.runVolumeM.isFinite }) {
            let factors = ACWRGovernor.capFactors(
                weeklyMeters: plan.weeks.map(\.runVolumeM),
                currentWeeklyM: inputs.currentWeeklyVolumeM ?? 0
            )
            if let index = factors.firstIndex(where: { !$0.isFinite || $0 < 0.95 }) {
                record(.recentToUsualLoadCapExceeded, week: index,
                       "A generated week remains materially above the legacy recent-to-usual load cap after rounding.")
            }
        }

        validateRace(
            plan,
            inputs: inputs,
            startDate: startDate,
            calendar: calendar,
            record: record
        )

        issues.sort(by: issueOrder)
        return PlanValidationReport(hardViolations: issues, legacyExceptions: sorted(exceptions))
    }

    private static func validateSession(_ session: GeneratedSession,
                                        week: Int,
                                        inputs: PlanInputs,
                                        record: (PlanValidationCode, Int?, Int?, String) -> Void) {
        let day = session.dayOffset
        if session.discipline == .strength {
            if session.targetDistanceM != nil || session.targetDurationS != nil
                || session.targetPaceSPerKm != nil || session.runType != nil {
                record(.mixedSessionModalities, week, day,
                       "Strength session also contains an endurance prescription.")
            }
            if session.strengthTargets.isEmpty {
                record(.missingStrengthPrescription, week, day,
                       "Strength session contains no exercise prescription.")
            }
            for exercise in session.strengthTargets {
                let rpeValid = exercise.targetRPE.map { $0.isFinite && (0...10).contains($0) } ?? true
                let pctValid = exercise.targetPctRM.map { $0.isFinite && (0...1).contains($0) } ?? true
                if exercise.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || exercise.targetSets <= 0 || exercise.repLow <= 0
                    || exercise.repHigh < exercise.repLow || !rpeValid || !pctValid {
                    record(.invalidStrengthPrescription, week, day,
                           "Strength target has an invalid name, set/rep range, RPE or percent-RM value.")
                }
            }
            return
        }

        if !session.strengthTargets.isEmpty || session.strengthLabel != nil || session.isHardLowerLift {
            record(.mixedSessionModalities, week, day,
                   "Endurance session also contains a strength prescription.")
        }
        if session.targetDistanceM == nil && session.targetDurationS == nil {
            record(.invalidDistance, week, day,
                   "Endurance session has neither a positive distance nor duration.")
        }
        if let distance = session.targetDistanceM {
            if !distance.isFinite || distance <= 0 {
                record(.invalidDistance, week, day,
                       "Target distance must be finite and positive.")
            }
        }
        if let duration = session.targetDurationS, !duration.isFinite || duration <= 0 {
            record(.invalidDuration, week, day,
                   "Target duration must be finite and positive.")
        }
        if session.discipline == .running, session.targetPaceSPerKm == nil {
            record(.invalidSessionPace, week, day,
                   "Running session has no target pace.")
        }
        if let pace = session.targetPaceSPerKm {
            if !validPace(pace) {
                record(.invalidSessionPace, week, day,
                       "Target pace is non-finite or outside 120...1200 s/km.")
            } else if inputs.distanceUnit != .auto, let runType = session.runType {
                let snapped = RunRounding.snapPace(
                    sPerKm: pace,
                    unit: inputs.distanceUnit,
                    type: runType
                )
                if abs(snapped - pace) > 0.001 {
                    record(.unsnappedPace, week, day,
                           "Target pace is not on the athlete's prescription grid.")
                }
            }
        }
        if session.runType == .hills {
            record(.autoPlanRequiresHills, week, day,
                   "The automatic legacy plan requires terrain-specific hill work.")
        }
        if !Set(inputs.injuryHistory).isDisjoint(with: PlanEngine.speedSensitiveAreas) {
            if session.runType == .strides || session.intervals?.localizedCaseInsensitiveContains("@ 5K") == true {
                record(.historyRestrictionNotApplied, week, day,
                       "A speed-sensitive history modifier did not suppress the legacy speed exposure.")
            }
        }
    }

    private static func validateRace(_ plan: GeneratedPlan,
                                     inputs: PlanInputs,
                                     startDate: Date,
                                     calendar: Calendar,
                                     record: (PlanValidationCode, Int?, Int?, String) -> Void) {
        let races: [(week: Int, session: GeneratedSession)] = plan.weeks.flatMap { week in
            week.sessions.filter { $0.runType == .race }.map { (week.index, $0) }
        }
        guard let raceDate = inputs.raceDate,
              let raceDistance = inputs.raceDistanceM,
              raceDistance > 0,
              inputs.disciplines.contains(.running) else {
            for race in races {
                record(.unexpectedRace, race.week, race.session.dayOffset,
                       "Plan contains a race without a supported running race request.")
            }
            return
        }

        let dayCount = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: startDate),
            to: calendar.startOfDay(for: raceDate)
        ).day ?? -1
        let expectedWeek = dayCount >= 0 ? dayCount / 7 : -1
        let expectedDay = dayCount >= 0 ? dayCount % 7 : -1
        let inWindow = expectedWeek >= 0 && expectedWeek < plan.weeks.count
        guard inWindow else {
            for race in races {
                record(.unexpectedRace, race.week, race.session.dayOffset,
                       "Plan contains a race outside the generated horizon.")
            }
            return
        }

        if races.isEmpty {
            record(.raceMissing, expectedWeek, expectedDay,
                   "In-window running race is missing from the plan.")
            return
        }
        if races.count != 1 {
            record(.unexpectedRace, nil, nil,
                   "Plan contains \(races.count) terminal race sessions.")
        }
        for race in races {
            if race.week != expectedWeek || race.session.dayOffset != expectedDay {
                record(.raceMisaligned, race.week, race.session.dayOffset,
                       "Race session is not on the requested calendar day.")
            }
            if abs((race.session.targetDistanceM ?? 0) - raceDistance) > 1 {
                record(.raceDistanceMismatch, race.week, race.session.dayOffset,
                       "Race session distance does not match the requested event.")
            }
            if let week = plan.weeks.first(where: { $0.index == race.week }),
               week.sessions.contains(where: {
                   $0.runType != .race && $0.dayOffset >= race.session.dayOffset
               }) {
                record(.trainingAfterTerminalRace, race.week, race.session.dayOffset,
                       "Training remains on or after the terminal race day.")
            }
            if plan.weeks.contains(where: { $0.index > race.week && !$0.sessions.isEmpty }) {
                record(.trainingAfterTerminalRace, race.week, race.session.dayOffset,
                       "Training weeks remain after the terminal race.")
            }
        }
        if plan.weeks.last?.isTaper != true {
            record(.taperMissing, expectedWeek, nil,
                   "An in-window race plan does not finish in a taper week.")
        }
    }

    private static func validPace(_ value: Double) -> Bool {
        value.isFinite && (120...1200).contains(value)
    }

    private static func issueOrder(_ lhs: PlanValidationIssue,
                                   _ rhs: PlanValidationIssue) -> Bool {
        let lw = lhs.location.weekIndex ?? -1
        let rw = rhs.location.weekIndex ?? -1
        if lw != rw { return lw < rw }
        let ld = lhs.location.dayOffset ?? -1
        let rd = rhs.location.dayOffset ?? -1
        if ld != rd { return ld < rd }
        return lhs.code.rawValue < rhs.code.rawValue
    }

    private static func sorted(_ exceptions: [LegacyPlanException]) -> [LegacyPlanException] {
        exceptions.sorted { $0.code.rawValue < $1.code.rawValue }
    }
}
