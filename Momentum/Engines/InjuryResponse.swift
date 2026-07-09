import Foundation
import SwiftData

/// The injury feedback loop (ENDURANCE-FOCUS §8.2): the athlete reports an issue — a body area and how
/// bad it is — and the plan responds deterministically and safely. Never a diagnosis, never a red
/// "failed" state: we reduce the aggravating stress, preserve fitness with non-impact work, say the
/// red flags out loud, and gate the way back. The AI narrates; these rules decide.
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
        case .twinge: "Mild — I notice it, but it doesn't change my stride"
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
            let window = plan.sessions.filter {
                $0.status == .planned && $0.completedWorkout == nil
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
                        s.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: p5k)
                    }
                    if let d = s.targetDistanceM { s.targetDistanceM = (d * 0.9).rounded() }
                    s.rationale = "\(marker) \(areaName) — easy running only while it settles."
                case .moderate, .severe:
                    // Rest the impact; keep the engine with non-impact cross-training. Severe halves
                    // the duration and makes it explicitly optional (pain-free only).
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
                        ? "\(marker) \(areaName) — no running. Easy spin ONLY if completely pain-free; otherwise rest."
                        : "\(marker) \(areaName) — no impact. Easy cross-training keeps your fitness while it heals."
                }
                changed += 1
            }
        }

        profile.activeInjuryArea = area.rawValue
        profile.activeInjurySeverity = severity.rawValue
        profile.activeInjuryUntil = until
        // Remember the area for future plan generation (protective ramps), no duplicates.
        if !profile.injuryHistory.contains(area.rawValue) {
            profile.injuryHistory = (profile.injuryHistory + [area.rawValue]).sorted()
        }

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
            let mine = plan.sessions.filter {
                $0.status == .planned && $0.completedWorkout == nil
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
                    s.targetDistanceM = 3_000                       // a short test-the-waters return
                    s.targetPaceSPerKm = PlanEngine.pace(.recovery, p5k: p5k)
                    s.rationale = "Welcome back — a short, gentle return. Stop if anything flares."
                } else {
                    s.runType = .easy
                    s.targetDistanceM = 5_000
                    s.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: p5k)
                    s.rationale = "Easy miles while you rebuild — quality work returns next week."
                }
                restored += 1
            }
            // The return gate: the first week back holds NO quality anywhere — including sessions the
            // injury window never touched. Re-injury risk peaks right here, when the athlete feels
            // fine and the plan still says "intervals".
            let gateEnd = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: today)) ?? today
            let eager = plan.sessions.filter {
                $0.status == .planned && $0.completedWorkout == nil
                && $0.discipline == .running
                && calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: today)
                && $0.date <= gateEnd
                && ($0.runType?.isQuality == true || $0.runType == .long)
            }
            for s in eager {
                s.runType = .easy
                s.intervals = nil
                s.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: p5k)
                if let d = s.targetDistanceM { s.targetDistanceM = min(d, 8_000) }
                s.rationale = "First week back — easy only. Quality returns once you've settled."
            }
        }
        profile.activeInjuryArea = nil
        profile.activeInjurySeverity = nil
        profile.activeInjuryUntil = nil

        let outcome = Outcome(headline: "Back to running",
                              detail: restored > 0
                                ? "Eased you back in: a short recovery run first, easy miles after. Quality work returns once you're settled."
                                : "Glad you're feeling better — your plan continues as written.",
                              guidance: "If the pain comes back, report it again and we'll adjust.",
                              sessionsChanged: restored)
        CoachingEvent.record(kind: .ease, headline: outcome.headline, detail: outcome.detail,
                             on: today, in: context)
        try? context.save()
        return outcome
    }

    // MARK: Copy (general management — never a diagnosis, red flags said out loud)

    private static func outcomeCopy(area: String, severity: InjurySeverity, changed: Int) -> Outcome {
        switch severity {
        case .twinge:
            return Outcome(
                headline: "Training around your \(area)",
                detail: "Kept you running, dropped the intensity for \(InjurySeverity.twinge.windowDays) days. Most twinges settle with easy running and rest.",
                guidance: "Ice and gentle mobility can help. If it sharpens, changes your stride, or lasts beyond a week — report it again or see a physio.",
                sessionsChanged: changed)
        case .moderate:
            return Outcome(
                headline: "Resting the impact on your \(area)",
                detail: "Swapped \(InjurySeverity.moderate.windowDays) days of running for easy cross-training — your fitness holds while it heals.",
                guidance: "If it isn't clearly improving in 3–5 days, a physio is worth the visit. Sharp pain, swelling, or pain at rest → get it looked at now.",
                sessionsChanged: changed)
        case .severe:
            return Outcome(
                headline: "Protecting your \(area) — no running",
                detail: "Stood running down for \(InjurySeverity.severe.windowDays) days. Optional pain-free spinning keeps the engine; everything else waits.",
                guidance: "Please see a professional — sharp pain, limping, or not being able to bear weight isn't something to train through. We'll be ready when you're cleared.",
                sessionsChanged: changed)
        }
    }
}
