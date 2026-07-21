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
    }

    /// A finished session reduced to what a comparison actually needs.
    struct Run: Sendable, Equatable {
        let date: Date
        let distanceM: Double
        let durationS: Double

        init(date: Date, distanceM: Double, durationS: Double) {
            self.date = date
            self.distanceM = distanceM
            self.durationS = durationS
        }

        /// Seconds per kilometre, or nil when there's nothing to divide — a recording with no
        /// distance or no elapsed time has no pace, and inventing one would poison every comparison.
        var paceSPerKm: Double? {
            guard distanceM > 0, durationS > 0 else { return nil }
            return durationS / (distanceM / 1000)
        }
    }

    /// Two runs are "the same shape" when their distances are within this fraction of each other.
    static let similarDistanceTolerance = 0.15

    /// Below this many seconds per displayed unit, a pace difference is noise — GPS drift and a
    /// different traffic light account for more. Claiming it would cheapen every real gain.
    static let meaningfulDeltaSPerUnit = 3.0

    /// The verdict line, or nil when we genuinely have nothing to say.
    /// - Parameters:
    ///   - run: the session just finished.
    ///   - priors: every earlier session of the SAME discipline. Order doesn't matter; anything
    ///     dated at or after `run` is discarded, so a caller may pass its whole history unfiltered.
    ///   - unit: display unit — the delta is phrased per mile or per kilometre to match the screen.
    static func verdict(for run: Run, priors: [Run], unit: DistanceUnit) -> Verdict? {
        guard let pace = run.paceSPerKm else { return nil }

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
        return Verdict(text: text, tone: .steady)
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
}
