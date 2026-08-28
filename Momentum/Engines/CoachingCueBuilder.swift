import Foundation

/// Pure, deterministic spoken-cue text for the voice coach (PRD §4.10 — Pro). The synthesizer just
/// reads these strings; building the wording here keeps it testable and free of AVFoundation. Cues
/// are short, factual, second-person where natural, and never make medical claims.
enum CoachingCueBuilder {

    /// A completed-unit milestone, e.g. "Mile 3. 8:45 per mile." The same line is read aloud and
    /// shown on the live screen, so the split is a clock figure (speech reads "eight forty-five";
    /// the eye reads it in one glance), never "8 minutes 45 seconds". Omitted when unknown (≤0),
    /// giving just "Mile 3."
    static func milestone(unitCount: Int, splitSecPerUnit: Double, unit: DistanceUnit) -> String {
        let name = unitName(unit)
        let header = "\(name.capitalized) \(unitCount)."
        guard splitSecPerUnit > 0 else { return header }
        return "\(header) \(clockFigure(seconds: splitSecPerUnit)) per \(name)."
    }

    static func restComplete() -> String { "Rest complete. Time for your next set." }
    static func paused() -> String { "Paused." }
    static func resumed() -> String { "Resumed." }
    static func goalReached() -> String { "Goal reached. Everything from here is extra." }

    // MARK: Structured workout (R1)

    /// Spoken once as a guided session begins — the coach's opening line at the track: the day's
    /// shape in plain words, then the promise that every step will be called. Composed from the
    /// steps themselves so the words and the workout can never disagree.
    static func workoutIntro(_ workout: StructuredWorkout) -> String {
        let shape: String
        if let w = workout.steps.first(where: { $0.kind == .work && $0.repTotal != nil }),
           let n = w.repTotal {
            // "10 repeats of 400 meters" / "8 hills, 30 seconds each" / "6 strides, 20 seconds each".
            shape = w.title == nil
                ? "\(n) repeats of \(spokenTarget(w.target))"
                : "\(n) \(w.displayNoun.lowercased())s, \(spokenTarget(w.target)) each"
        } else {
            // Continuous sessions (tempo, progression, run/walk, race-finish long) read their title.
            shape = workout.title
                .replacingOccurrences(of: " · ", with: ", ")
                .replacingOccurrences(of: "@", with: "at")
        }
        let warm = workout.steps.first?.kind == .warmup ? " Warm-up first." : ""
        return "Today: \(shape).\(warm) I'll call every step."
    }

    /// Spoken when a guided step begins — e.g. "Rep 3 of 6. 400 meters at your target. Go.",
    /// "Hill 2 of 8. 45 seconds hard. Go.", "Float. 1 minute easy.", "Cool down. Nice and easy."
    /// The final rep of a set gets the words every coach says: "Last one."
    static func stepStart(_ step: WorkoutStep) -> String {
        switch step.kind {
        case .warmup: return "Warm up. Ease in."
        case .cooldown: return "Cool down. Nice and easy."
        case .recovery:
            let noun = step.title ?? "Recover"
            if case let .duration(s) = step.target { return "\(noun). \(spokenPace(secPerUnit: s)) easy." }
            return "\(noun). Easy now."
        case .work:
            // Effort-based reps (hills / strides) have no pace target → "hard"; paced reps run
            // "at your target" — except fartlek surges, which are speed PLAY: "strong", never a number.
            let effort = step.paceSPerKm == nil ? "hard"
                : step.title == "Surge" ? "strong"
                : "at your target"
            if let i = step.repIndex, let n = step.repTotal {
                let last = (i == n && n > 1) ? " Last one." : ""
                return "\(step.displayNoun) \(i) of \(n).\(last) \(spokenTarget(step.target)) \(effort). Go."
            }
            // A continuous block (tempo, or a progression segment) named by its title.
            let name = step.title.map { "\($0)." } ?? ""
            return "\(name) \(spokenTarget(step.target)). Hold your effort.".trimmingCharacters(in: .whitespaces)
        }
    }

    /// A gentle pace nudge inside a work step. Never a shame state — just a direction.
    static func paceNudge(_ adherence: StructuredRunTracker.Adherence) -> String {
        switch adherence {
        case .tooFast: "Ease back a touch."
        case .tooSlow: "Pick it up."
        case .onPace, .noTarget: ""
        }
    }

    /// Occasional positive reinforcement while holding the target pace. Sparse by design (the view
    /// model throttles hard) so hearing it stays meaningful. The caller passes a running count and
    /// the lines cycle, keeping the wording deterministic.
    static func encouragement(_ index: Int) -> String {
        // Facts, not cheerleading: the coach confirms the number, then goes quiet again.
        let lines = ["On pace.",
                     "Right on target.",
                     "Holding the target."]
        return lines[max(index, 0) % lines.count]
    }

