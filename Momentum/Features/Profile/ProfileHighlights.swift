import Foundation

/// The "Highlights" tab of the profile — an auto-curated greatest-hits reel derived from history:
/// current streak, longest run, longest session, biggest lifting day, and top strength PRs. Pure and
/// testable (no view logic). Each highlight that maps to a single workout carries its `workoutID` so a
/// tap can open the immersive pager on exactly that session.
@MainActor
struct ProfileHighlights {
    enum Kind { case streak, longestRun, longestSession, volumeDay, pr }

    struct Highlight: Identifiable {
        let id: String
        let kind: Kind
        let title: String        // "Longest run"
        let value: String        // "12.4 km"
        let systemImage: String
        let workoutID: UUID?     // tap → open the pager at this workout (nil = not tied to one)
    }

    let items: [Highlight]

    init(stats: ProfileStats, workouts: [Workout],
         weightUnit: WeightUnit = .default(), distanceUnit: DistanceUnit = .auto) {
        var out: [Highlight] = []

        // Current streak — the earned flame.
        if stats.currentStreak > 0 {
            out.append(Highlight(
                id: "streak", kind: .streak, title: "Day streak",
                value: "\(stats.currentStreak)", systemImage: "flame.fill", workoutID: nil))
        }

        // Longest run — the single farthest run.
        if stats.longestRunM > 0 {
            let run = workouts.filter { $0.type == .run }.max { ($0.gps?.distanceM ?? 0) < ($1.gps?.distanceM ?? 0) }
            out.append(Highlight(
                id: "longest-run", kind: .longestRun, title: "Longest run",
                value: Formatters.distance(meters: stats.longestRunM, unit: distanceUnit),
                systemImage: "figure.run", workoutID: run?.id))
        }

        // Longest session — most time under tension of any single workout.
        if stats.longestDurationS > 0 {
            let longest = workouts.max { $0.durationS < $1.durationS }
            out.append(Highlight(
                id: "longest-session", kind: .longestSession, title: "Longest session",
                value: Formatters.duration(s: stats.longestDurationS),
                systemImage: "clock.fill", workoutID: longest?.id))
        }

        // Biggest lifting day — the strength workout with the most volume.
        if let bigDay = workouts.filter({ $0.type.isStrengthStyle })
            .max(by: { ($0.strength?.totalVolumeKg ?? 0) < ($1.strength?.totalVolumeKg ?? 0) }),
           let vol = bigDay.strength?.totalVolumeKg, vol > 0 {
            let shown = weightUnit == .lb ? vol * Formatters.lbPerKg : vol
            out.append(Highlight(
                id: "volume-day", kind: .volumeDay, title: "Biggest day",
                value: "\(Formatters.compact(shown)) \(weightUnit == .lb ? "lb" : "kg")",
                systemImage: "dumbbell.fill", workoutID: bigDay.id))
        }

        // Top strength PRs (best e1RM per lift).
        for (i, pr) in stats.strengthPRs.enumerated() {
            out.append(Highlight(
                id: "pr-\(i)-\(pr.name)", kind: .pr, title: pr.name,
                value: Formatters.weight(kg: pr.e1RMKg, unit: weightUnit),
                systemImage: "trophy.fill", workoutID: nil))
        }

        self.items = out
    }
}
