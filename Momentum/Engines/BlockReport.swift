import Foundation

/// The block report: what actually changed over a rolling six-week block, in a coach's words.
///
/// An athlete with no race has no finish line to tell them the training worked, so the block
/// itself has to say it. Every number here is read from the journal and the plan, never guessed,
/// and a line only appears when there is evidence for it: a first block with no logged history
/// gets a shorter report, not a padded one. Deterministic, unit-aware, and dash-free like every
/// other line the coach writes.
enum BlockReport {
    struct Summary: Equatable, Sendable {
        var blockNumber: Int                 // 1-based, the way the athlete counts blocks
        var weeklyVolumeM: Double?           // achieved, averaged over the block's weeks
        var previousWeeklyVolumeM: Double?   // the four weeks before the block began
        var longestRunM: Double?
        var previousLongestRunM: Double?
        var sessionsPlanned: Int
        var sessionsDone: Int
        var checkpointDistanceM: Double?     // the block's time trial, when it was run
        var checkpointTimeS: Double?
        var p5kStartSPerKm: Double?          // the fitness estimate when the block began
        var p5kEndSPerKm: Double?            // and now
    }

    struct Text: Equatable, Sendable {
        var headline: String
        var lines: [String]
        var next: String
    }

    static func text(_ s: Summary, unit: DistanceUnit) -> Text {
        var lines: [String] = []

        // The checkpoint leads: it is the measured answer. A mile is a benchmark, not a 5K
        // predictor, so it is reported as its own time and nothing more.
        if let d = s.checkpointDistanceM, let t = s.checkpointTimeS, d > 0, t > 0 {
            var line = "Checkpoint: \(Formatters.distance(meters: d, unit: unit)) in \(clock(t))."
            if d >= 2_000 {
                let p5k = PlanEngine.riegelP5k(distanceM: d, timeS: t)
                line += " That is a 5K estimate of \(clock(p5k * 5))."
            }
            lines.append(line)
        }

        if let a = s.p5kStartSPerKm, let b = s.p5kEndSPerKm, a > 0, b > 0 {
            let delta = a - b   // positive means faster now
            if abs(delta) >= 3 {
                lines.append(delta > 0
                    ? "Your 5K estimate moved from \(clock(a * 5)) to \(clock(b * 5)) over the block."
                    : "Your 5K estimate went from \(clock(a * 5)) to \(clock(b * 5)). Fitness shows up on its own schedule.")
            } else if s.checkpointDistanceM == nil {
                lines.append("Your 5K estimate held at \(clock(b * 5)).")
            }
        }

        if let v = s.weeklyVolumeM, v > 0 {
            let now = Formatters.distance(meters: v, unit: unit)
            if let p = s.previousWeeklyVolumeM, p > 0, abs(v - p) / p >= 0.05 {
                let then = Formatters.distance(meters: p, unit: unit)
                lines.append(v > p
                    ? "You ran about \(now) a week, up from \(then)."
                    : "You ran about \(now) a week, down from \(then). The next block starts from there, not from the plan.")
            } else {
                lines.append("You ran about \(now) a week.")
            }
        }

        if let l = s.longestRunM, l > 0 {
            let now = Formatters.distance(meters: l, unit: unit)
            if let p = s.previousLongestRunM, p > 0, l > p * 1.05 {
                lines.append("Longest run \(now), up from \(Formatters.distance(meters: p, unit: unit)).")
            } else {
                lines.append("Longest run \(now).")
            }
        }

        if s.sessionsPlanned > 0 {
            lines.append("\(s.sessionsDone) of \(s.sessionsPlanned) sessions done.")
        }

        return Text(headline: "Block \(s.blockNumber) in review.",
                    lines: lines,
                    next: "The next block builds from what you actually ran. Nothing is locked in.")
    }

    /// The report as one coach message.
    static func message(_ s: Summary, unit: DistanceUnit) -> String {
        let t = text(s, unit: unit)
        return ([t.headline] + t.lines + [t.next]).joined(separator: " ")
    }

    /// "27:31" or "1:02:10".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
