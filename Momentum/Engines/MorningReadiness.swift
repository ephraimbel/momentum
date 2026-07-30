import Foundation

/// The morning headline number (Recovery Hub plan §4.2) — one honest 0–100 readiness score that
/// blends the load-derived `RecoveryModel.score` with the body's overnight signals (HRV, sleep,
/// resting HR) and the athlete's own check-in. Each input is a **pillar** with a fixed raw weight,
/// renormalized over whichever pillars are actually present — that renormalization IS the
/// missing-signal degradation: a watch-less athlete still gets a real number, just at lower
/// confidence, never a fake one. Sparse Apple-only vitals (respiratory rate, wrist temperature)
/// never earn pillar status; they land as bounded post-blend **modifiers**. Banding and guidance
/// reuse `RecoveryModel` — one banding function app-wide, so Today and the hub can never disagree.
/// Deterministic and fixture-tested (PRD §9 — rules compute, AI narrates). No medical claims.
@MainActor
struct MorningReadiness {

    // MARK: Output shape

    enum PillarKind: String, Sendable, CaseIterable {
        case load        // RecoveryModel.score — how the last weeks of training sit in the body
        case hrv         // overnight HRV vs the athlete's own norm
        case sleep       // last night vs need, plus capped 14-day debt
        case restingHR   // overnight resting HR vs norm (inverted — elevated reads worse)
        case checkin     // the athlete's own words: energy + legs
    }

    /// One contributor to the blend. `weight` is the renormalized share (present-pillar weights
    /// always sum to 1), so the signed `points` sum exactly to `blend − 50` — the DriverRow's math.
    struct Pillar: Sendable, Equatable {
        let kind: PillarKind
        let score: Double        // 0–100, clamped
        let weight: Double       // renormalized over present pillars
        var points: Double { weight * (score - 50) }
    }

    /// A bounded post-blend deduction from the illness-watch vitals. Absent signals and unlearned
    /// baselines both arrive as `nil` (`RecoverySignals` encodes the ≥7-day banding rule upstream)
    /// and are silently zero — a deviation penalty against an unlearned norm is exactly the false
    /// alarm this prevents.
    struct Modifier: Sendable, Equatable {
        enum Kind: String, Sendable { case respiratory, wristTemperature }
        let kind: Kind
        let points: Double       // −5 or −10
    }

    /// How much signal built the number — by present-pillar count (5 / 4 / 3 / ≤2). Renders in the
    /// hero card's partial-data footnote; never blocks a score.
    enum Confidence: String, Sendable { case high, medium, low, minimal }

    let score: Int                       // 0–100, post-modifier, clamped
    let band: RecoveryModel.Readiness    // via RecoveryModel.band — cuts 25/45/65/80
    let pillars: [Pillar]                // fixed order load → check-in; DriverRow sorts by |points|
    let modifiers: [Modifier]
    let modifierPoints: Double           // the floored total actually applied (never below −15)
    let blend: Double                    // pre-modifier weighted blend, unrounded
    let confidence: Confidence

    /// One-line, no-shame guidance — the shared band copy, so the hub and Today read identically.
    var guidance: String { RecoveryModel.guidance(band) }

    /// Raw pillar weights (sum to 1 when all five report). Load leads — it's the plan's own
    /// signal — then HRV as the most direct autonomic-recovery read.
    private enum RawWeight {
        static let load = 0.30, hrv = 0.25, sleep = 0.20, restingHR = 0.15, checkin = 0.10
    }

    // MARK: Compute

