import Foundation

/// Physiological recovery signals read from Apple Health — the numbers wearables (Apple Watch,
/// Garmin, Oura, Whoop) all write there: **heart-rate variability (HRV/SDNN)**, **resting heart
/// rate**, and **last night's sleep**. Each is paired with the athlete's own recent baseline so the
/// value reads against *their* norm, not a population number (the Oura/Garmin convention).
///
/// Deterministic and testable (PRD §9 — rules compute, AI narrates). No medical claims: these adjust
/// a readiness score and surface plain-language anchors; they never diagnose.
struct RecoverySignals: Sendable, Equatable {
    var hrvMs: Double? = nil            // last night's HRV (SDNN), milliseconds
    var hrvBaselineMs: Double? = nil    // ~30-day average HRV
    var restingHR: Int? = nil           // most recent resting HR, bpm
    var restingHRBaseline: Double? = nil// ~30-day average resting HR
    var sleepHours: Double? = nil       // last night's asleep duration, hours

    // Illness-watch deviations (RECOVERY-HUB-PLAN §11.1.3) — sparse, Apple-only signals that read
    // exclusively against a learned personal baseline. `nil` until that baseline is banded (≥7 days
    // of history): a deviation penalty against an unlearned norm is exactly the false alarm this
    // guards against. Consumed by `MorningReadiness` modifiers and `RecoveryAdaptation.decide`.
    var respiratoryZ: Double? = nil     // overnight respiratory rate, z-score vs personal baseline
    var wristTempDeltaC: Double? = nil  // overnight wrist temperature, °C above personal baseline

    static let empty = RecoverySignals()

    /// True once at least one physiological signal is available — gates the device-backed card layout.
    var hasPhysio: Bool { hrvMs != nil || restingHR != nil || sleepHours != nil }

    // MARK: Plain-language anchors (value vs the athlete's own baseline)

    enum Trend: String, Sendable { case up, steady, down }

    /// HRV vs baseline — higher HRV = better recovered.
    var hrvTrend: Trend? {
        guard let hrv = hrvMs, let b = hrvBaselineMs, b > 0 else { return nil }
        switch hrv / b {
        case 1.05...:      return .up
        case 0.92..<1.05:  return .steady
        default:           return .down
        }
    }
    var hrvNote: String? {
        switch hrvTrend {
        case .up:     return "above your norm"
        case .steady: return "on par"
        case .down:   return "below your norm"
        case nil:     return hrvMs != nil ? "learning your norm" : nil
        }
    }

    /// Resting HR vs baseline — an elevated resting HR is the classic under-recovered / incoming-illness
    /// signal, so "up" reads as a caution here (the opposite polarity to HRV).
    var restingHRTrend: Trend? {
        guard let rhr = restingHR, let b = restingHRBaseline, b > 0 else { return nil }
        switch Double(rhr) - b {
        case ..<1:    return .steady
        case 1..<4:   return .up
        default:      return .down   // .down == "well up" caution; kept distinct for the note
        }
    }
    var restingHRNote: String? {
        switch restingHRTrend {
        case .steady: return "steady"
        case .up:     return "slightly up"
        case .down:   return "elevated"
        case nil:     return restingHR != nil ? "learning your norm" : nil
        }
    }

    var sleepNote: String? {
        guard let s = sleepHours else { return nil }
        switch s {
        case 7.5...:  return "solid"
        case 6..<7.5: return "moderate"
        case 5..<6:   return "short"
        default:      return "very short"
        }
    }

    // MARK: Display

    var hrvValue: String? { hrvMs.map { "\(Int($0.rounded()))" } }
    var restingHRValue: String? { restingHR.map { "\($0)" } }
    var sleepValue: String? {
        guard let s = sleepHours else { return nil }
        let h = Int(s), m = Int((s - Double(h)) * 60)
        return "\(h)h \(String(format: "%02d", m))m"
    }

    // MARK: Readiness blend

    /// Blends the load-derived readiness (0–100) with the physiological signals. HRV dominates (it's
    /// the most direct autonomic-recovery read), then an elevated resting HR, then short sleep. Bounded
    /// and clamped so a single noisy sample can't swing the score wildly. Returns the base unchanged
    /// when no device data is present.
    func blendedReadiness(base: Int) -> Int {
        guard hasPhysio else { return base }
        var score = Double(base)

        if let hrv = hrvMs, let b = hrvBaselineMs, b > 0 {
            switch hrv / b {
            case 1.05...:      score += 8
            case 0.92..<1.05:  break
            case 0.82..<0.92:  score -= 12
            default:           score -= 22
            }
        }
        if let rhr = restingHR, let b = restingHRBaseline, b > 0 {
            switch Double(rhr) - b {
            case ..<1:   break
            case 1..<4:  score -= 8
            default:     score -= 16
            }
        }
        if let sleep = sleepHours {
            switch sleep {
            case 7.5...:  score += 5
            case 6..<7.5: break
            case 5..<6:   score -= 10
            default:      score -= 18
            }
        }
        return Int(max(0, min(100, score)).rounded())
    }

    #if DEBUG
    /// Canned signals for sim verification (no physical wearable needed) — launched via
    /// `--health-recovery-demo`. A well-rested morning: HRV a touch above norm, resting HR steady,
    /// a solid night, breathing and wrist temp comfortably in band. Each value is this morning's
    /// point in `HealthService.demoDailyHistory`/`demoSleepNights`, so the hero, the vitals tiles,
    /// and the history charts tell one story on the sim.
    static let demo = RecoverySignals(hrvMs: 68, hrvBaselineMs: 63, restingHR: 52,
                                      restingHRBaseline: 51.6, sleepHours: 7.33,
                                      respiratoryZ: 0.5, wristTempDeltaC: 0.05)

    /// A plausible strained morning — launched via `--health-recovery-strained`. HRV well below
    /// norm, resting HR elevated, a short night, breathing and wrist temp both above baseline:
    /// the concordant picture that should ease today's session. As with `demo`, each value is the
    /// endpoint of the matching `HealthService` demo history, so the strained trend charts land here.
    static let demoStrained = RecoverySignals(hrvMs: 46, hrvBaselineMs: 62, restingHR: 55,
                                              restingHRBaseline: 49, sleepHours: 5.4,
                                              respiratoryZ: 2.1, wristTempDeltaC: 0.6)

    /// The best morning the model can describe — launched via `--health-recovery-primed` for the
    /// marketing capture of a 100 readiness (the one state that earns the iridescent ring). HRV
    /// well above norm, resting HR under it, a full night, breathing and temperature dead on band.
    static let demoPrimed = RecoverySignals(hrvMs: 84, hrvBaselineMs: 63, restingHR: 47,
                                            restingHRBaseline: 51.6, sleepHours: 8.6,
                                            respiratoryZ: 0.0, wristTempDeltaC: 0.0)
    #endif
}
