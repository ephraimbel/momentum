import Foundation

/// How hard the athlete chooses to push toward the goal — same destination, three ramps and three risk
/// profiles. This is a lever generic plan apps don't give you: you decide the aggression, and the
/// adaptive engine holds an aggressive plan to a tighter recovery leash (see ENDURANCE-FOCUS §6.3).
enum PlanIntensity: String, Codable, Sendable, CaseIterable, Identifiable {
    case gentle       // "Take your time"
    case balanced     // recommended default
    case aggressive
    /// The tier above Aggressive (user call 2026-07-23): for athletes training to WIN — front of
    /// the race, not the finish line. Higher volume ceiling, the two-hard-days week as standard,
    /// recovery jogs where full rest would sit. Never *recommended* by the feasibility engine —
    /// it's a commitment the athlete makes, not advice we give. Requires a 5+ day week (`floorDays`);
    /// every safety layer (ACWR governor, recovery tripwires, the injury hold-to-balanced cap)
    /// still applies — that's what makes it a coach and not a dare.
    case podium

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: "Take your time"; case .balanced: "Balanced"
        case .aggressive: "Aggressive"; case .podium: "Podium"
        }
    }

    var subtitle: String {
        switch self {
        case .gentle:     "Gentler ramp, most sustainable"
        case .balanced:   "Steady, sustainable progress"
        case .aggressive: "Faster gains, more demanding"
        case .podium:     "Train to win — the full commitment"
        }
    }

    /// Volume multiplier applied on each build week (the weekly ramp rate).
    var weeklyRamp: Double {
        switch self { case .gentle: 1.05; case .balanced: 1.08; case .aggressive: 1.11; case .podium: 1.12 }
    }

    /// Build weeks between cutback/down weeks — aggressive tiers stack a little more before easing.
    var buildWeeksPerDownWeek: Int {
        switch self { case .gentle: 3; case .balanced: 3; case .aggressive: 4; case .podium: 4 }
    }

    /// Bias on quality (hard) sessions per week vs. the balanced baseline. Wired in
    /// `PlanEngine.cardioSessions`: >1.0 (or experienced) at real volume unlocks the SECOND weekly
    /// quality session (build/peak, ≥5 run days, no injury history) — the Pfitzinger-style
    /// two-hard-days week. ≤1.0 at modest volume keeps the single-quality default. Podium lowers
    /// that volume gate too (`PlanEngine.secondQualityGateM`) — two hard days are its standard.
    var qualityBias: Double {
        switch self { case .gentle: 0.85; case .balanced: 1.0; case .aggressive: 1.2; case .podium: 1.4 }
    }

    /// An honest one-liner about the tradeoff (nil when there's nothing to warn about).
    var riskNote: String? {
        switch self {
        case .gentle:     "Lower injury risk. Best if you're new, coming back, or injury-prone."
        case .balanced:   nil
        case .aggressive: "Higher injury and burnout risk. We'll watch your recovery closely and pull back sooner."
        case .podium:     "Five-plus days, two hard sessions a week, jogs where rest days sat. For athletes chasing the front of the race. We watch recovery closely and pull back the moment your body says so."
        }
    }

    /// The training-frequency floor for the tier (0 = none). Podium's structure — two quality
    /// days + a long run + real easy volume — physically doesn't fit in fewer than five days.
    var floorDays: Int {
        self == .podium ? 5 : 0
    }

    /// The demanding tiers run on a tighter recovery leash (`RecoveryAdaptation` reacts to milder
    /// warning signs, wants more sleep) — the deal that makes them a coach and not a dare.
    var tightLeash: Bool {
        self == .aggressive || self == .podium
    }

    /// How much the tier scales the honest pace-improvement ceiling. Pushing harder buys faster gains
    /// for more risk — the steeper `weeklyRamp` and the tighter recovery leash are the other side of
    /// this deal. Both the feasibility verdict AND the Podium outlook read improvement through this,
    /// so choosing a harder push genuinely opens up a tighter goal (12 weeks IS enough for a real
    /// jump if the athlete commits to ramping faster) — while the copy stays honest about the cost.
    var improvementFactor: Double {
        switch self { case .gentle: 0.9; case .balanced: 1.0; case .aggressive: 1.35; case .podium: 1.6 }
    }
}