    /// Builds the morning score from whatever is present, or `nil` when nothing is — the
    /// "learning you" state, never a fake number. Load contributes only once `hasData` (~a month
    /// of history); HRV / resting HR prefer a banded `HealthBaselines` z-score and fall back to
    /// the coarse `RecoverySignals` trend cuts; sleep need and 14-day debt come from the sleep
    /// engine (defaults: 8 h need, no debt).
    init?(load: RecoveryModel? = nil,
          signals: RecoverySignals = .empty,
          hrvBaseline: HealthBaselines.Baseline? = nil,
          restingHRBaseline: HealthBaselines.Baseline? = nil,
          sleepNeedH: Double = 8.0,
          sleepDebt14H: Double = 0,
          checkin: DailyCheckin? = nil) {
        var present: [(kind: PillarKind, score: Double, rawWeight: Double)] = []

        // Load — RecoveryModel.score verbatim, present only once there's enough history to judge.
        if let load, load.hasData {
            present.append((kind: .load, score: Double(load.score), rawWeight: RawWeight.load))
        }

        // HRV — higher than your norm = better recovered. The banded z-path maps ±2.5 SD onto the
        // full 0–100; the coarse ratio fallback matches `hrvTrend`'s cuts.
        if let hrv = signals.hrvMs {
            if let b = hrvBaseline, b.isBanded {
                let z = min(max(b.z(hrv), -2.5), 2.5)
                present.append((kind: .hrv, score: Self.clamped(50 + 20 * z), rawWeight: RawWeight.hrv))
            } else if let base = signals.hrvBaselineMs, base > 0 {
                let s: Double = switch hrv / base {
                case 1.05...:     75
                case 0.92..<1.05: 55
                case 0.82..<0.92: 30
                default:          10
                }
                present.append((kind: .hrv, score: s, rawWeight: RawWeight.hrv))
            }
        }

        // Sleep — 25 pts per hour short of need, plus 2.5 pts per debt-hour (capped at 12 h so
        // stale debt can't drown a good night). Oversleeping is not a bonus; the clamp holds 100.
        if let night = signals.sleepHours {
            let s = 100 - 25 * max(0, sleepNeedH - night) - 2.5 * min(max(sleepDebt14H, 0), 12)
            present.append((kind: .sleep, score: Self.clamped(s), rawWeight: RawWeight.sleep))
        }

        // Resting HR — the z-axis inverts (an elevated overnight resting HR is the classic
        // under-recovered sign); the Δ fallback matches `restingHRTrend`'s cuts, plus a
        // genuinely-below-norm reward tier.
        if let rhr = signals.restingHR {
            if let b = restingHRBaseline, b.isBanded {
                let z = min(max(b.z(Double(rhr)), -2.5), 2.5)
                present.append((kind: .restingHR, score: Self.clamped(50 - 20 * z), rawWeight: RawWeight.restingHR))
            } else if let base = signals.restingHRBaseline, base > 0 {
                let s: Double = switch Double(rhr) - base {
                case ...(-2): 75
                case ..<1:    60
                case ..<4:    40
                default:      15
                }
                present.append((kind: .restingHR, score: s, rawWeight: RawWeight.restingHR))
            }
        }

        // Check-in — what the athlete says stands equal to what the wearable measured.
        if let c = checkin {
            let energy: Double = switch c.energy { case .low: -25; case .ok: 0; case .full: 20 }
            let legs: Double = switch c.legs { case .fresh: 20; case .ok: 0; case .heavy: -20; case .sore: -35 }
            present.append((kind: .checkin, score: Self.clamped(60 + energy + legs), rawWeight: RawWeight.checkin))
        }

        // Zero pillars → nil: the hub renders "learning you", never a fake number — and modifiers
        // alone can never invent a score.
        guard !present.isEmpty else { return nil }

        // Renormalize the raw weights over what's actually present. Weights sum to 1, so a single
        // clamped pillar can move the blend by at most its weight × 100 — with all five reporting
        // that's 30 points, the invariant the fixtures pin.
        let totalWeight = present.reduce(0) { $0 + $1.rawWeight }
        pillars = present.map { Pillar(kind: $0.kind, score: $0.score, weight: $0.rawWeight / totalWeight) }
        blend = pillars.reduce(0) { $0 + $1.weight * $1.score }

        // Illness-watch modifiers — post-blend, deviations against a learned norm only.
        var mods: [Modifier] = []
        if let z = signals.respiratoryZ {
            if z >= 2 { mods.append(Modifier(kind: .respiratory, points: -10)) }
            else if z >= 1 { mods.append(Modifier(kind: .respiratory, points: -5)) }
        }
        if let delta = signals.wristTempDeltaC {
            if delta >= 1.0 { mods.append(Modifier(kind: .wristTemperature, points: -10)) }
            else if delta >= 0.5 { mods.append(Modifier(kind: .wristTemperature, points: -5)) }
        }
        modifiers = mods
        // Combined floor: both firing hard reads −15, not −20 — corroborating body signals cap,
        // they don't stack without bound.
        modifierPoints = max(mods.reduce(0) { $0 + $1.points }, -15)

        score = Int(min(max(blend + modifierPoints, 0), 100).rounded())
        band = RecoveryModel.band(score)
        confidence = switch pillars.count {
        case 5:  .high
        case 4:  .medium
        case 3:  .low
        default: .minimal
        }
    }

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 100) }
}
