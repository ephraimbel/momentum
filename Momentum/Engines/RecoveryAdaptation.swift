import Foundation
import SwiftData

/// Recovery-driven daily adaptation (ENDURANCE-FOCUS §8.1): the wearable signals mirrored into Apple
/// Health (HRV, resting HR, sleep) can ease **today's** session — one bounded change, with the reason
/// said plainly. Never a red state, never a plan rewrite: quality becomes easy for a day, that's all.
/// An aggressive plan runs on a tighter leash (it also reacts to milder warnings). Deterministic; the
/// AI only narrates.
enum RecoveryAdaptation {

    struct Decision: Sendable, Equatable {
        let reason: String            // plain language, built from the actual signals
    }

    /// Decide whether today should be eased. Requires TWO independent warning signs — one noisy night
    /// never lurches the plan (§1 guardrail). The aggressive tier also counts a *slightly* elevated
    /// resting HR and a slightly shorter night (the tighter leash it was promised).
    static func decide(signals: RecoverySignals, intensity: PlanIntensity) -> Decision? {
        var reasons: [String] = []

        if signals.hrvTrend == .down { reasons.append("HRV below your norm") }

        // NOTE the trend polarity: `.down` is the "well up" caution (≥4 bpm over baseline); `.up` is
        // slightly raised (1–4 bpm) — only the aggressive leash reacts to the milder form.
        if signals.restingHRTrend == .down {
            reasons.append("resting HR elevated")
        } else if intensity == .aggressive, signals.restingHRTrend == .up {
            reasons.append("resting HR creeping up")
        }

        let sleepCut = intensity == .aggressive ? 6.5 : 6.0
        if let sleep = signals.sleepHours, sleep < sleepCut {
            reasons.append("a short night (\(String(format: "%.1f", sleep))h)")
        }

        guard reasons.count >= 2 else { return nil }
        return Decision(reason: reasons.joined(separator: " and "))
    }

    /// Apply a decision: soften **today's** run only — quality/long becomes easy at ~90% volume. If
    /// today is already easy (or a rest/strength day) there's nothing to protect; returns nil.
    /// Recorded once per day (CoachingEvent dedupes), mirrored to the bell inbox.
    @MainActor
    @discardableResult
    static func applyToToday(_ decision: Decision, plan: TrainingPlan?, today: Date = Date(),
                             in context: ModelContext, calendar: Calendar = .current) -> (headline: String, detail: String)? {
        guard let plan else { return nil }
        let todays = PlanCoaching.todaySessions(plan, on: today, calendar: calendar)
        guard let session = todays.first(where: {
            $0.status == .planned && $0.completedWorkout == nil && $0.discipline == .running
            && ($0.runType?.isQuality == true || $0.runType == .long)
        }) else { return nil }

        let p5k = plan.p5kSPerKm
        session.runType = .easy
        session.intervals = nil
        session.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: p5k)
        if let d = session.targetDistanceM { session.targetDistanceM = (d * 0.9).rounded() }
        if let dur = session.targetDurationS { session.targetDurationS = (dur * 0.9).rounded() }
        session.rationale = "Eased today — \(decision.reason). The hard work lands better when you're recovered."

        let note = (headline: "Easy day instead",
                    detail: "Your body's asking for it: \(decision.reason). Today's session is easy running; your plan picks back up tomorrow.")
        CoachingEvent.record(kind: .ease, headline: note.headline, detail: note.detail, on: today, in: context)
        try? context.save()
        return note
    }
}