/// The honest read on whether a race goal is reachable in the time available, how much room there is,
/// and what to do when it isn't — the truthfulness generic plan apps skip (ENDURANCE-FOCUS §6.4).
/// Pure + deterministic; testable.
struct PlanFeasibility: Sendable {
    enum Verdict: String, Sendable {
        case onTrack     // comfortable — plenty of runway
        case tight       // doable, but it'll take focus (favor Aggressive)
        case tooShort    // not safely reachable by race day — offer honest alternatives
        case noRace      // no dated race — a rolling "get fitter, stay healthy" plan
    }

    let verdict: Verdict
    let weeksAvailable: Int
    let weeksNeeded: Int                 // safe build to this goal from current fitness
    let recommended: PlanIntensity
    let headline: String
    let detail: String
    /// Honest alternatives, shown when `tooShort`.
    let options: [String]
    /// A realistic finish time achievable by race day (nil when no goal time / not applicable).
    let realisticFinishS: Double?

    // MARK: Assessment

    /// Assess a goal against current fitness and the calendar.
    /// - currentP5kSPerKm: current 5K-equivalent pace (fitness). nil when unknown → time check is skipped.
    /// - currentWeeklyVolumeM: recent weekly running volume (0 for a brand-new runner).
    /// - injuryProne: past injuries reported — with room to spare, the recommendation eases off.
    /// - daysPerWeek: the athlete's training frequency. nil (unknown) skips the frequency check —
    ///   the calendar can be generous while the week is the real constraint, and pretending two
    ///   days prepares a marathon is exactly the dishonesty this engine exists to refuse.
    static func assess(raceDistanceM: Double?,
                       goalFinishTimeS: Double?,
                       currentP5kSPerKm: Double?,
                       currentWeeklyVolumeM: Double,
                       weeksAvailable: Int,
                       experience: ExperienceLevel,
                       injuryProne: Bool = false,
                       daysPerWeek: Int? = nil,
                       intensity: PlanIntensity = .balanced,
                       currentRaceTimeS: Double? = nil) -> PlanFeasibility {

        guard let distanceM = raceDistanceM, distanceM > 0 else {
            return PlanFeasibility(verdict: .noRace, weeksAvailable: weeksAvailable, weeksNeeded: 0,
                                   recommended: (experience == .new || injuryProne) ? .gentle : .balanced,
                                   headline: "A plan that grows with you",
                                   detail: "No race on the calendar. We'll build your fitness safely, week over week, and you can point it at a race anytime.",
                                   options: [], realisticFinishS: nil)
        }

        // The core read for a chosen level of push: how many weeks the goal needs (volume AND, when a
        // goal time is set, pace improvement), whether that time goal is beyond one cycle's honest
        // reach, and the best finish reachable by race day. Intensity feeds BOTH sides — a harder
        // push ramps volume faster (`weeklyRamp`) and earns a higher improvement ceiling
        // (`improvementFactor`) — so "how hard do you want to push" genuinely moves the verdict.
        func read(_ push: PlanIntensity) -> (weeksNeeded: Int, beyondReach: Bool, realisticFinishS: Double?) {
            let peak = peakWeeklyVolumeM(distanceM: distanceM, experience: experience)
            let current = max(currentWeeklyVolumeM, 8_000)      // floor so a near-zero base doesn't blow up the log
            let buildWeeks = current >= peak ? 0
                : Int(ceil(log(peak / current) / log(push.weeklyRamp)))
            let taperWeeks = distanceM >= RaceDistance.marathon.meters ? 3 : 2
            let weeksForVolume = max(minWeeks(forDistanceM: distanceM), buildWeeks + 2 + taperWeeks)

            var weeksForTime = 0
            var realistic: Double? = nil
            var beyond = false
            // The athlete's OWN time at the race distance is the truest "now"; otherwise project it
            // from 5K fitness (Riegel). Round-tripping a marathon time through a 5K-equivalent pace and
            // back re-applies the endurance tax — painting a real 4:00 marathoner as a 4:11 one, so a
            // genuine 30-minute PR reads as impossible when it isn't. Their actual race time skips that.
            let predictedNow = currentRaceTimeS ?? currentP5kSPerKm.map { predictedFinishS(distanceM: distanceM, p5kSPerKm: $0) }
            if let goal = goalFinishTimeS, let predicted = predictedNow {
                realistic = predicted
                if goal < predicted {                           // needs improvement
                    let need = (predicted - goal) / predicted    // fraction faster required
                    let perWeek = improvementPerWeek(experience, push)
                    let cap = improvementCap(experience, push)
                    if need > cap {
                        beyond = true                            // not realistic in one cycle at this push
                        weeksForTime = Int(ceil(cap / perWeek)) + 4
                    } else {
                        weeksForTime = Int(ceil(need / perWeek))
                    }
                    let achievable = min(cap, perWeek * Double(weeksAvailable))
                    realistic = predicted * (1 - achievable)     // best time reachable by race day
                }
            }
            return (max(weeksForVolume, weeksForTime), beyond, realistic)
        }

        func calendarVerdict(_ r: (weeksNeeded: Int, beyondReach: Bool, realisticFinishS: Double?)) -> Verdict {
            if r.beyondReach && weeksAvailable < r.weeksNeeded { return .tooShort }
            if weeksAvailable >= r.weeksNeeded { return .onTrack }
            if weeksAvailable >= Int(ceil(Double(r.weeksNeeded) * 0.8)) { return .tight }
            return .tooShort
        }

        // The DISPLAY read is at the athlete's chosen push, so the banner reacts as they pick a tier;
        // the RECOMMENDATION is anchored at Balanced so the "· Recommended" badge stays put while
        // they explore (and so a comfortable-at-balanced goal still eases new/injured athletes in).
        let shown = read(intensity)
        let shownVerdict = calendarVerdict(shown)
        let balancedVerdict = calendarVerdict(read(.balanced))

        // Frequency honesty: the calendar can be generous while the WEEK is the real constraint. One
        // day under the distance's effective minimum tightens the verdict; two or more under it is
        // maintenance, not race preparation — say so.
        var verdict = shownVerdict
        var frequencyShortfall: (days: Int, minDays: Int)? = nil
        if let days = daysPerWeek {
            let minDays = minimumEffectiveDays(forDistanceM: distanceM)
            if days < minDays {
                frequencyShortfall = (days: days, minDays: minDays)
                if minDays - days >= 2 { verdict = .tooShort }
                else if verdict == .onTrack { verdict = .tight }
            }
        }

        // Recommendation follows the BALANCED read — aggression trades recovery for progress, and a
        // frequency gap isn't closed by pushing harder on fewer days; it's closed by adding a day
        // (which the copy says plainly). Podium is never recommended — it's a commitment the athlete
        // makes, not advice the engine gives.
        let recommended: PlanIntensity
        switch balancedVerdict {
        case .onTrack: recommended = (experience == .new || injuryProne) ? .gentle : .balanced
        case .tight, .tooShort: recommended = .aggressive
        case .noRace: recommended = .balanced
        }

        let (headline, detail, options) = copy(verdict: verdict, weeksAvailable: weeksAvailable,
                                               weeksNeeded: shown.weeksNeeded, distanceM: distanceM,
                                               realisticFinishS: goalFinishTimeS != nil ? shown.realisticFinishS : nil,
                                               calendarVerdict: shownVerdict,
                                               frequencyShortfall: frequencyShortfall)

        return PlanFeasibility(verdict: verdict, weeksAvailable: weeksAvailable, weeksNeeded: shown.weeksNeeded,
                               recommended: recommended, headline: headline, detail: detail,
                               options: options, realisticFinishS: shown.realisticFinishS)
    }