    static func workoutComplete() -> String { "Workout complete. That's the work done." }

    // MARK: Planned (non-structured) runs

    /// The opening line for a plan-prescribed easy/long run: the day's distance up front, and the
    /// pace to hold when the plan set one. nil for a free run with no goal (silence is the norm).
    /// e.g. "14 miles today. Hold about 9:40 per mile." / "8 kilometers today."
    static func runIntro(goalMeters: Double?, targetPaceSPerKm: Double?, unit: DistanceUnit) -> String? {
        guard let goalMeters, goalMeters > 0 else { return nil }
        let head = "\(spokenDistance(meters: goalMeters, unit: unit)) today."
        guard let pace = targetPaceSPerKm, pace > 0 else { return head }
        // "About" means about: a coach says "about 9:40", never "about 9:39". Nearest 5 s.
        return "\(head) Hold about \(clockPace(secPerKm: pace, unit: unit, roundTo: 5)) per \(unitName(unit))."
    }

    /// Spoken once at the midpoint of a goal run: "Halfway. 7 miles to go."
    static func halfway(remainingMeters: Double, unit: DistanceUnit) -> String {
        "Halfway. \(spokenDistance(meters: remainingMeters, unit: unit)) to go."
    }

    /// Spoken once with one unit left on a goal run: "Last mile." / "Last kilometer."
    static func finalStretch(unit: DistanceUnit) -> String { "Last \(unitName(unit))." }

    /// A pace-drift nudge on a planned easy/long run, spoken only after the drift has held for a
    /// while (the view model owns the band, hysteresis and cooldown). Never a verdict on the run.
    static func paceDrift(_ adherence: StructuredRunTracker.Adherence) -> String {
        switch adherence {
        case .tooFast: "A touch quick for today. Ease back to your target."
        case .tooSlow: "Under your target. Pick it up a little."
        case .onPace, .noTarget: ""
        }
    }

    /// "14 miles" / "8 kilometers" / "1 mile" / "5.5 kilometers" for the current unit setting.
    static func spokenDistance(meters: Double, unit: DistanceUnit) -> String {
        let name = unitName(unit)
        let value = unit.resolved() == .imperial ? meters / Formatters.metersPerMile : meters / 1000
        let rounded = (value * 10).rounded() / 10
        let n = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(n) \(name)\(rounded == 1 ? "" : "s")"
    }

    /// Pace as a clock figure ("9:40") in the athlete's unit, readable on screen and by speech alike.
    /// `roundTo` snaps to the nearest N seconds for approximate targets.
    static func clockPace(secPerKm: Double, unit: DistanceUnit, roundTo: Double = 1) -> String {
        let perUnit = unit.resolved() == .imperial ? secPerKm * (Formatters.metersPerMile / 1000) : secPerKm
        return clockFigure(seconds: perUnit, roundTo: roundTo)
    }

    /// Seconds as "m:ss" (hours fold into minutes: a 62-minute split reads "62:00", never "1:02:00",
    /// which speech would read as a time of day).
    static func clockFigure(seconds: Double, roundTo: Double = 1) -> String {
        let step = max(1, roundTo)
        let total = Int((seconds / step).rounded() * step)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A step target spoken naturally: "400 meters" / "1 kilometer" / "90 seconds".
    static func spokenTarget(_ target: WorkoutStep.Target) -> String {
        switch target {
        case let .distance(m):
            if m < 1000 { return "\(Int(m.rounded())) meters" }
            let km = m / 1000
            let n = km == km.rounded() ? String(Int(km)) : String(format: "%.1f", km)
            return "\(n) kilometer\(km == 1 ? "" : "s")"
        case let .duration(s):
            return spokenPace(secPerUnit: s)
        }
    }

    /// "mile" (imperial) or "kilometer" (metric); `auto` resolves via locale.
    static func unitName(_ unit: DistanceUnit) -> String {
        unit.resolved() == .imperial ? "mile" : "kilometer"
    }

    /// A seconds-per-unit value spoken naturally: "8 minutes 45 seconds" / "8 minutes" / "45 seconds".
    static func spokenPace(secPerUnit: Double) -> String {
        let total = Int(secPerUnit.rounded())
        let minutes = total / 60, seconds = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if seconds > 0 { parts.append("\(seconds) second\(seconds == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("0 seconds") }
        return parts.joined(separator: " ")
    }
}
