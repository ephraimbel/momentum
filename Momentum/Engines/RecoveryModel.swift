import Foundation

/// Deterministic recovery / readiness (PRD §4.8, §16 "recovery-model depth" — shipped rules-only).
/// Builds on the ACWR (`ProgressInsights`) with two more sports-science signals from Foster's work:
/// **monotony** (mean daily load ÷ its standard deviation — how *samey* the week is) and **strain**
/// (weekly load × monotony). A readiness score (0–100) combines recent-to-usual load change,
/// monotony, and lack of rest into a glanceable training-context band. It is not an injury model or
/// a physiological diagnosis. The AI narrates it; this type only computes.
@MainActor
struct RecoveryModel {
    enum Readiness: String, Sendable {
        case primed = "Low strain"
        case ready = "Steady"
        case moderate = "Moderate"
        case strained = "High strain"
        case depleted = "Very high"
    }

    let score: Int            // 0–100 context index; higher = fewer load-pattern cautions
    let readiness: Readiness
    let monotony: Double      // 7-day mean daily load ÷ SD; >2 is a grind
    let strain: Double        // weekly load × monotony
    let acwr: Double
    let weeklyLoad: Double
    let restDays: Int         // zero-load days in the last 7
    let hasData: Bool

    init(workouts: [Workout], now: Date = Date(), calendar: Calendar = .current) {
        // Daily load over the last 7 days (today inclusive), rest days counted as zero.
        var daily = [Double](repeating: 0, count: 7)
        let today = calendar.startOfDay(for: now)
        for w in workouts {
            let day = calendar.startOfDay(for: w.startedAt)
            if let idx = calendar.dateComponents([.day], from: day, to: today).day, idx >= 0, idx < 7 {
                daily[idx] += TrainingLoad.session(w)
            }
        }
        let weekly = daily.reduce(0, +)
        weeklyLoad = weekly
        restDays = daily.filter { $0 == 0 }.count

        let mean = weekly / 7
        let variance = daily.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 7
        let sd = variance.squareRoot()
        // All-same nonzero days ⇒ maximal monotony; no load ⇒ none.
        monotony = sd > 0.0001 ? mean / sd : (mean > 0 ? 2.5 : 0)
        strain = weekly * monotony

        let insights = ProgressInsights(workouts: workouts, now: now, calendar: calendar)
        acwr = insights.acwr
        hasData = insights.chronic >= 1   // need ~a month of history to judge readiness

        guard hasData else { score = 0; readiness = .moderate; return }

        var s = 100.0
        // Recent-to-usual change — a conservative load-pattern input, not an injury predictor.
        switch acwr {
        case ..<1.3:    break
        case 1.3..<1.5: s -= 15
        case 1.5..<1.8: s -= 35
        default:        s -= 55
        }
        // Monotony — repeated similar daily load increases this model's accumulated-strain signal.
        switch monotony {
        case ..<1.5:    break
        case 1.5..<2.0: s -= 10
        default:        s -= 25
        }
        // No easy day at all in the last week.
        if restDays == 0 { s -= 15 }

        score = Int(max(0, min(100, s)).rounded())
        readiness = Self.band(score)
    }

    static func band(_ score: Int) -> Readiness {
        switch score {
        case 80...:  .primed
        case 65..<80: .ready
        case 45..<65: .moderate
        case 25..<45: .strained
        default:      .depleted
        }
    }

    /// One-line, no-shame guidance for the band — what to do today.
    var guidance: String { Self.guidance(readiness) }

    /// Guidance for an arbitrary band — used when a device-blended readiness re-bands the score
    /// (`RecoverySignals.blendedReadiness`) so the copy matches the blended, not the load-only, level.
    static func guidance(_ band: Readiness) -> String {
        switch band {
        case .primed:   "Your recent pattern leaves recovery margin. Follow the plan, and let how you feel lead."
        case .ready:    "Your recent pattern is steady. Follow the plan and keep the effort honest."
        case .moderate: "The context is mixed — keep today honest, not heroic."
        case .strained: "Recent strain is elevated. Favor easy or technique work and check how you feel."
        case .depleted: "Recent strain is much higher. Consider easy running or rest, especially with fatigue, pain, or illness."
        }
    }
}