    // MARK: Model

    /// Predicted finish time (s) for a distance from a 5K-equivalent pace, via Riegel (T = T₅ₖ·(D/5k)^1.06).
    static func predictedFinishS(distanceM: Double, p5kSPerKm: Double) -> Double {
        let t5k = p5kSPerKm * 5.0
        // Same Riegel core as RacePredictor, same endurance tax past ~3 h — the feasibility verdict
        // and the goal-time check must judge against the honest number, not the curve's optimism.
        return DanielsPaces.enduranceCorrected(raceTimeS: t5k * pow(distanceM / 5_000, 1.06))
    }

    /// Sensible peak weekly volume (meters) to be *ready* for a distance, scaled by experience.
    /// Also the plan engine's build ceiling: long runways grow toward this and hold, so a year-long
    /// marathon plan actually reaches marathon volume instead of plateauing at an arbitrary multiple.
    static func peakWeeklyVolumeM(distanceM: Double, experience: ExperienceLevel) -> Double {
        let d = RaceDistance.nearest(toMeters: distanceM)
        let km: Double
        switch (d, experience) {
        case (.fiveK, .new): km = 20; case (.fiveK, .some): km = 30; case (.fiveK, .experienced): km = 40
        case (.tenK, .new): km = 30; case (.tenK, .some): km = 40; case (.tenK, .experienced): km = 50
        case (.half, .new): km = 40; case (.half, .some): km = 55; case (.half, .experienced): km = 70
        case (.marathon, .new): km = 55; case (.marathon, .some): km = 70; case (.marathon, .experienced): km = 90
        case (.fiftyK, .new): km = 65; case (.fiftyK, .some): km = 80; case (.fiftyK, .experienced): km = 100
        }
        return km * 1_000
    }

