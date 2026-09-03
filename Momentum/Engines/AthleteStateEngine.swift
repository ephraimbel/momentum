import Foundation

/// One logged run, flattened to the values the athlete-state derivation reads. Plain data, no
/// SwiftData: `PlanService.runEvidenceRows` builds these from `Workout`/`GPSDetail`, tests build
/// them by hand. Health never appears here (signals only, never workouts).
struct RunEvidenceRow: Sendable, Equatable {
    struct SplitRow: Sendable, Equatable {
        var distanceM: Double
        var durationS: Double
        var avgHR: Int?
    }

    var startedAt: Date
    var distanceM: Double
    var durationS: Double
    var avgHR: Int? = nil
    var splits: [SplitRow] = []
    /// Post-run RPE 1…10 when the athlete gave one.
    var rpe: Int? = nil
    /// The plan session this run was logged against, if any.
    var plannedRunType: RunType? = nil
    var plannedDistanceM: Double? = nil
    var planFit: PlanFit? = nil
    /// A race result: the planned race session, or a run the athlete marked as a race.
    var isRace: Bool = false

    var paceSPerKm: Double { durationS / max(0.001, distanceM / 1000) }
}

/// What the state derivation knows about the athlete beyond their runs: HR bounds for the
/// threshold band, and the times they typed in (onboarding benchmarks, self-reported).
struct AthleteStateProfile: Sendable, Equatable {
    var maxHR: Int? = nil
    var restingHR: Int? = nil
    /// Self-reported race/benchmark results: (distance, time).
    var benchmarks: [Benchmark] = []

    struct Benchmark: Sendable, Equatable {
        var distanceM: Double
        var timeS: Double
    }

    static let empty = AthleteStateProfile()
}

/// The long-run read the planner consumes: a three-way summary of `RunningDurability`, so the
/// engine reasons about "can this athlete absorb a longer long run" without re-deriving evidence.
enum DurabilitySignal: String, Sendable, Codable, Equatable, CaseIterable {
    /// Long runs faded late or were repeatedly cut short: hold the long run, spread the volume.
    case fragile
    /// Nothing says either way, or the evidence is mixed.
    case steady
    /// Every long run finished as intended and the late-run drift stayed flat: let it grow.
    case strong
}

/// Derives the athlete's state from their own logged runs (`docs/ELITE-RUNNING-SYSTEM.md` §3): the
/// performance curve with a personal Riegel exponent, a threshold proxy with its method, and a
/// durability read. Pure and deterministic; every value is an evidence envelope carrying source,
/// window, sample count, confidence and limitations, never a bare number.
///
/// What it deliberately does not do: no readiness score, no injury probability, no "economy", no
/// Health-derived training. A single exceptional run is a hypothesis, not an identity — most reads
/// need two comparable efforts before they reach moderate confidence.
enum AthleteStateEngine {
    /// Same window `PlanFitnessEvidence` uses for weekly volume: eight weeks of evidence.
    static let windowDays = 56
    static let populationRiegelExponent = 1.06
    static let riegelExponentBounds = 1.03...1.12

    // MARK: Entry point

    static func derive(runs: [RunEvidenceRow],
                       profile: AthleteStateProfile = .empty,
                       asOf: Date,
                       calendar: Calendar = .current) -> RunningAthleteState {
        let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: asOf) ?? .distantPast
        let window = DateInterval(start: cutoff, end: max(cutoff, asOf))
        let inWindow = runs
            .filter { $0.startedAt >= cutoff && $0.startedAt <= asOf && $0.distanceM > 0 && $0.durationS > 0 }
            .sorted { $0.startedAt < $1.startedAt }

