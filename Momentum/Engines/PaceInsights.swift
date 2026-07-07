import Foundation
import SwiftData

/// Pace Insights (running-excellence R4) — a read of how the athlete's *quality* sessions are landing
/// against their prescribed paces, surfaced as a calm, no-shame verdict (Runna's "Pace Insight" idea,
/// our phrasing + values). The plan already auto-sharpens paces from strong runs
/// (`PlanCoaching.recalibratePaces`); this makes that legible and adds the one signal auto-recalibration
/// deliberately never gives — "your targets may be a touch hot" (it only ever speeds you up, no-shame).
///
/// The classifier is pure + deterministic + testable; a thin `@MainActor` adapter gathers the runs.
enum PaceInsights {
    /// One completed quality session's prescribed vs achieved average pace (s/km).
    struct QualityRun: Sendable, Equatable {
        let targetPaceSPerKm: Double
        let achievedPaceSPerKm: Double
        /// Signed delta: negative = ran *faster* than the target (lower s/km).
        var deltaSPerKm: Double { achievedPaceSPerKm - targetPaceSPerKm }
    }

    enum Verdict: String, Sendable, Equatable { case monitoring, onPoint, ahead, review, variable }

    struct Result: Sendable, Equatable {
        let verdict: Verdict
        let headline: String
        let detail: String
    }

    /// On-pace band half-width, and the delta spread above which pacing reads as inconsistent (s/km).
    static let toleranceSPerKm = 8.0
    static let variableSpreadSPerKm = 30.0

    /// Classify recent quality runs. Needs ≥ 2 valid runs to say anything; otherwise "monitoring".
    static func evaluate(_ runs: [QualityRun]) -> Result {
        let valid = runs.filter { $0.targetPaceSPerKm > 0 && $0.achievedPaceSPerKm > 0 }
        guard valid.count >= 2 else {
            return Result(verdict: .monitoring, headline: "Gathering pace data",
                          detail: "Log a couple of quality sessions and I'll read how your pacing's landing.")
        }
        let deltas = valid.map(\.deltaSPerKm)
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let spread = (deltas.max() ?? 0) - (deltas.min() ?? 0)

        if spread > variableSpreadSPerKm {
            return Result(verdict: .variable, headline: "Mixed pacing",
                          detail: "Your quality splits are swinging run to run — settling into an even effort will unlock these sessions.")
        }
        if mean < -toleranceSPerKm {
            return Result(verdict: .ahead, headline: "Ahead of your targets",
                          detail: "You're running quality sessions faster than prescribed — fitness is climbing, and your paces are keeping up.")
        }
        if mean > toleranceSPerKm {
            return Result(verdict: .review, headline: "Targets running a touch hot",
                          detail: "Your quality paces are landing a little slower than target — no worries; we can ease them so the work stays honest.")
        }
        return Result(verdict: .onPoint, headline: "Dialed in",
                      detail: "Your quality runs are landing right on their targets. Textbook execution.")
    }

    /// Gather the athlete's recent completed quality runs (tempo / intervals / race) that carried a
    /// prescribed pace and produced a GPS result — most-recent first, capped. SwiftData read only; the
    /// classifier above stays pure.
    @MainActor
    static func recentQualityRuns(_ plan: TrainingPlan?, limit: Int = 6) -> [QualityRun] {
        guard let plan else { return [] }
        let quality: Set<RunType> = [.tempo, .intervals, .race]
        var collected: [(date: Date, run: QualityRun)] = []
        for s in plan.sessions {
            guard s.status == .completed, let rt = s.runType, quality.contains(rt) else { continue }
            guard let target = s.targetPaceSPerKm, target > 0,
                  let w = s.completedWorkout, let gps = w.gps,
                  gps.distanceM > 0, w.durationS > 0 else { continue }
            let achieved = w.durationS / (gps.distanceM / 1000.0)
            collected.append((w.startedAt, QualityRun(targetPaceSPerKm: target, achievedPaceSPerKm: achieved)))
        }
        collected.sort { $0.date > $1.date }
        return collected.prefix(limit).map(\.run)
    }
}
