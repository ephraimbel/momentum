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
    /// resting HR and a slightly shorter night (the tighter leash it was promised). The morning
    /// check-in counts too: what the athlete says stands equal to what the wearable measured. Illness-
    /// watch deviations (breathing rate, wrist temperature) count the same way once their baselines
    /// are banded — nil until then, so an unlearned norm can never raise a false alarm.
    static func decide(signals: RecoverySignals, intensity: PlanIntensity,
                       checkin: DailyCheckin? = nil) -> Decision? {
        var reasons: [String] = []

        if signals.hrvTrend == .down { reasons.append("HRV below your norm") }
        if let c = checkin {
            if c.legs == .sore || c.legs == .heavy { reasons.append("your legs feel \(c.legs.rawValue)") }
            if c.energy == .low { reasons.append("you're low on energy") }
        }

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

        // Illness-watch (RECOVERY-HUB-PLAN §11.1.3) — the hard tier of the readiness modifiers, each
        // one ordinary warning sign here. Alone it's a quirk of the night; concordant with a second
        // signal it's the body fighting something, and the ease legitimately fires. Never a diagnosis.
        if let z = signals.respiratoryZ, z >= 2 { reasons.append("breathing rate above your norm") }
        if let delta = signals.wristTempDeltaC, delta >= 1.0 { reasons.append("running warm vs your normal") }

        guard reasons.count >= 2 else { return nil }
        return Decision(reason: reasons.joined(separator: " and "))
    }

    // MARK: Overtraining tripwire (§8.1) — load + physiology agreeing is a different animal

    /// The forced-cutback condition: training load already in the danger zone (ACWR beyond ~1.5) AND
    /// the body agreeing (HRV suppressed or resting HR elevated). Load alone can be a planned peak;
    /// physiology alone can be a bad night — together they're the classic overtraining signature.
    static func tripwire(acwr: Double, signals: RecoverySignals) -> Decision? {
        guard acwr > 1.5 else { return nil }
        var reasons = ["your training load has spiked (\(String(format: "%.1f", acwr))× your recent norm)"]
        if signals.hrvTrend == .down { reasons.append("HRV is suppressed") }
        if signals.restingHRTrend == .down { reasons.append("resting HR is elevated") }
        guard reasons.count >= 2 else { return nil }             // load must be corroborated by the body
        return Decision(reason: reasons.joined(separator: " and "))
    }

    /// Apply the tripwire: a real cutback (every upcoming session eased, the next one a true recovery
    /// day) via the same bounded path as every other adaptation — throttled to once a week so it can
    /// never spiral a plan downward.
    @MainActor
    @discardableResult
    static func applyCutback(_ decision: Decision, plan: TrainingPlan?, today: Date = Date(),
                             in context: ModelContext, calendar: Calendar = .current) -> (headline: String, detail: String)? {
        guard let plan else { return nil }
        if let last = plan.lastAdaptedAt,
           (calendar.dateComponents([.day], from: last, to: today).day ?? .max) < 7 { return nil }
        guard PlanCoaching.apply(.rest, to: plan, from: today, in: context, calendar: calendar) > 0 else { return nil }
        let note = (headline: "Cutback week",
                    detail: "We pulled this week back: \(decision.reason). Absorbing the work now is how you come back stronger — this is the plan working, not failing.")
        CoachingEvent.record(kind: .recover, headline: note.headline, detail: note.detail, on: today, in: context)
        try? context.save()
        return note
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
        // `.moved` is still today's open work (reconcileMissed rolls slipped days forward as .moved)
        // — a quality session must not dodge the recovery ease just because it slid here.
        guard let session = todays.first(where: {
            ($0.status == .planned || $0.status == .moved)
            && $0.completedWorkout == nil && $0.discipline == .running
            && ($0.runType?.isQuality == true || $0.runType == .long)
        }) else { return nil }

        let p5k = plan.p5kSPerKm
        session.runType = .easy
        session.intervals = nil
        session.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: p5k)
        if let d = session.targetDistanceM {
            session.targetDistanceM = RunRounding.snap(meters: d * 0.9, unit: PlanCoaching.displayUnit(in: context))
        }
        if let dur = session.targetDurationS { session.targetDurationS = (dur * 0.9).rounded() }
        session.rationale = "Eased today — \(decision.reason). The hard work lands better when you're recovered."

        let note = (headline: "Easy day instead",
                    detail: "Your body's asking for it: \(decision.reason). Today's session is easy running; your plan picks back up tomorrow.")
        CoachingEvent.record(kind: .ease, headline: note.headline, detail: note.detail, on: today, in: context)
        try? context.save()
        return note
    }
}
