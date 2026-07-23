import SwiftUI
import SwiftData

/// The trophy room — every award across the seven collections, earned coins in full metal, the
/// rest as quiet ghosts with their progress arcs. Pushed from the profile's Awards shelf.
struct AwardsGalleryView: View {
    @Query private var profiles: [UserProfile]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Query private var records: [PersonalRecord]
    @Query private var earned: [EarnedAward]
    @Environment(\.dismiss) private var dismiss

    /// Built once per data change in `.task` — snapshot assembly walks the full history and must
    /// never run in `body` (page-load rule). Locked-cell progress is precomputed into a dictionary
    /// here too: `AwardsEngine.progress` re-walks the activity list, and calling it per cell per
    /// render made the trophy-room scroll cost O(history × cells).
    @State private var snapshot: AwardsEngine.Snapshot?
    @State private var progressByID: [String: Double] = [:]
    @State private var builtForKey = -1
    @State private var detail: Award?

    /// Invalidation covers everything the snapshot reads: workouts, records (a new PR moves speed
    /// progress with no new workout), and earned rows (plan-based awards land without either).
    private var dataKey: Int {
        var h = Hasher()
        h.combine(workouts.count); h.combine(records.count); h.combine(earned.count)
        return h.finalize()
    }

    private var earnedByID: [String: EarnedAward] {
        Dictionary(earned.map { ($0.awardID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                summary
                ForEach(Award.Collection.allCases) { collection in
                    section(for: collection)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) { header }
        .task(id: dataKey) {
            guard builtForKey != dataKey else { return }
            let snap = AwardsBook.snapshot(workouts: workouts, records: records,
                                           plan: profiles.first?.plan)
            let earnedIDs = Set(earned.map(\.awardID))
            var map: [String: Double] = [:]
            for award in AwardsCatalog.all where !earnedIDs.contains(award.id) {
                map[award.id] = AwardsEngine.progress(toward: award, in: snap)?.fraction
            }
            snapshot = snap
            progressByID = map
            builtForKey = dataKey
        }
        .sheet(item: $detail) { award in
            AwardDetailSheet(award: award, earnedRow: earnedByID[award.id],
                             snapshot: snapshot,
                             distanceUnit: DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto)
                .presentationDetents([.medium])
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 32, height: 32, alignment: .leading)
            }
            .accessibilityLabel("Back")
            Spacer()
            Text("awards")
                .font(.display(Theme.FontSize.body, weight: .bold))
                .foregroundStyle(Theme.ink)
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.background)
    }

    /// The room's own reading: how much of the wall is filled, with an earned iridescent fill —
    /// count > 0 is achievement, so the accent is honest.
    private var summary: some View {
        let count = Set(earned.map(\.awardID)).count
        let total = AwardsCatalog.all.count
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(count)")
                    .font(.display(40, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                Text("of \(total) earned")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    if count > 0 {
                        Capsule()
                            .fill(IridescentMaterial())
                            .frame(width: max(6, geo.size.width * Double(count) / Double(max(1, total))))
                    }
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) of \(total) awards earned")
    }

    // MARK: Collections

    private func section(for collection: Award.Collection) -> some View {
        let awards = AwardsCatalog.awards(in: collection)
        let earnedHere = awards.filter { earnedByID[$0.id] != nil }.count
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title.uppercased())
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                        .foregroundStyle(Theme.inkTertiary)
                    Text(collection.subtitle)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Text("\(earnedHere)/\(awards.count)")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                    .foregroundStyle(earnedHere > 0 ? Theme.ink : Theme.inkTertiary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3),
                      spacing: Theme.Space.md) {
                ForEach(awards) { award in
                    let row = earnedByID[award.id]
                    AwardCell(award: award, earnedAt: row?.earnedAt,
                              progress: row == nil ? lockedProgress(award) : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { detail = award }
                }
            }
        }
    }

    private func lockedProgress(_ award: Award) -> Double? {
        progressByID[award.id]
    }
}

// MARK: - Detail sheet

/// One award, up close: the coin at full size, the earn condition, and either when it fell (plus
/// the workout that sealed it) or exactly how close it is.
struct AwardDetailSheet: View {
    let award: Award
    var earnedRow: EarnedAward?
    var snapshot: AwardsEngine.Snapshot?
    var distanceUnit: DistanceUnit = .auto
    @Environment(\.dismiss) private var dismiss

    private var progress: AwardsEngine.Progress? {
        guard earnedRow == nil, let snapshot else { return nil }
        return AwardsEngine.progress(toward: award, in: snapshot)
    }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Capsule().fill(Theme.hairline).frame(width: 36, height: 4)
                .padding(.top, Theme.Space.sm)
            Spacer()

            AwardMedallion(award: award, earned: earnedRow != nil, size: 168,
                           progress: earnedRow == nil ? progress?.fraction : nil)

            VStack(spacing: Theme.Space.xs) {
                Text(award.name)
                    .font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                Text(award.requirement)
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Space.xl)

            if let earnedRow {
                EarnedLine(text: earnedText(earnedRow), systemImage: "checkmark.seal.fill", earned: true)
            } else {
                lockedReading
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    private func earnedText(_ row: EarnedAward) -> String {
        let date = row.earnedAt.formatted(date: .abbreviated, time: .omitted)
        if let title = row.workout?.title, !title.isEmpty {
            return "Earned \(date) · \(title)"
        }
        return "Earned \(date)"
    }

    /// The honest distance-to-go, in the athlete's own units where units apply.
    private var lockedReading: some View {
        VStack(spacing: Theme.Space.sm) {
            if let progress, progress.fraction > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(Theme.ink)
                            .frame(width: max(4, geo.size.width * progress.fraction))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, Theme.Space.xl)
            }
            Text(progressText)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private var progressText: String {
        guard let progress else { return "Not yet — keep moving" }
        switch progress.unit {
        case .meters:
            let current = Formatters.distance(meters: progress.current, unit: distanceUnit)
            let target = Formatters.distance(meters: progress.target, unit: distanceUnit)
            // Climb awards are meter-defined (Everest is 8,849 m in any hemisphere).
            if award.collection == .climb {
                return "\(Int(progress.current)) of \(Int(progress.target)) m climbed"
            }
            return "\(current) of \(target)"
        case .seconds:
            // Time on Feet climbs toward a duration; Speed chases one down.
            if award.collection == .endurance {
                return "Longest \(Formatters.duration(s: progress.current)) of \(Formatters.duration(s: progress.target))"
            }
            guard progress.current > 0 else { return "No benchmark time yet" }
            return "Best \(Formatters.duration(s: progress.current)) · target \(Formatters.duration(s: progress.target))"
        case .days:
            return "\(Int(progress.current)) of \(Int(progress.target)) days"
        case .count:
            return "\(Int(progress.current)) of \(Int(progress.target))"
        case .kilograms:
            return "\(Formatters.compact(progress.current)) of \(Formatters.compact(progress.target)) kg"
        }
    }
}
