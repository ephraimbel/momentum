import Foundation

/// One honest sentence about what a finished cardio session MEANT, drawn from the athlete's own
/// history.
///
/// The post-workout moment used to show five bare numbers and no interpretation. `CardioAchievements`
/// covers the runs that set a record — maybe one in ten — and every other run read as filing rather
/// than feedback. This covers the rest, and the caller shows it only when there is no badge, so the
/// two never talk over each other.
///
/// Two rules it never breaks:
/// - **No over-claiming.** Comparisons run against strictly-earlier sessions only, and only against
///   runs of a comparable distance — ranking a 5K against a 20K is arithmetic, not insight.
/// - **No shame.** A slower run is never handed back as a deficit. When there's nothing encouraging
///   and true to say about the pace, it falls through to a fact about showing up instead. That isn't
///   spin: the number is right there on the screen above it.
///
/// Pure by design (no SwiftData, no `Date()`) so every branch is fixture-testable.
enum RunVerdict {

    /// What KIND of thing the line says — so the surface can dress it honestly. The app's accent
    /// rule is that iridescence marks progress and nothing else, and "that's 3 this week" is a fact
    /// about turning up, not an award. Without this the consistency line wore the same rosette and
    /// iridescent capsule as a personal best, which cheapens the badge that means something.
    enum Tone: Sendable, Equatable {
        /// A genuine best — earns the full treatment.
        case earned
        /// Measurably faster than last time, but not a record.
        case gain
        /// Their first one. Nothing to compare against yet.
        case beginning
        /// True and worth saying, but not an achievement.
        case steady
    }

    struct Verdict: Sendable, Equatable {
        let text: String
        let tone: Tone
        /// Whether this sentence is still true a year from now.
        ///
        /// Most of them are: where a run ranks among the athlete's own is a fact about the past and
        /// doesn't rot. The consistency fallback is the exception, because "that's 3 this week" is
        /// true at the finish line and nonsense on a run reopened in December. History shows the
        /// timeless ones and suppresses the rest, so a run keeps its meaning without ever lying
        /// about when it happened.
        let isTimeless: Bool

        init(text: String, tone: Tone, isTimeless: Bool = true) {
            self.text = text
            self.tone = tone
            self.isTimeless = isTimeless
        }
    }

    /// A finished session reduced to what a comparison actually needs.
    struct Run: Sendable, Equatable {
        let date: Date
        let distanceM: Double
        let durationS: Double
        /// Average heart rate, when the run captured one. Optional throughout: it is the difference
        /// between a good line and no line, never between a correct verdict and a wrong one.
        let avgHR: Int?

        init(date: Date, distanceM: Double, durationS: Double, avgHR: Int? = nil) {
            self.date = date
            self.distanceM = distanceM
            self.durationS = durationS
            self.avgHR = avgHR
        }

        /// Seconds per kilometre, or nil when there's nothing to divide — a recording with no
        /// distance or no elapsed time has no pace, and inventing one would poison every comparison.
        var paceSPerKm: Double? {
            guard distanceM > 0, durationS > 0 else { return nil }
            return durationS / (distanceM / 1000)
        }
    }

    /// Earlier runs over the same ground, and what to call it.
    ///
    /// Distance is a crude stand-in for "comparable": two 5Ks can share a number and nothing else.
    /// Same-route runs are the comparison a runner actually makes, so when the caller can supply
    /// them (`RouteMatch`) they outrank everything the distance ladder can say. The noun travels
    /// with the priors because only the geometry knows whether it closed.
    struct RouteContext: Sendable, Equatable {
        let priors: [Run]
        let isLoop: Bool

        init(priors: [Run], isLoop: Bool) {
            self.priors = priors
            self.isLoop = isLoop
        }
    }

    /// Two runs are "the same shape" when their distances are within this fraction of each other.
    static let similarDistanceTolerance = 0.15

    /// Below this many seconds per displayed unit, a pace difference is noise — GPS drift and a
    /// different traffic light account for more. Claiming it would cheapen every real gain.
    static let meaningfulDeltaSPerUnit = 3.0

    /// A heart-rate drop worth mentioning. Below this, day-to-day variation in sleep, caffeine and
    /// strap placement accounts for it.
    static let meaningfulHRDeltaBPM = 3

    /// How much pace a run may give up and still be read as "the same effort at a lower heart rate".
    /// Past this the athlete simply ran easier, and crediting that as efficiency would be a lie the
    /// athlete can feel.
    static let sameEffortPaceWindowSPerUnit = 15.0

