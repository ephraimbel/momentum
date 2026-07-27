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
///
/// **How the coach talks here** (the same rules the server prompt carries, so the two voices are one):
/// - Lead with the number the athlete just earned, in the words they'd use. "8.0 km at 5:14 pace",
///   not "Run of 8.0 km at 5:14 /km".
/// - No trailing appositive. ", a strong top end" / ", right on track" / ", base is building" is the
///   loudest tell in machine writing: a clause bolted on to sound like a conclusion. Say it as a
///   sentence or don't say it.
/// - No filler praise. "Nice work, saved." and "Every step counts." are what something with nothing
///   to say says. A coach who has nothing to add stops talking, and the numbers are on screen anyway.
/// - Short sentences. Fragments are fine. Contractions are fine. That's how people speak.
/// - Never an em dash. `CoachVoiceTests` fails the build if one appears in any of these strings.
enum WorkoutReadTemplates {

    static func read(for workout: Workout, planned: Bool, weightUnit: WeightUnit = .default(),
                     distanceUnit: DistanceUnit = .auto) -> WorkoutRead {
        let read: WorkoutRead
        if workout.type.isStrengthStyle {
            read = strength(workout, weightUnit: weightUnit, planned: planned)
        } else if workout.type.isTimed {
            read = timed(workout, planned: planned)
        } else {
            read = cardio(workout, distanceUnit: distanceUnit, planned: planned)
        }
        return WorkoutRead(narrative: sanitize(read.narrative), insights: read.insights,
                           planAdjustment: read.planAdjustment)
    }

    // MARK: Timed

    private static func timed(_ workout: Workout, planned: Bool) -> WorkoutRead {
        let mins = Int((workout.durationS / 60).rounded())
        let sport = workout.type.title
        var narrative = mins > 0 ? "\(sport), \(mins) minutes." : "\(sport) logged."
        // Nothing else is known about a timed sport, so nothing else gets said. The old tail
        // ("Nice work, saved.") was the sound of filling a silence.
        if planned { narrative += " That's today's session done." }
        return WorkoutRead(narrative: narrative, insights: [], planAdjustment: nil)
    }

    // MARK: Strength

    private static func strength(_ workout: Workout, weightUnit: WeightUnit, planned: Bool) -> WorkoutRead {
        guard let session = workout.strength else {
            // Coaching, not filler: it says what to do next time to get more back.
            return WorkoutRead(narrative: "Logged. Add your sets next time and I'll track the numbers.",
                               insights: [], planAdjustment: nil)
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

        // Lead with the concrete fact. A specific opener earns trust where generic praise reads as
        // filler, and the top set is named the way lifters say it out loud: "80 kg for 5".
        var narrative = "\(Int(volume)) \(unit) across \(session.totalSets) sets."
        if bestE1RM > 0 {
            narrative += " Best set: \(bestName) at \(Formatters.weight(kg: bestW, unit: weightUnit)) for \(bestReps)."
        }
        if planned { narrative += " That's today's plan session done." }

        var insights = [WorkoutRead.Insight(label: "Volume", value: "\(Int(volume)) \(unit)", note: "")]
        if bestE1RM > 0 {
            insights.append(.init(label: "Top e1RM", value: Formatters.weight(kg: bestE1RM, unit: weightUnit), note: bestName))
        }
        return WorkoutRead(narrative: narrative, insights: insights, planAdjustment: nil)
    }

    // MARK: Cardio

    private static func cardio(_ workout: Workout, distanceUnit: DistanceUnit, planned: Bool) -> WorkoutRead {
        guard let gps = workout.gps, gps.distanceM > 0 else {
            return WorkoutRead(narrative: "Logged. No distance on this one, so I'm going by time.",
                               insights: [], planAdjustment: nil)
        }
        let dist = Formatters.distance(meters: gps.distanceM, unit: distanceUnit)
        // "8.0 km at 5:14 pace." is how an athlete says it. "Run of 8.0 km at 5:14 /km." is how a
        // form says it: the sport is already obvious from the pace, and the of-construction is
        // stilted in speech.
        var narrative: String
        switch workout.type {
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide:
            let speed = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
            narrative = "\(dist) at \(Formatters.speed(ms: speed, unit: distanceUnit))."
        case .walk, .hike:
            narrative = "\(dist) on foot."
        default:
            let pace = workout.durationS > 0 ? workout.durationS / (gps.distanceM / 1000) : 0
            // No trailing "pace": the formatter already says "/km", and "at 5:14 /km pace" is the
            // kind of doubled-up phrase nobody says out loud.
            narrative = "\(dist) at \(Formatters.pace(secPerKm: pace, unit: distanceUnit))."
        }
        if let trend = splitTrend(gps) { narrative += " \(trend)." }
        // Close the coaching loop: name the prescribed session and how it landed.
        if planned, let clause = coachingClause(runType: workout.plannedSession?.runType, reps: gps.structuredReps) {
            narrative += " \(clause)"
        } else if planned {
            narrative += " That's today's session done."
        }

        let insights = [
            WorkoutRead.Insight(label: "Distance", value: dist, note: ""),
            WorkoutRead.Insight(label: "Elevation", value: "\(Int(gps.elevationGainM)) m", note: ""),
        ]
        return WorkoutRead(narrative: narrative, insights: insights, planAdjustment: nil)
    }

    /// The coaching tie-in for a prescribed run — names the session and, for a guided one, how the reps
    /// landed. Turns "today's session ✓" into a read that shows the plan understood what you just did.
    /// Pure + testable. nil for a free run with no prescription.
    static func coachingClause(runType: RunType?, reps: [RepResult]) -> String? {
        guard let rt = runType else { return nil }
        let name: String
        switch rt {
        case .intervals:   name = "speed session"
        case .tempo:       name = "tempo"
        case .fartlek:     name = "fartlek"
        case .hills:       name = "hill session"
        case .strides:     name = "strides"
        case .progression: name = "progression run"
        case .long:        name = "long run"
        case .recovery:    name = "recovery run"
        case .easy:        name = "easy run"
        case .race:        name = "race"
        case .freeRun:     return nil
        }
        // One sentence for the session, one for how it went. The old form hung the second half on a
        // comma (", aerobic base building" / ", the hard work's banked") which is the machine tell
        // this voice is built to avoid.
        var clause = "That's the \(name) done."
        let paced = reps.filter { $0.verdict != .noTarget }
        if !paced.isEmpty {
            let on = paced.filter { $0.verdict == .onPace }.count
            clause += " \(on) of \(paced.count) reps on pace."
        } else if rt.isQuality {
            clause += " That's the hard work in."
        } else if rt == .recovery || rt == .easy {
            clause += " Easy days are what make the hard ones work."
        }
        return clause
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
        if distSecond > distFirst * 1.03 { return "You ran the second half faster" }
        if distFirst > distSecond * 1.03 { return "You went out quick and held on" }
        return "Even the whole way"
    }

    /// Strip anything that could read as a medical claim (prompt + post-filter, §8.8).
    static func sanitize(_ text: String) -> String {
        let banned = ["injur", "pain", "diagnos", "medical", "rehab"]
        let lower = text.lowercased()
        if banned.contains(where: { lower.contains($0) }) {
            return "Logged. I've got the numbers."
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
