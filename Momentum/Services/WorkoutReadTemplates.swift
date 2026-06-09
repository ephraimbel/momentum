import Foundation

/// The post-workout AI read payload (PRD §8.8). `narrative` ≤ 55 words, second person, specific,
/// plan-aware, no medical claims.
struct WorkoutRead: Sendable, Equatable {
    struct Insight: Sendable, Equatable { let label: String; let value: String; let note: String }
    var narrative: String
    var insights: [Insight]
    var planAdjustment: String?
}

/// Deterministic per-discipline reads (PRD §8.8 fallback). These render instantly so the moment
/// never blocks; the server LLM, when configured, can replace `narrative` with a richer one.
enum WorkoutReadTemplates {

    static func read(for workout: Workout, planned: Bool, weightUnit: WeightUnit = .default(),
                     distanceUnit: DistanceUnit = .auto) -> WorkoutRead {
        let read = workout.type == .strength
            ? strength(workout, weightUnit: weightUnit, planned: planned)
            : cardio(workout, distanceUnit: distanceUnit, planned: planned)
        return WorkoutRead(narrative: sanitize(read.narrative), insights: read.insights,
                           planAdjustment: read.planAdjustment)
    }

    // MARK: Strength

    private static func strength(_ workout: Workout, weightUnit: WeightUnit, planned: Bool) -> WorkoutRead {
        guard let session = workout.strength else {
            return WorkoutRead(narrative: "Session saved. Keep stacking days.", insights: [], planAdjustment: nil)
        }
        let volume = weightUnit == .lb ? session.totalVolumeKg * Formatters.lbPerKg : session.totalVolumeKg
        let unit = weightUnit == .lb ? "lb" : "kg"

        // Best e1RM set across working sets.
        var bestName = "", bestE1RM = 0.0, bestW = 0.0, bestReps = 0
        for row in session.exercises {
            for set in row.sets where set.isComplete && set.type == .working {
                guard let w = set.weightKg, let r = set.reps else { continue }
                let e = StrengthMath.e1RM(weightKg: w, reps: r)
                if e > bestE1RM { bestE1RM = e; bestW = w; bestReps = r; bestName = row.exercise?.name ?? "your top lift" }
            }
        }

        var narrative = "Strong work. \(Int(volume)) \(unit) across \(session.totalSets) sets."
        if bestE1RM > 0 {
            narrative += " \(bestName) topped \(Formatters.weight(kg: bestW, unit: weightUnit)) × \(bestReps)."
        }
        narrative += planned ? " Counts toward today's plan ✓, right on track." : " Logged and saved."

        var insights = [WorkoutRead.Insight(label: "Volume", value: "\(Int(volume)) \(unit)", note: "")]
        if bestE1RM > 0 {
            insights.append(.init(label: "Top e1RM", value: Formatters.weight(kg: bestE1RM, unit: weightUnit), note: bestName))
        }
        return WorkoutRead(narrative: narrative, insights: insights, planAdjustment: nil)
    }

    // MARK: Cardio

    private static func cardio(_ workout: Workout, distanceUnit: DistanceUnit, planned: Bool) -> WorkoutRead {
        guard let gps = workout.gps, gps.distanceM > 0 else {
            return WorkoutRead(narrative: "Session saved. Every step counts.", insights: [], planAdjustment: nil)
        }
        let dist = Formatters.distance(meters: gps.distanceM, unit: distanceUnit)
        let typeWord = (workout.type == .ride) ? "Ride" : (workout.type == .walk ? "Walk" : "Run")
        let metric: String
        if workout.type == .ride {
            let speed = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
            metric = "at \(Formatters.speed(ms: speed, unit: distanceUnit))"
        } else {
            let pace = workout.durationS > 0 ? workout.durationS / (gps.distanceM / 1000) : 0
            metric = "at \(Formatters.pace(secPerKm: pace, unit: distanceUnit))"
        }

        var narrative = "\(typeWord) of \(dist) \(metric)."
        if let trend = splitTrend(gps) { narrative += " \(trend)." }
        narrative += planned ? " That's today's session ✓, base is building." : " Nice work, saved."

        let insights = [
            WorkoutRead.Insight(label: "Distance", value: dist, note: ""),
            WorkoutRead.Insight(label: "Elevation", value: "\(Int(gps.elevationGainM)) m", note: ""),
        ]
        return WorkoutRead(narrative: narrative, insights: insights, planAdjustment: nil)
    }

    /// "Negative split" if the back half was quicker than the front half.
    private static func splitTrend(_ gps: GPSDetail) -> String? {
        let samples = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
        guard samples.count >= 4, let first = samples.first, let last = samples.last else { return nil }
        let total = gps.distanceM
        guard total > 0 else { return nil }
        let midTime = first.t.addingTimeInterval(last.t.timeIntervalSince(first.t) / 2)
        // Distance covered in each time-half (rough but cheap).
        var distFirst = 0.0, distSecond = 0.0, prev = samples[0]
        for s in samples.dropFirst() {
            let d = Geo.distance(lat1: prev.lat, lon1: prev.lon, lat2: s.lat, lon2: s.lon)
            if s.t <= midTime { distFirst += d } else { distSecond += d }
            prev = s
        }
        if distSecond > distFirst * 1.03 { return "You sped up into a negative split" }
        if distFirst > distSecond * 1.03 { return "Even, honest effort" }
        return "Steady throughout"
    }

    /// Strip anything that could read as a medical claim (prompt + post-filter, §8.8).
    static func sanitize(_ text: String) -> String {
        let banned = ["injur", "pain", "diagnos", "medical", "rehab"]
        let lower = text.lowercased()
        if banned.contains(where: { lower.contains($0) }) {
            return "Session saved, momentum's got the details."
        }
        // Em/en dashes read as generic-AI slop; convert to clean sentence punctuation.
        let cleaned = deDash(text)
        // Trim to <= 55 words defensively.
        let words = cleaned.split(separator: " ")
        return words.count <= 55 ? cleaned : words.prefix(55).joined(separator: " ") + "…"
    }

    /// Replace em/en dashes with sentence punctuation; leave hyphens in compound words alone.
    static func deDash(_ s: String) -> String {
        guard s.contains("—") || s.contains("–") else { return s }
        let pieces = s.replacingOccurrences(of: "–", with: "—")
            .components(separatedBy: "—")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return pieces.enumerated().reduce("") { acc, e in
            let (idx, p) = e
            let capped = idx == 0 ? p : p.prefix(1).uppercased() + p.dropFirst()
            return idx == 0 ? capped : acc + ". " + capped
        }
    }
}