    /// Minimum specific-prep block (weeks) for a distance — even a fit runner needs this to be race-ready.
    private static func minWeeks(forDistanceM distanceM: Double) -> Int {
        switch RaceDistance.nearest(toMeters: distanceM) {
        case .fiveK: 4; case .tenK: 5; case .half: 8; case .marathon: 12; case .fiftyK: 16
        }
    }

    /// The effective training-frequency floor for a distance — under this, weekly structure can't
    /// hold a long run AND quality AND enough easy volume, so the build maintains rather than
    /// prepares. (The engine still generates whatever week the athlete asks for; this is the
    /// honesty layer, not a gate.)
    static func minimumEffectiveDays(forDistanceM distanceM: Double) -> Int {
        switch RaceDistance.nearest(toMeters: distanceM) {
        case .fiveK, .tenK: 3
        case .half, .marathon: 4
        case .fiftyK: 5
        }
    }

    /// Sustainable pace-improvement rate per week (fraction faster), by experience and how hard the
    /// athlete pushes — beginners improve fastest, the trained plateau; a harder push (with its
    /// steeper ramp and tighter recovery leash) earns a faster rate. Still deliberately conservative.
    private static func improvementPerWeek(_ e: ExperienceLevel, _ intensity: PlanIntensity = .balanced) -> Double {
        let base: Double
        switch e { case .new: base = 0.010; case .some: base = 0.007; case .experienced: base = 0.005 }
        return base * intensity.improvementFactor
    }

    /// Ceiling on total pace improvement in one training cycle (fraction faster), scaled the same way.
    private static func improvementCap(_ e: ExperienceLevel, _ intensity: PlanIntensity = .balanced) -> Double {
        let base: Double
        switch e { case .new: base = 0.20; case .some: base = 0.15; case .experienced: base = 0.10 }
        return base * intensity.improvementFactor
    }

    /// The honest ceiling on how much faster `weeks` of training can make this athlete — the same
    /// per-week rates and per-cycle caps the verdict runs on, exposed so the Podium outlook can
    /// never promise what the verdict engine would refuse.
    static func achievableImprovement(experience: ExperienceLevel, weeks: Int,
                                      intensity: PlanIntensity = .balanced) -> Double {
        min(improvementCap(experience, intensity), improvementPerWeek(experience, intensity) * Double(max(0, weeks)))
    }

