import SwiftUI

/// Read-only summary for a timed activity, on the shared post-activity page grammar (2026-08-13 —
/// the Strava-shaped order every discipline follows): identity, hero number, plan connection,
/// share, photo, note. A timed sport's identity is its glyph (the map/muscle-map slot at the scale
/// this data supports), its hero is the duration, and the stat row carries whatever the session
/// actually measured — effort, calories, and the stationary e-bike's console readouts. Shared by
/// `TimedSaveView` (editing) and `WorkoutDetailView` (history), mirroring Cardio/StrengthSummaryContent.
struct TimedSummaryContent: View {
    let workout: Workout
    var showsHeader: Bool = true
    var canEditPhoto: Bool = false
    /// The save screen owns an EDITABLE calorie row — it hides this read-only one so the number
    /// doesn't appear twice. History keeps it.
    var showsCalories: Bool = true
    /// Added to every reveal below — see `CardioSummaryContent.revealDelay`. History passes 0.
    var revealDelay: Double = 0
    /// Post-workout only (the save flow passes true): "checked off your plan" speaks in the
    /// present tense — true at the finish line, stale on a session opened from History.
    var showsPlanLine: Bool = false

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            if showsHeader { header.reveal(revealDelay) }
            hero.reveal(revealDelay + 0.08)
            if let planLine {
                EarnedLine(text: planLine, systemImage: "calendar.badge.checkmark")
                    .reveal(revealDelay + 0.14)
            }
            EarnedShareButton(workout: workout, title: "Share this session")
                .reveal(revealDelay + 0.20)
            WorkoutPhotoSection(workout: workout, canEdit: canEditPhoto)
                .reveal(revealDelay + 0.24)
            if !workout.note.isEmpty {
                Text(workout.note)
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .reveal(revealDelay + 0.28)
            }
        }
    }

    /// The plan connection at the payoff moment — same slot and language as the other summaries.
    private var planLine: String? {
        guard showsPlanLine, let s = workout.plannedSession else { return nil }
        let kind = s.workoutType?.title.lowercased() ?? "session"
        let prefix = Calendar.current.isDateInToday(s.date)
            ? "Today’s" : "\(s.date.formatted(.dateTime.weekday(.wide)))’s"
        return "\(prefix) \(kind): checked off your plan."
    }

    /// The activity's identity — its glyph on the earned-iridescent stage (this is the timed
    /// sport's map slot), with the session's name and date.
    private var header: some View {
        VStack(spacing: Theme.Space.sm) {
            ZStack {
                Circle().fill(LinearGradient(colors: Theme.iridescent.map { $0.opacity(0.25) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                Image(systemName: workout.type.systemImage)
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink)
            }
            Text(workout.title.isEmpty ? workout.type.title : workout.title)
                .font(.display(Theme.FontSize.title, weight: .black)).foregroundStyle(Theme.ink)
            Text(workout.startedAt.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
    }

    /// The duration hero with the shared count-up reveal, over an equal-width row of whatever the
    /// session actually measured — no boxed card, the same open hero every summary leads with.
    private var hero: some View {
        VStack(spacing: Theme.Space.lg) {
            CountUpHero(target: workout.durationS,
                        format: { Formatters.duration(s: $0) },
                        label: "Duration",
                        delay: revealDelay)
            let stats = statEntries
            if !stats.isEmpty {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    ForEach(stats, id: \.label) { entry in
                        stat(entry.value, entry.label)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.md)
    }

    /// Present-only stats: a yoga session shows effort and calories; the stationary e-bike adds
    /// its console readouts (distance, speed, climb) — other timed sports never carry a gps payload.
    private var statEntries: [(value: String, label: String)] {
        var out: [(String, String)] = []
        let unit = DistanceUnit.auto
        if let gps = workout.gps, gps.distanceM > 0 {
            out.append((Formatters.distance(meters: gps.distanceM, unit: unit), "Distance"))
            if gps.avgSpeedMS > 0 { out.append((Formatters.speed(ms: gps.avgSpeedMS, unit: unit), "Avg speed")) }
            if gps.elevationGainM > 0 { out.append((Formatters.elevation(meters: gps.elevationGainM, unit: unit), "Climb")) }
        }
        if let effort = workout.perceivedEffort { out.append(("\(effort)/10", "Effort")) }
        if showsCalories, let kcal = workout.calories, kcal > 0 { out.append(("\(Int(kcal))", "Calories")) }
        return out
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