        let curve = performanceCurve(runs: inWindow, benchmarks: profile.benchmarks,
                                     window: window, asOf: asOf)
        let threshold = thresholdProxy(runs: inWindow, curve: curve?.value, profile: profile,
                                       window: window, asOf: asOf)
        let durability = durability(runs: inWindow, window: window, asOf: asOf)
        let longest = inWindow.map(\.distanceM).max().map {
            RunningEvidence(value: $0, source: .momentumWorkout, observedAt: asOf, window: window,
                            sampleCount: inWindow.count, confidence: inWindow.count >= 3 ? .high : .low,
                            limitations: inWindow.count >= 3 ? [] : [.smallSample])
        }
        return RunningAthleteState(
            longestRecentRunM: longest,
            performanceCurve: curve,
            thresholdProxy: threshold,
            durability: durability
        )
    }

    // MARK: Planner read-outs

    /// The planner's three-way read of the durability evidence. Nil when there is nothing to say.
    static func durabilitySignal(_ evidence: RunningEvidence<RunningDurability>?) -> DurabilitySignal? {
        guard let evidence else { return nil }
        let d = evidence.value
        let completion = d.completionFraction
        if completion == nil, d.lateSessionResponse == .indeterminate { return nil }
        if (completion ?? 1) < 0.6 || d.lateSessionResponse == .declining { return .fragile }
        if let completion, completion >= 0.8,
           d.lateSessionResponse == .stable || d.lateSessionResponse == .improving { return .strong }
        return .steady
    }

    /// Fill the seed's state fields from the derived state. Only empty fields are filled: an
    /// explicit onboarding entry always outranks an estimate.
    static func seed(_ seed: CalibrationSeed, with state: RunningAthleteState) -> CalibrationSeed {
        var out = seed
        if out.thresholdSPerKm == nil,
           let t = state.thresholdProxy, t.confidence >= .low, let pace = t.value.paceSPerKm {
            out.thresholdSPerKm = pace
        }
        if out.riegelExponent == nil,
           let curve = state.performanceCurve, curve.confidence >= .moderate,
           let k = curve.value.riegelExponent {
            out.riegelExponent = k
        }
        if out.durability == nil {
            out.durability = durabilitySignal(state.durability)
        }
        return out
    }

    // MARK: Performance curve + personal Riegel exponent

    /// Race results and genuinely hard efforts, one best per distance band, plus the athlete's own
    /// typed benchmarks. Non-maximal efforts under-state fitness at short distances, so mixing a
    /// tempo with a race would bias the exponent upward; keeping only the fastest effort per band
    /// keeps the fit honest.
    static func performanceCurve(runs: [RunEvidenceRow],
                                 benchmarks: [AthleteStateProfile.Benchmark],
                                 window: DateInterval, asOf: Date)
        -> RunningEvidence<RunningPerformanceCurve>? {
        struct Effort { let distanceM: Double; let timeS: Double; let isRace: Bool; let selfReported: Bool }
        var efforts: [Effort] = []
        for run in runs where run.distanceM >= 1_500 {
            let hard = run.isRace || run.plannedRunType == .tempo
                || ((run.rpe ?? 0) >= 7 && !isEasyFamily(run.plannedRunType) && run.distanceM >= 3_000)
            guard hard else { continue }
            efforts.append(Effort(distanceM: run.distanceM, timeS: run.durationS,
                                  isRace: run.isRace, selfReported: false))
        }
        for b in benchmarks where b.distanceM >= 1_500 && b.timeS > 0 {
            efforts.append(Effort(distanceM: b.distanceM, timeS: b.timeS, isRace: true, selfReported: true))
        }
        guard !efforts.isEmpty else { return nil }

        // One best per band: the fastest pace is the most maximal effort at that distance.
        func band(_ d: Double) -> Int {
            switch d {
            case ..<6_000: 0
            case ..<12_000: 1
            case ..<25_000: 2
            default: 3
            }
        }
        var best: [Int: Effort] = [:]
        for e in efforts {
            let key = band(e.distanceM)
            let pace = e.timeS / (e.distanceM / 1000)
            if let cur = best[key], cur.timeS / (cur.distanceM / 1000) <= pace { continue }
            best[key] = e
        }
        let chosen = best.values.sorted { $0.distanceM < $1.distanceM }
        let points = chosen.map {
            RunningPerformancePoint(distanceM: $0.distanceM, durationS: $0.timeS,
                                    paceSPerKm: $0.timeS / ($0.distanceM / 1000))
        }
        let bounds = RunningValueRange(lower: chosen.map(\.timeS).min() ?? 0,
                                       upper: chosen.map(\.timeS).max() ?? 0)

        var limitations: Set<RunningEvidenceLimitation> = []
        if chosen.contains(where: \.selfReported) { limitations.insert(.selfReported) }
        let exponent = fitRiegelExponent(points)
        let raceCount = chosen.filter { $0.isRace && !$0.selfReported }.count
        let confidence: RunningEvidenceConfidence
        if exponent != nil, raceCount >= 2 { confidence = limitations.isEmpty ? .high : .moderate }
        else if exponent != nil, raceCount >= 1 { confidence = .moderate }
        else if exponent != nil { confidence = .low }
        else { confidence = .low; limitations.insert(.smallSample) }
        let source: RunningEvidenceSource = raceCount > 0 ? .raceResult
            : (chosen.allSatisfy(\.selfReported) ? .athleteEntry : .momentumWorkout)
        return RunningEvidence(
            value: RunningPerformanceCurve(points: points, observedDurationBoundsS: bounds,
                                           riegelExponent: exponent),
            source: source, observedAt: asOf, window: window,
            sampleCount: chosen.count, confidence: confidence, limitations: limitations
        )
    }

    /// Least squares on log(time) = a + k·log(distance). Needs two points at least 1.5× apart in
    /// distance; the result is bounded to the plausible range. Nil = not enough spread to say.
    static func fitRiegelExponent(_ points: [RunningPerformancePoint]) -> Double? {
        let usable = points.filter { $0.distanceM > 0 && $0.durationS > 0 }
        guard usable.count >= 2,
              let dMin = usable.map(\.distanceM).min(), let dMax = usable.map(\.distanceM).max(),
              dMax / dMin >= 1.5 else { return nil }
        let xs = usable.map { log($0.distanceM) }, ys = usable.map { log($0.durationS) }
        let n = Double(usable.count)
        let xMean = xs.reduce(0, +) / n, yMean = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in xs.indices {
            num += (xs[i] - xMean) * (ys[i] - yMean)
            den += (xs[i] - xMean) * (xs[i] - xMean)
        }
        guard den > 0 else { return nil }
        let k = num / den
        guard k.isFinite else { return nil }
        return min(riegelExponentBounds.upperBound, max(riegelExponentBounds.lowerBound, k))
    }

    // MARK: Threshold proxy

    /// Daniels' T is the intensity an athlete can race for about an hour. First available wins:
    /// a race of that length says it outright; a race of another length is moved along the
    /// athlete's own curve; a sustained block at threshold heart rate says it from the inside;
    /// a completed steady session says it from the plan. Each carries its method and confidence.
    static func thresholdProxy(runs: [RunEvidenceRow], curve: RunningPerformanceCurve?,
                               profile: AthleteStateProfile,
                               window: DateInterval, asOf: Date)
        -> RunningEvidence<RunningThresholdProxy>? {
        let k = curve?.riegelExponent ?? populationRiegelExponent

        // 1. Race results (and all-out efforts) by duration.
        let hardEfforts = runs.filter {
            $0.isRace || ((($0.rpe ?? 0) >= 8) && !isEasyFamily($0.plannedRunType) && $0.distanceM >= 3_000)
        }
        if let best = hardEfforts
            .filter({ $0.durationS >= 20 * 60 && $0.durationS <= 120 * 60 })
            .min(by: { abs($0.durationS - 3600) < abs($1.durationS - 3600) }) {
            let direct = best.durationS >= 45 * 60 && best.durationS <= 75 * 60
            let pace: Double
            if direct {
                pace = best.paceSPerKm
            } else {
                // Move the effort to the one-hour distance along the athlete's curve:
                // t = t1 · (d/d1)^k  ⇒  d60 = d1 · (3600/t1)^(1/k).
                let d60 = best.distanceM * pow(3600 / best.durationS, 1 / k)
                pace = 3600 / max(0.001, d60 / 1000)
            }
            let confidence: RunningEvidenceConfidence = direct && best.isRace ? .high : .moderate
            var limitations: Set<RunningEvidenceLimitation> = []
            if !direct { limitations.insert(.outsideObservedDuration) }
            if !best.isRace { limitations.insert(.selfReported) }
            return RunningEvidence(
                value: RunningThresholdProxy(paceSPerKm: pace.rounded(), heartRateBPM: best.avgHR.map(Double.init),
                                             method: .raceResult),
                source: best.isRace ? .raceResult : .momentumWorkout, observedAt: best.startedAt,
                window: window, sampleCount: 1,
                confidence: limitations.isEmpty ? confidence : min(confidence, .moderate),
                limitations: limitations
            )
        }

        // 2. A sustained block at threshold heart rate.
        if let maxHR = profile.maxHR, maxHR > 100 {
            let blocks = runs.compactMap { thresholdBlock(in: $0, maxHR: maxHR, restingHR: profile.restingHR) }
            if !blocks.isEmpty {
                let recent = Array(blocks.suffix(3))
                let paces = recent.map(\.paceSPerKm).sorted()
                let median = paces[paces.count / 2]
                let hr = recent.map(\.avgHR).reduce(0, +) / Double(recent.count)
                let poor = recent.contains(where: \.poorGPS)
                return RunningEvidence(
                    value: RunningThresholdProxy(paceSPerKm: median.rounded(), heartRateBPM: hr.rounded(),
                                                 method: .workoutEstimate),
                    source: .momentumWorkout, observedAt: recent.last?.at ?? asOf, window: window,
                    sampleCount: recent.count, confidence: poor ? .low : .moderate,
                    limitations: poor ? [.poorGPS] : []
                )
            }
        }

        // 3. Completed steady (tempo) sessions from the plan.
        let tempos = runs.filter { $0.plannedRunType == .tempo && $0.durationS >= 15 * 60 }
            .filter { $0.rpe == nil || (6...8).contains($0.rpe!) }
        if tempos.count >= 2 {
            let paces = tempos.map(\.paceSPerKm).sorted()
            let median = paces.count.isMultiple(of: 2)
                ? (paces[paces.count / 2 - 1] + paces[paces.count / 2]) / 2
                : paces[paces.count / 2]
            let missingRPE = tempos.contains { $0.rpe == nil }
            let hrs = tempos.compactMap(\.avgHR)
            return RunningEvidence(
                value: RunningThresholdProxy(paceSPerKm: median.rounded(),
                                             heartRateBPM: hrs.isEmpty ? nil : Double(hrs.reduce(0, +)) / Double(hrs.count),
                                             method: .workoutEstimate),
                source: .momentumWorkout, observedAt: tempos.last?.startedAt ?? asOf, window: window,
                sampleCount: tempos.count, confidence: missingRPE ? .low : .moderate,
                limitations: missingRPE ? [.missingRPE] : []
            )
        }
        return nil
    }

    private struct ThresholdBlock {
        let paceSPerKm: Double
        let avgHR: Double
        let at: Date
        let poorGPS: Bool
    }

    /// The longest contiguous run of splits at threshold heart rate (86–92 % of heart-rate reserve
    /// when a resting HR is known, else of max), if it lasts twenty minutes or more.
    private static func thresholdBlock(in run: RunEvidenceRow, maxHR: Int, restingHR: Int?) -> ThresholdBlock? {
        guard run.durationS >= 25 * 60, run.splits.count >= 2 else { return nil }
        let rest = restingHR.flatMap { $0 > 25 && $0 < maxHR ? Double($0) : nil }
        func hr(atFraction f: Double) -> Double {
            if let rest { return rest + f * (Double(maxHR) - rest) }
            return f * Double(maxHR)
        }
        let lo = hr(atFraction: 0.86), hi = hr(atFraction: 0.92)
        var bestRange: Range<Int>?
        var start: Int?
        for (i, split) in run.splits.enumerated() {
            let inBand = split.avgHR.map { Double($0) >= lo && Double($0) <= hi && split.durationS > 0 } ?? false
            if inBand {
                if start == nil { start = i }
            } else if let s = start {
                let r = s..<i
                if bestRange.map({ duration(run.splits[$0]) < duration(run.splits[r]) }) ?? true { bestRange = r }
                start = nil
            }
        }
        if let s = start {
            let r = s..<run.splits.count
            if bestRange.map({ duration(run.splits[$0]) < duration(run.splits[r]) }) ?? true { bestRange = r }
        }
        guard let r = bestRange else { return nil }
        let block = Array(run.splits[r])
        let dur = duration(block), dist = block.reduce(0.0) { $0 + $1.distanceM }
        guard dur >= 20 * 60, dist > 0 else { return nil }
        let pace = dur / (dist / 1000)
        let hrMean = Double(block.compactMap(\.avgHR).reduce(0, +)) / Double(max(1, block.count))
        let poor = block.contains { let p = $0.durationS / max(0.001, $0.distanceM / 1000); return p < 120 || p > 900 }
        return ThresholdBlock(paceSPerKm: pace, avgHR: hrMean, at: run.startedAt, poorGPS: poor)
    }

    private static func duration(_ splits: ArraySlice<RunEvidenceRow.SplitRow>) -> Double {
        splits.reduce(0.0) { $0 + $1.durationS }
    }
    private static func duration(_ splits: [RunEvidenceRow.SplitRow]) -> Double {
        splits.reduce(0.0) { $0 + $1.durationS }
    }

    // MARK: Durability

    /// How the athlete holds up late in long runs: the longest continuous effort, how often the
    /// planned long run was finished as intended, and whether pace-for-heart-rate drifts in the
    /// last third. Drift is the honest field read of durability; without heart rate it is
    /// indeterminate and only completion carries weight.
    static func durability(runs: [RunEvidenceRow], window: DateInterval, asOf: Date)
        -> RunningEvidence<RunningDurability>? {
        guard let longestS = runs.map(\.durationS).max(), longestS > 0 else { return nil }

        let plannedLong = runs.filter { $0.plannedRunType == .long && ($0.plannedDistanceM ?? 0) > 0 }
        var completion: Double?
        if plannedLong.count >= 2 {
            let done = plannedLong.filter {
                $0.distanceM >= 0.9 * ($0.plannedDistanceM ?? 0) && $0.planFit != .harder && ($0.rpe ?? 0) <= 7
            }.count
            completion = Double(done) / Double(plannedLong.count)
        }

        let drifts: [Double] = runs
            .filter { $0.durationS >= 3600 && $0.splits.count >= 6 && !isQualityFamily($0.plannedRunType) }
            .compactMap(cardiacDrift)
        let response: RunningTrendDirection
        if drifts.isEmpty {
            response = .indeterminate
        } else {
            let mean = drifts.reduce(0, +) / Double(drifts.count)
            if drifts.count >= 3 {
                let half = drifts.count / 2
                let early = drifts.prefix(half).reduce(0, +) / Double(half)
                let late = drifts.suffix(drifts.count - half).reduce(0, +) / Double(drifts.count - half)
                if late <= early - 0.02, late < 0.05 { response = .improving }
                else { response = mean >= 0.08 ? .declining : .stable }
            } else {
                response = mean >= 0.08 ? .declining : .stable
            }
        }

        var limitations: Set<RunningEvidenceLimitation> = []
        if drifts.isEmpty { limitations.insert(.missingEnvironment) }
        if completion == nil { limitations.insert(.smallSample) }
        let samples = max(plannedLong.count, drifts.count, 1)
        let confidence: RunningEvidenceConfidence = (completion != nil && !drifts.isEmpty) ? .high
            : (completion != nil || !drifts.isEmpty) ? .moderate : .low
        return RunningEvidence(
            value: RunningDurability(observedDurationS: longestS, completionFraction: completion,
                                     lateSessionResponse: response),
            source: .momentumWorkout, observedAt: asOf, window: window, sampleCount: samples,
            confidence: limitations.isEmpty ? confidence : min(confidence, .moderate),
            limitations: limitations
        )
    }

    /// Pace-for-heart-rate decoupling: speed per beat in the first third of the run versus the
    /// last third. Positive = the same pace cost more late. Nil without heart rate on both ends.
    static func cardiacDrift(_ run: RunEvidenceRow) -> Double? {
        let n = run.splits.count
        guard n >= 6 else { return nil }
        let third = n / 3
        func efficiency(_ slice: ArraySlice<RunEvidenceRow.SplitRow>) -> Double? {
            let withHR = slice.filter { ($0.avgHR ?? 0) > 60 && $0.durationS > 0 && $0.distanceM > 0 }
            guard withHR.count >= max(1, slice.count / 2) else { return nil }
            let dist = withHR.reduce(0.0) { $0 + $1.distanceM }
            let dur = withHR.reduce(0.0) { $0 + $1.durationS }
            let hr = Double(withHR.compactMap(\.avgHR).reduce(0, +)) / Double(withHR.count)
            guard dur > 0, hr > 0 else { return nil }
            return (dist / dur) / hr
        }
        guard let first = efficiency(run.splits[0..<third]),
              let last = efficiency(run.splits[(n - third)..<n]), first > 0 else { return nil }
        return (first - last) / first
    }

    // MARK: Helpers

    private static func isEasyFamily(_ type: RunType?) -> Bool {
        guard let type else { return false }
        return [.easy, .long, .recovery, .freeRun].contains(type)
    }

    private static func isQualityFamily(_ type: RunType?) -> Bool {
        guard let type else { return false }
        return [.tempo, .intervals, .race, .fartlek, .hills, .strides].contains(type)
    }
}
