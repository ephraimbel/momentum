import Foundation
import SwiftData

/// The injury feedback loop (ENDURANCE-FOCUS §8.2): the athlete reports an issue — a body area and how
/// bad it is — and the plan responds deterministically and safely. Never a diagnosis, never a red
/// "failed" state: we reduce the aggravating stress, preserve fitness with non-impact work, say the
/// red flags out loud, and gate the way back. The AI narrates; these conservative product rules
/// decide how the plan changes, without diagnosing the issue or predicting recovery time.
enum InjurySeverity: String, Codable, Sendable, CaseIterable, Identifiable {
    case twinge, moderate, severe
    var id: String { rawValue }

    var label: String {
        switch self {
        case .twinge: "A slight twinge"
        case .moderate: "It changes how I run"
        case .severe: "I can't run on it"
        }
    }
    var subtitle: String {
        switch self {
        case .twinge: "Mild. I notice it, but it doesn't change my stride"
        case .moderate: "It hurts or alters my gait, but I can keep moving"
        case .severe: "Sharp pain, limping, or I'm avoiding it entirely"
        }
    }
    /// How long the plan trains around it before we check back in.
    var windowDays: Int {
        switch self { case .twinge: 5; case .moderate: 10; case .severe: 14 }
    }
}

enum InjuryResponse {
    /// Marker prefix on converted sessions' rationale — lets `resume` find and restore exactly the
    /// sessions this loop touched (never anything the athlete or another adaptation changed).
    static let marker = "Protecting your"

    struct Outcome: Sendable {
        let headline: String
        let detail: String
        let guidance: String      // general management — never a diagnosis
        let sessionsChanged: Int
    }

    /// Apply the deterministic response for a report: reshape the window's running sessions, stamp the
    /// active-injury state on the profile, and record it (adaptation history + the bell inbox).
    @MainActor
    @discardableResult
    static func report(area: InjuryArea, severity: InjurySeverity,
                       profile: UserProfile, today: Date = Date(),
                       in context: ModelContext, calendar: Calendar = .current) -> Outcome {
        let until = calendar.date(byAdding: .day, value: severity.windowDays, to: calendar.startOfDay(for: today)) ?? today
        let areaName = area.label.lowercased()
        var changed = 0

        if let plan = profile.plan {
            let p5k = plan.p5kSPerKm
            let unit = (DistanceUnit(rawValue: profile.distanceUnit) ?? .auto).resolved()   // keep returns clean
            // `.moved` sessions are still upcoming work — reconcileMissed rolls slipped days forward
            // as .moved, and an injured athlete must not keep a quality session just because it slid.
            let window = plan.sessions.filter {
                ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                && $0.discipline == .running
                && calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: today)
                && $0.date <= until
            }
            for s in window {
                switch severity {
                case .twinge:
                    // Keep running, drop the intensity: quality → easy, volume trimmed a touch.
                    if let rt = s.runType, rt.isQuality || rt == .long {
                        s.runType = .easy
                        s.intervals = nil
                        s.targetPaceSPerKm = RunRounding.snapPace(
                            sPerKm: PlanEngine.pace(.easy, p5k: p5k), unit: unit, type: .easy)
                    }
                    if let d = s.targetDistanceM { s.targetDistanceM = RunRounding.snap(meters: d * 0.9, unit: unit) }
                    s.rationale = "\(marker) \(areaName). Easy running only while it settles."
                case .moderate, .severe:
                    // Remove impact. The replacement is always optional; severe reports get a much
                    // shorter placeholder and explicit professional-care language in the outcome.
                    let duration: Double
                    if let dur = s.targetDurationS {
                        duration = dur
                    } else if let d = s.targetDistanceM {
                        duration = d / 1000 * (s.targetPaceSPerKm ?? PlanEngine.pace(.easy, p5k: p5k))
                    } else {
                        duration = 2_400
                    }
                    s.discipline = .cycling
                    s.sportType = WorkoutType.ride.rawValue
                    s.runType = nil
                    s.intervals = nil
                    s.targetDistanceM = nil
                    s.targetPaceSPerKm = nil
                    s.targetDurationS = (severity == .severe ? duration * 0.5 : duration).rounded()
                    s.rationale = severity == .severe
                        ? "\(marker) \(areaName). No running. This optional easy spin is only a placeholder; rest instead if it is uncomfortable or you have not been advised that it is appropriate."
                        : "\(marker) \(areaName). No impact running. Easy non-impact work is optional and should stop if it aggravates the area."
                }
                changed += 1
            }
        }