    /// Close enough to a route best that saying so is encouragement rather than a consolation.
    static let nearBestWindowSPerUnit = 10.0

    /// The verdict line, or nil when we genuinely have nothing to say.
    /// - Parameters:
    ///   - run: the session just finished.
    ///   - priors: every earlier session of the SAME discipline. Order doesn't matter; anything
    ///     dated at or after `run` is discarded, so a caller may pass its whole history unfiltered.
    ///   - route: earlier runs over this exact route, when the caller could identify one. Takes
    ///     precedence over the distance ladder below: same ground is a real test, same distance is
    ///     a coincidence.
    ///   - unit: display unit — the delta is phrased per mile or per kilometre to match the screen.
    static func verdict(for run: Run, priors: [Run], route: RouteContext? = nil,
                        unit: DistanceUnit) -> Verdict? {
        guard let pace = run.paceSPerKm else { return nil }

        if let route, let v = routeVerdict(for: run, pace: pace, route: route, unit: unit) { return v }

        let earlier = priors.filter { $0.date < run.date && $0.distanceM > 0 && $0.durationS > 0 }
        guard !earlier.isEmpty else {
            return Verdict(text: "Your first one on the board. Everything after this has something to measure against.",
                           tone: .beginning)
        }

        // Only runs of a comparable distance can speak to pace.
        let similar = earlier.filter {
            abs($0.distanceM - run.distanceM) <= run.distanceM * similarDistanceTolerance
        }

        if !similar.isEmpty {
            // Where this one lands among them. `paceSPerKm` is non-nil for every member of `similar`
            // (the filter above required distance and duration), so the fallback never decides a rank.
            let fasterCount = similar.filter { ($0.paceSPerKm ?? .infinity) < pace }.count
            let rank = fasterCount + 1
            if rank == 1 { return Verdict(text: "Your fastest at this distance.", tone: .earned) }
            if rank <= 3 { return Verdict(text: "Your \(ordinal(rank))-fastest at this distance.", tone: .earned) }

            // Not a podium — but a clear gain on the last comparable outing still deserves saying.
            if let last = similar.max(by: { $0.date < $1.date }), let lastPace = last.paceSPerKm {
                let gainSPerKm = lastPace - pace          // positive ⇒ faster today
                let gain = perDisplayUnit(gainSPerKm, unit: unit)
                if gain >= meaningfulDeltaSPerUnit {
                    return Verdict(text: "\(Int(gain.rounded()))s/\(unitLabel(unit)) faster than last time at this distance.",
                                   tone: .gain)
                }
            }
            // Slower, or level: deliberately fall through. See the no-shame rule above.
        } else if run.distanceM > (earlier.map(\.distanceM).max() ?? 0) {
            // Nothing comparable because it's further than anything before it.
            return Verdict(text: "The furthest you've gone. New ground.", tone: .earned)
        }

        return consistencyLine(for: run, earlier: earlier)
    }

    // MARK: - The route ladder