    private static func copy(verdict: Verdict, weeksAvailable: Int, weeksNeeded: Int,
                             distanceM: Double, realisticFinishS: Double?,
                             calendarVerdict: Verdict? = nil,
                             frequencyShortfall: (days: Int, minDays: Int)? = nil) -> (String, String, [String]) {
        let label = RaceDistance.nearest(toMeters: distanceM).label.lowercased()

        // Frequency-driven tooShort gets its own copy: the calendar may be fine — the WEEK is the
        // problem, and "move your race later" would be advice for the wrong constraint.
        if let f = frequencyShortfall, f.minDays - f.days >= 2 {
            var opts = ["Train \(f.minDays) days a week. \(f.minDays + 1) is even better for a \(label)"]
            if distanceM >= RaceDistance.half.meters {
                let shorter = distanceM >= RaceDistance.marathon.meters ? "half marathon" : "10K"
                opts.append("Point this week at a \(shorter) instead and build up from there")
            }
            if calendarVerdict == .tooShort {
                opts.append("Move your race about \(max(1, weeksNeeded - weeksAvailable)) weeks later so you can build safely")
            }
            return ("\(f.days) days a week won't prepare a \(label)",
                    "We'll build your week either way — but honestly, \(f.days) days holds fitness rather than building race readiness. A \(label) build needs room for a long run, quality work, AND easy volume; that starts at about \(f.minDays) days. Your best moves:",
                    opts)
        }

        var (headline, detail, options): (String, String, [String])
        switch verdict {
        case .onTrack:
            // The no-date sentinel (OnboardingViewModel passes 999 when a race distance is chosen
            // but no date is on the calendar): a literal "999 weeks is comfortable" shipped once.
            // No date means no clock, so say that instead of the number.
            if weeksAvailable >= 900 {
                (headline, detail, options) = ("You've got room",
                        "No race date yet, so there's no clock on this. We'll build you toward your \(label) steadily, and you'll be ready when you pick one.",
                        [])
            } else {
                (headline, detail, options) = ("You've got room",
                        "\(weeksAvailable) weeks is comfortable for a safe \(label) build. We'll progress you steadily and arrive fresh.",
                        [])
            }
        case .tight:
            (headline, detail, options) = ("It'll be tight, but doable",
                    "\(weeksAvailable) weeks to your \(label). We'd ideally want about \(weeksNeeded). It's within reach if you stay consistent; an aggressive plan bridges the gap, and we'll watch your recovery closely.",
                    [])
        case .tooShort:
            var opts = ["Move your race about \(max(1, weeksNeeded - weeksAvailable)) weeks later so you can build safely"]
            if let t = realisticFinishS { opts.insert("Target a realistic \(Self.hms(t)) for this race", at: 0) }
            if distanceM >= RaceDistance.half.meters {
                let shorter = distanceM >= RaceDistance.marathon.meters ? "half marathon" : "10K"
                opts.append("Run a \(shorter) now and build to the \(label) later")
            }
            (headline, detail, options) = ("That's a very short runway",
                    "A safe \(label) build from where you are is about \(weeksNeeded) weeks, and you have \(weeksAvailable). We won't pretend otherwise: cramming that gap sharply raises injury risk. We'll still coach every day between now and the start line, with fresh legs, race-pace touches, and a plan that gets you there ready to run the day well. But honestly, here are your best moves:",
                    opts)
        case .noRace:
            (headline, detail, options) = ("A plan that grows with you", "", [])
        }

        // One day under the effective minimum: the calendar copy stands, with the frequency move
        // named first — it's the cheapest fix on the table.
        if let f = frequencyShortfall {
            let tight = verdict == .tight && calendarVerdict == .onTrack
            if tight {
                detail = weeksAvailable >= 900
                    ? "No race date yet, so there's no clock. But \(f.days) days a week is the light side for a \(label). Most of the gap closes with one more day."
                    : "\(weeksAvailable) weeks is comfortable, but \(f.days) days a week is the light side for a \(label). Most of the gap closes with one more day."
            }
            options.insert("Train \(f.minDays) days a week. A \(label) build really wants \(f.minDays)–\(f.minDays + 1)", at: 0)
        }
        return (headline, detail, options)
    }

    /// "h:mm:ss" / "mm:ss" for a duration.
    static func hms(_ s: Double) -> String {
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