        profile.activeInjuryArea = area.rawValue
        profile.activeInjurySeverity = severity.rawValue
        profile.activeInjuryUntil = until
        // Remember the area as a conservative planning modifier, with no duplicates. This history
        // does not diagnose the athlete or establish current capacity.
        if !profile.injuryHistory.contains(area.rawValue) {
            profile.injuryHistory = (profile.injuryHistory + [area.rawValue]).sorted()
        }
        // An injury response IS this week's structural change — joining the shared throttle keeps
        // load-based auto-adaptation from re-shaping the same sessions days later. (The injury loop
        // itself never *reads* the throttle: reporting pain must always work.)
        profile.plan?.lastAdaptedAt = today

        let outcome = outcomeCopy(area: areaName, severity: severity, changed: changed)
        CoachingEvent.record(kind: .recover, headline: outcome.headline, detail: outcome.detail,
                             on: today, in: context)
        try? context.save()
        return outcome
    }

    /// The athlete says they're feeling better: clear the injury state and bring back the window's
    /// converted sessions as a gentle return — a short recovery run first, easy running after, never
    /// straight back to quality. Only touches sessions this loop marked.
    @MainActor
    @discardableResult
    static func resume(profile: UserProfile, today: Date = Date(),
                       in context: ModelContext, calendar: Calendar = .current) -> Outcome {
        var restored = 0
        if let plan = profile.plan {
            let p5k = plan.p5kSPerKm
            let unit = (DistanceUnit(rawValue: profile.distanceUnit) ?? .auto).resolved()
            let mine = plan.sessions.filter {
                ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                && calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: today)
                && ($0.rationale?.hasPrefix(marker) ?? false)
            }.sorted { $0.date < $1.date }
            for (i, s) in mine.enumerated() {
                s.discipline = .running
                s.sportType = nil
                s.intervals = nil
                s.targetDurationS = nil
                if i == 0 {
                    s.runType = .recovery
                    s.targetDistanceM = RunRounding.snap(meters: 3_000, unit: unit)   // a short test-the-waters return
                    s.targetPaceSPerKm = RunRounding.snapPace(
                        sPerKm: PlanEngine.pace(.recovery, p5k: p5k), unit: unit, type: .recovery)
                    s.rationale = "Welcome back. A short, gentle return. Stop if anything flares."
                } else {
                    s.runType = .easy
                    s.targetDistanceM = RunRounding.snap(meters: 5_000, unit: unit)
                    s.targetPaceSPerKm = RunRounding.snapPace(
                        sPerKm: PlanEngine.pace(.easy, p5k: p5k), unit: unit, type: .easy)
                    s.rationale = "Easy miles while you rebuild. Quality work returns next week."
                }
                restored += 1
            }
            // The return gate: the first week back holds NO quality anywhere — including sessions the
            // injury window never touched. Early confidence can outrun rebuilt tolerance: the athlete
            // may feel fine while the untouched plan still says "intervals".
            let gateEnd = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: today)) ?? today
            let eager = plan.sessions.filter {
                ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                && $0.discipline == .running
                && calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: today)
                && $0.date <= gateEnd
                && ($0.runType?.isQuality == true || $0.runType == .long)
            }
            for s in eager {
                s.runType = .easy
                s.intervals = nil
                s.targetPaceSPerKm = RunRounding.snapPace(
                    sPerKm: PlanEngine.pace(.easy, p5k: p5k), unit: unit, type: .easy)
                if let d = s.targetDistanceM { s.targetDistanceM = RunRounding.snap(meters: min(d, 8_000), unit: unit) }
                s.rationale = "First week back, easy only. Quality returns once you've settled."
            }
        }
        profile.activeInjuryArea = nil
        profile.activeInjurySeverity = nil
        profile.activeInjuryUntil = nil
        // The restored return-to-run week is a structural change too — hold the shared throttle so
        // recovery adaptation can't immediately re-ease the just-rebuilt gate sessions.
        profile.plan?.lastAdaptedAt = today

        var detail = restored > 0
            ? "Eased you back in: a short recovery run first, easy miles after. Quality work returns once you're settled."
            : "Glad you're feeling better. Your plan continues as written."
        // Honest re-timing (§8.2): a pause with a race on the calendar deserves a straight answer
        // about the goal — reassurance when there's room, the truth when there isn't.
        if let retiming = raceRetiming(profile: profile, today: today, calendar: calendar) {
            detail += " \(retiming)"
        }
        let outcome = Outcome(headline: "Back to running",
                              detail: detail,
                              guidance: "If the pain comes back, report it again and we'll adjust.",
                              sessionsChanged: restored)
        CoachingEvent.record(kind: .ease, headline: outcome.headline, detail: outcome.detail,
                             on: today, in: context)
        try? context.save()
        return outcome
    }

    /// Where the race goal stands after the pause — the feasibility engine re-run against today's
    /// calendar. nil when there's no dated race ahead.
    @MainActor
    static func raceRetiming(profile: UserProfile, today: Date = Date(),
                             calendar: Calendar = .current) -> String? {
        guard let raceDate = profile.raceDate, raceDate > today,
              let distanceM = profile.raceDistanceM, distanceM > 0 else { return nil }
        let weeks = max(0, calendar.dateComponents([.weekOfYear], from: today, to: raceDate).weekOfYear ?? 0)
        let experience = ExperienceLevel(rawValue: profile.experience[Discipline.running.rawValue] ?? "") ?? .some
        let f = PlanFeasibility.assess(raceDistanceM: distanceM,
                                       goalFinishTimeS: profile.goalFinishTimeS,
                                       currentP5kSPerKm: profile.plan?.p5kSPerKm,
                                       currentWeeklyVolumeM: profile.weeklyRunVolumeM ?? 0,
                                       weeksAvailable: weeks,
                                       experience: experience)
        let label = RaceDistance.nearest(toMeters: distanceM).label.lowercased()
        switch f.verdict {
        case .onTrack:
            return "Your \(label) is still on track. \(weeks) weeks is enough runway."
        case .tight:
            return "The \(label) is tighter now: \(weeks) weeks where we'd like about \(f.weeksNeeded). Doable if the body cooperates. Consistency over heroics."
        case .tooShort:
            return "Honestly, \(weeks) weeks to the \(label) is short after a pause. A safe build wants about \(f.weeksNeeded). Consider adjusting the goal time or the date, and we'll make either work."
        case .noRace:
            return nil
        }
    }

    // MARK: Copy (general management — never a diagnosis, red flags said out loud)

    private static func outcomeCopy(area: String, severity: InjurySeverity, changed: Int) -> Outcome {
        switch severity {
        case .twinge:
            return Outcome(
                headline: "Training around your \(area)",
                detail: "Kept the next \(InjurySeverity.twinge.windowDays) days low-intensity and reduced aggravating work. This is a conservative plan adjustment, not a diagnosis.",
                guidance: "Monitor it during and after activity. If it sharpens, changes your stride, worsens, or concerns you, stop and seek qualified assessment.",
                sessionsChanged: changed)
        case .moderate:
            return Outcome(
                headline: "Resting the impact on your \(area)",
                detail: "Replaced \(InjurySeverity.moderate.windowDays) days of impact running with optional easy non-impact work only if it feels comfortable.",
                guidance: "Pain that changes gait or function, persists, worsens, swells, or occurs at rest deserves qualified assessment.",
                sessionsChanged: changed)
        case .severe:
            return Outcome(
                headline: "Protecting your \(area), no running",
                detail: "Removed impact running for \(InjurySeverity.severe.windowDays) days. Do not use the app to test the area; the replacement sessions are optional placeholders, not treatment advice.",
                guidance: "Please seek appropriate professional care. Sharp pain, limping, or inability to bear weight is not something to train through.",
                sessionsChanged: changed)
        }
    }
}