    /// What this run meant *for this route*, in descending order of what it's allowed to claim.
    ///
    /// The rungs, and the guard each one carries so it can never over-claim:
    ///  1. **Route best.** Needs two earlier outings, so "fastest here" describes a route the
    ///     athlete knows rather than the better of two attempts.
    ///  2. **Route podium.** Needs three, for the same reason: second of three is a placing, second
    ///     of two is a way of saying "slower".
    ///  3. **Faster than last time here**, once the gain clears the noise floor.
    ///  4. **The same road at a lower heart rate.** The one honest thing to say about a run that
    ///     wasn't faster: the clock is not the only measure and this is the other one. Gated on the
    ///     pace being close, because a genuinely easy day also has a low heart rate and calling that
    ///     efficiency is flattery.
    ///  5. **Within touching distance of their best here.**
    ///  6. **The bare fact of the repetition**, which is always true and never a rebuke.
    ///
    /// Rungs 4 to 6 are the no-shame floor: none of them states a deficit. The clock is on the
    /// screen directly above this line, so the athlete already knows. Saying it back is not honesty,
    /// it is just piling on.
    private static func routeVerdict(for run: Run, pace: Double,
                                     route: RouteContext, unit: DistanceUnit) -> Verdict? {
        let priors = route.priors.filter { $0.date < run.date && $0.paceSPerKm != nil }
        guard !priors.isEmpty, let bestPrior = priors.compactMap(\.paceSPerKm).min() else { return nil }

        let noun = route.isLoop ? "loop" : "route"
        let ord = ordinalWord(priors.count + 1)
        let rank = priors.filter { ($0.paceSPerKm ?? .infinity) < pace }.count + 1

        if rank == 1, priors.count >= 2 {
            return Verdict(text: "Fastest you've run this \(noun).", tone: .earned)
        }
        // Second and third only: first place belongs to the rung above, which declines to award it
        // on a field of two, and a podium rung that also handled rank 1 would announce a "1th".
        //
        // A placing is only worth naming when there is a field to place in. Second of two is a
        // roundabout way of saying "slower", and third of four is barely better, so a placing must
        // have at least as many runs behind it as in front: 2nd needs four outings, 3rd needs six.
        if (2...3).contains(rank), priors.count + 1 >= rank * 2 {
            return Verdict(text: "Your \(ordinal(rank))-fastest on this \(noun).", tone: .earned)
        }

        if let last = priors.max(by: { $0.date < $1.date }), let lastPace = last.paceSPerKm {
            let gain = perDisplayUnit(lastPace - pace, unit: unit)
            if gain >= meaningfulDeltaSPerUnit {
                return Verdict(text: "\(ord) time on this \(noun). \(Int(gain.rounded()))s/\(unitLabel(unit)) faster than last time.",
                               tone: .gain)
            }
            if let hr = run.avgHR, let lastHR = last.avgHR, hr > 0, lastHR > 0,
               lastHR - hr >= meaningfulHRDeltaBPM,
               perDisplayUnit(pace - lastPace, unit: unit) <= sameEffortPaceWindowSPerUnit {
                return Verdict(text: "\(ord) time on this \(noun), at \(lastHR - hr) fewer beats than last time.",
                               tone: .gain)
            }
        }

        let offBest = perDisplayUnit(pace - bestPrior, unit: unit)
        if offBest > 0, offBest <= nearBestWindowSPerUnit {
            return Verdict(text: "\(ord) time on this \(noun). Within \(max(1, Int(offBest.rounded())))s/\(unitLabel(unit)) of your best here.",
                           tone: .steady)
        }
        return Verdict(text: "\(ord) time on this \(noun).", tone: .steady)
    }

    // MARK: - Fallback

    /// What's true no matter how the pace landed: that they showed up, and how often lately.
    private static func consistencyLine(for run: Run, earlier: [Run]) -> Verdict? {
        let weekAgo = run.date.addingTimeInterval(-7 * 24 * 3600)
        let thisWeek = earlier.filter { $0.date >= weekAgo }.count + 1   // +1 for the run just finished
        let text: String
        switch thisWeek {
        case 1: text = "First one of the week. That's the hard one done."
        case 2: text = "Two this week."
        default: text = "That's \(thisWeek) this week."
        }
        // The one line that expires: see `Verdict.isTimeless`.
        return Verdict(text: text, tone: .steady, isTimeless: false)
    }

    // MARK: - Units

    /// A seconds-per-kilometre difference expressed per displayed unit, so "18s/mi" is genuinely
    /// per mile rather than a kilometre figure wearing a mile label.
    private static func perDisplayUnit(_ sPerKm: Double, unit: DistanceUnit) -> Double {
        unit.resolved() == .imperial ? sPerKm * (Formatters.metersPerMile / 1000) : sPerKm
    }

    private static func unitLabel(_ unit: DistanceUnit) -> String {
        unit.resolved() == .imperial ? "mi" : "km"
    }

    /// Only ever called for 2 and 3 — the podium places the caller asks about.
    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    /// "Ninth time on this loop" reads like a person; "9th time" reads like a receipt. Words up to
    /// twenty, where English has them and they stay short, then digits, where spelling it out would
    /// be worse than the numeral it replaced. Capitalised because it always opens the sentence.
    private static func ordinalWord(_ n: Int) -> String {
        let words = ["", "First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh",
                     "Eighth", "Ninth", "Tenth", "Eleventh", "Twelfth", "Thirteenth", "Fourteenth",
                     "Fifteenth", "Sixteenth", "Seventeenth", "Eighteenth", "Nineteenth", "Twentieth"]
        if n >= 1, n < words.count { return words[n] }
        // 21st, 22nd, 23rd, 24th … with the teens exception English insists on.
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
