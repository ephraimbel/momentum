import SwiftUI
import SwiftData

/// Reusable strength summary body (PRD §4.4), on the shared post-activity page grammar
/// (2026-08-13 — the Strava-shaped order every discipline now follows): hero numbers, the plan
/// connection, then the session's IDENTITY VISUAL — a run leads with its route map; a lifting
/// session leads with the worked body — then records, share, the AI read, and the analysis
/// detail (exercise breakdown, week context). No navigation chrome of its own.
struct StrengthSummaryContent: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var celebratePRs: Bool = false
    /// Show the user's title/description header (off in the save editor, which has editable fields).
    var showsHeader: Bool = true
    var canEditPhoto: Bool = false
    /// Added to every reveal below, so the cascade waits for the celebration beat playing over it.
    /// See `CardioSummaryContent.revealDelay`. History passes 0 and reveals immediately.
    var revealDelay: Double = 0
    /// Post-workout only (the save flow passes true): "checked off your plan" speaks in the
    /// present tense — true at the finish line, stale on a session opened from History.
    var showsPlanLine: Bool = false

    @Environment(\.modelContext) private var context
    @State private var prs: [StrengthPRs.Hit] = []
    /// Which exercises are opened to their set-by-set detail (collapsed by default).
    @State private var expandedExercises: Set<Int> = []
    /// The session's seven-day window for the closing week card — fetched here (on the
    /// always-present task) and handed down; see `CardioSummaryContent.weekWorkouts`.
    @State private var weekWorkouts: [Workout] = []
    /// The plan connection at the payoff moment — same slot as the run summary's line.
    @State private var planLine: String?

    var body: some View {
        if let session = workout.strength {
            VStack(spacing: Theme.Space.lg) {
                if showsHeader, !workout.title.isEmpty || !workout.note.isEmpty { titleHeader }
                headline(workout, session)   // staggers its own children; no outer reveal
                if let planLine {
                    EarnedLine(text: planLine, systemImage: "calendar.badge.checkmark")
                        .reveal(revealDelay + 0.08)
                }
                // The session's identity visual, directly under the hero — the same slot the run
                // page gives its route map. It used to sit mid-page, below the AI read.
                muscleCard(session).reveal(revealDelay + 0.12)
                if !prs.isEmpty { prSection.reveal(revealDelay + 0.16) }
                // Always offered — see CardioSummaryView. The title stays honest: a session with no
                // record on it is worth sharing, but it isn't a PR and must not claim to be.
                EarnedShareButton(workout: workout, weightUnit: weightUnit,
                                  title: prs.isEmpty ? "Share this session" : "Share your PR").reveal(revealDelay + 0.20)
                WorkoutPhotoSection(workout: workout, canEdit: canEditPhoto).reveal(revealDelay + 0.24)
                AIReadCard(workout: workout, weightUnit: weightUnit).reveal(revealDelay + 0.30)
                PlanProposalCard().reveal(revealDelay + 0.34)
                exercisesSection(session).reveal(revealDelay + 0.38)
                // The week the session lands in, measured in the discipline's own currency
                // (tonnage) — the same closing beat as the run page.
                WeekContextCard(anchor: workout.startedAt, weekWorkouts: weekWorkouts,
                                metric: .volume, weightUnit: weightUnit).reveal(revealDelay + 0.42)
            }
            .task {
                prs = StrengthPRs.detect(for: workout, weightUnit: weightUnit, in: context)
                if showsPlanLine, let s = workout.plannedSession {
                    let kind: String
                    if s.discipline == .strength {
                        let split = StrengthSplit.title(forPlanned: s)
                        kind = split == "Strength" ? "strength session" : split.lowercased()
                    } else {
                        kind = s.workoutType?.title.lowercased() ?? "session"
                    }
                    planLine = "\(dayPrefix(s.date)) \(kind): checked off your plan."
                }
                if let desc = WeekContextCard.windowDescriptor(anchor: workout.startedAt) {
                    weekWorkouts = (try? context.fetch(desc)) ?? []
                }
            }
        } else {
            Text("No strength data").foregroundStyle(Theme.inkTertiary)
        }
    }

    /// One self-relative line that frames the session as progress — drawn from this workout's PRs.
    private var competenceText: String? {
        guard !prs.isEmpty else { return nil }
        if prs.count == 1 { return "\(prs[0].exerciseName) \(prs[0].label) · \(prs[0].detail)" }
        return "\(prs.count) personal records today"
    }

    private func dayPrefix(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "Today’s" : "\(date.formatted(.dateTime.weekday(.wide)))’s"
    }

    private func headline(_ workout: Workout, _ session: StrengthSession) -> some View {
        let volume = weightUnit == .lb ? session.totalVolumeKg * Formatters.lbPerKg : session.totalVolumeKg
        // Staggered internally, matching the run hero: the number lands, then what it meant,
        // then the detail row.
        return VStack(spacing: Theme.Space.lg) {
            CountUpHero(target: volume,
                        format: { Int($0.rounded()).formatted() },
                        label: "Volume (\(weightUnit == .lb ? "lb" : "kg"))",
                        delay: revealDelay)
                .reveal(revealDelay)
            if let competenceText { EarnedLine(text: competenceText).reveal(revealDelay + 0.14) }
            HStack(alignment: .top, spacing: Theme.Space.md) {
                stat("\(session.totalSets)", "Sets")
                stat(Formatters.duration(s: workout.durationS), "Duration")
                stat("\(session.exercises.count)", "Exercises")
                if let kcal = workout.calories, kcal > 0 { stat("\(Int(kcal))", "Calories") }
            }
            .reveal(revealDelay + 0.22)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.md)
    }

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if !workout.title.isEmpty {
                Text(workout.title).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
            }
            if !workout.note.isEmpty {
                Text(workout.note).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            // Scale, never wrap — the 4-up row ("EXERCISES" et al.) breaks baseline alignment on
            // an SE otherwise (mirrors CardioSummaryContent's stat).
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var prSection: some View {
        VStack(spacing: Theme.Space.sm) {
            ForEach(prs) { hit in
                PRBadge(text: "\(hit.exerciseName) · \(hit.label) \(hit.detail)", celebrate: celebratePRs)
            }
        }
    }

    // MARK: Identity visual — the worked body

    /// The worked body on its iridescent stage (`IridescentWash` is earned here — it only ever
    /// backs a completed session's worked muscles), with the per-muscle working-set tally
    /// beneath the figure.
    private func muscleCard(_ session: StrengthSession) -> some View {
        let entries = session.exercises.map { row in
            (primary: (row.exercise?.primaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             secondary: (row.exercise?.secondaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             sets: row.sets.filter { $0.isComplete && $0.type == .working }.count)
        }
        let activation = StrengthMath.weeklySetsByMuscle(entries)
        let byMuscle = activation
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        return VStack(spacing: Theme.Space.md) {
            MuscleMapView(activation: activation)
                .frame(height: 250)
                .frame(maxWidth: .infinity)
            if !byMuscle.isEmpty {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(byMuscle, id: \.key) { muscle, sets in
                        HStack {
                            Text(muscle.rawValue.capitalized).foregroundStyle(Theme.ink)
                            Spacer()
                            Text(sets == sets.rounded() ? "\(Int(sets)) sets" : String(format: "%.1f sets", sets))
                                .monospacedDigit().foregroundStyle(Theme.inkSecondary)
                        }
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    }
                }
            }
        }
        .padding(Theme.Space.md)
        .background(IridescentWash())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline))
    }

    // MARK: Exercise breakdown — the splits grammar, spoken in iron

    /// One row per exercise: name, session volume, and a bar whose LENGTH is that volume (the
    /// session's biggest lift = full width) — the same reading as the run page's split rows. An
    /// exercise that set a record wears the earned accent on its bar. Tap a row to open the
    /// set-by-set story; a five-exercise session must never read as a thirty-row wall.
    private func exercisesSection(_ session: StrengthSession) -> some View {
        let rows = session.exercises.sorted { $0.order < $1.order }
        let workingByRow: [[SetEntry]] = rows.map { row in
            row.sets.filter { $0.isComplete && $0.type == .working }.sorted { $0.index < $1.index }
        }
        let volumes: [Double] = workingByRow.map { sets in
            sets.reduce(0) { $0 + (($1.weightKg ?? 0) * Double($1.reps ?? 0)) }
        }
        let maxVolume = volumes.max() ?? 0
        let prNames = Set(prs.map(\.exerciseName))
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                sectionTitle("Exercises")
                Spacer()
                Text("\(session.totalSets) sets")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.persistentModelID) { i, row in
                exerciseCard(row, working: workingByRow[i], volumeKg: volumes[i],
                             maxVolumeKg: maxVolume,
                             hitPR: prNames.contains(row.exercise?.name ?? ""), index: i)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exerciseCard(_ row: WorkoutExercise, working: [SetEntry], volumeKg: Double,
                              maxVolumeKg: Double, hitPR: Bool, index: Int) -> some View {
        let expanded = expandedExercises.contains(index)
        let name = row.exercise?.name ?? "Exercise"
        let best = bestSet(working)
        let subtitle = working.isEmpty
            ? "No working sets"
            : "\(working.count) set\(working.count == 1 ? "" : "s")\(best.map { " · best \(setString($0))" } ?? "")"
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button {
                guard !working.isEmpty else { return }
                Haptics.selection()
                withAnimation(Motion.standard) {
                    if expanded { expandedExercises.remove(index) } else { expandedExercises.insert(index) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.rounded(Theme.FontSize.body, weight: .bold))
                                .foregroundStyle(Theme.ink)
                            Text(subtitle)
                                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        Spacer()
                        Text(volumeString(volumeKg))
                            .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Theme.ink)
                        if !working.isEmpty {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.inkTertiary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                    }
                    // The volume bar — a record wears the earned accent, everything else stays ink.
                    GeometryReader { geo in
                        Capsule()
                            .fill(hitPR ? AnyShapeStyle(IridescentMaterial())
                                        : AnyShapeStyle(Theme.ink.opacity(0.55)))
                            .frame(width: max(10, geo.size.width * (maxVolumeKg > 0 ? volumeKg / maxVolumeKg : 0)))
                    }
                    .frame(height: 10)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue("\(subtitle), volume \(volumeString(volumeKg))\(hitPR ? ", personal record" : "")")
            .accessibilityHint(working.isEmpty ? "" : (expanded ? "Hides each set" : "Shows each set"))
            if expanded {
                setRows(working)
                    .transition(.opacity)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
    }

    /// The expanded set-by-set story — ordinal, weight × reps, and a bar sized by set volume;
    /// the best set (top e1RM) reads bolder.
    private func setRows(_ working: [SetEntry]) -> some View {
        let volumes = working.map { (($0.weightKg ?? 0) * Double($0.reps ?? 0)) }
        let maxVol = volumes.max() ?? 0
        let bestIdx = bestSetIndex(working)
        return VStack(spacing: 7) {
            ForEach(Array(working.enumerated()), id: \.offset) { i, s in
                HStack(spacing: Theme.Space.sm) {
                    Text("\(i + 1)")
                        .font(.rounded(11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 26, alignment: .trailing)
                    Text(setString(s))
                        .font(.rounded(12, weight: i == bestIdx ? .bold : .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(width: 110, alignment: .trailing)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Theme.ink.opacity(i == bestIdx ? 0.55 : 0.28))
                            .frame(width: max(10, geo.size.width * (maxVol > 0 ? volumes[i] / maxVol : 0)))
                    }
                    .frame(height: 10)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Set \(i + 1), \(setString(s))\(i == bestIdx ? ", best set" : "")")
            }
        }
    }

    /// The set the athlete would quote — highest estimated one-rep max, not just heaviest bar.
    private func bestSetIndex(_ sets: [SetEntry]) -> Int? {
        let scores = sets.map { StrengthMath.e1RM(weightKg: $0.weightKg ?? 0, reps: $0.reps ?? 0) }
        guard let top = scores.max(), top > 0 else { return nil }
        return scores.firstIndex(of: top)
    }

    private func bestSet(_ sets: [SetEntry]) -> SetEntry? {
        bestSetIndex(sets).map { sets[$0] }
    }

    /// One set in the athlete's own terms — weight × reps for lifts, and honest fallbacks for the
    /// library's other logging modes (bodyweight reps, timed holds, carries) instead of "— × 0".
    private func setString(_ s: SetEntry) -> String {
        if let w = s.weightKg, let r = s.reps { return "\(Formatters.weight(kg: w, unit: weightUnit)) × \(r)" }
        if let r = s.reps { return "\(r) reps" }
        if let d = s.durationS, d > 0 { return Formatters.duration(s: d) }
        if let m = s.distanceM, m > 0 { return Formatters.distance(meters: m, unit: .auto) }
        return "—"
    }

    private func volumeString(_ kg: Double) -> String {
        let v = weightUnit == .lb ? kg * Formatters.lbPerKg : kg
        return "\(Int(v.rounded()).formatted()) \(weightUnit == .lb ? "lb" : "kg")"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.rounded(Theme.FontSize.label, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Theme.inkTertiary)
    }
}
