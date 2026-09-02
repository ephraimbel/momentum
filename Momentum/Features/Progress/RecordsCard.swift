import SwiftUI
import SwiftData

/// The record book — the athlete's persisted lifetime bests with the date each was set (Progress →
/// You). Records are earned progress, so each value wears the iridescent accent. Renders nothing
/// until a first record exists (honest silence over an empty trophy case).
struct RecordsCard: View {
    var distanceUnit: DistanceUnit = .auto

    @Query private var records: [PersonalRecord]

    /// The segment-flip static cache (the HeatmapHistoryCard/HealthSegmentView pattern): this card
    /// remounts on every Trends visit, and `RecordsBook.currentBests` filters the full record list
    /// once per cardio type. Value types only, never SwiftData refs.
    @MainActor private static var cache: (key: Int, bests: [RecordsBook.Best])?

    /// Scalar signature over everything the displayed shelf reads. A direct record query is
    /// deliberate: inserts performed by the one-time backfill invalidate it immediately, whereas
    /// observing the profile did not reliably invalidate when only its `prs` relationship changed.
    private var recordsKey: Int {
        var h = Hasher()
        h.combine(records.count)
        for record in records {
            h.combine(record.type.rawValue)
            h.combine(record.value)
            h.combine(record.achievedAt)
        }
        return h.finalize()
    }

    /// Compute synchronously on the first populated query. The previous empty-state `.task`
    /// lived on an empty conditional view, so SwiftUI could elide the task that was required to
    /// make that very view non-empty—a cold record book could therefore hide forever.
    private var currentBests: [RecordsBook.Best] {
        let key = recordsKey
        if let cached = Self.cache, cached.key == key { return cached.bests }
        let computed = RecordsBook.currentBests(records)
        Self.cache = (key, computed)
        return computed
    }

    var body: some View {
        let rows = currentBests
        return Group {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("RECORD BOOK").font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, best in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                        row(best)
                    }
                }
            }
            .padding(Theme.Space.md)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        }
    }

    private func row(_ best: RecordsBook.Best) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(best.type.recordLabel)
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.sm)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value(best))
                    .font(.display(18, weight: .black)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(IridescentMaterial()).opacity(0.30))
                Text(best.achievedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.vertical, Theme.Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(best.type.recordLabel): \(value(best)), set \(best.achievedAt.formatted(date: .abbreviated, time: .omitted))")
    }

    private func value(_ best: RecordsBook.Best) -> String {
        switch best.type {
        case .fastest1k, .fastest5k, .fastest10k, .fastestHalf, .fastestMarathon, .fastest50k, .longestDuration:
            Formatters.duration(s: best.value)
        case .longestRun:
            Formatters.distance(meters: best.value, unit: distanceUnit)
        default:
            "\(Int(best.value))"
        }
    }
}
