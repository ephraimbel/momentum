import SwiftUI

/// The profile's award shelf, curated: the most recent wins first, then — when there's room —
/// the closest locked "next up" per collection, so the shelf always shows both what's been earned
/// and what's within reach. Pure and testable — no view logic.
struct AwardsShelf {
    struct Cell: Identifiable {
        let award: Award
        let earnedAt: Date?      // nil = locked "next up"
        let progress: Double?    // locked only
        var id: String { award.id }
    }

    let cells: [Cell]
    let earnedCount: Int
    let totalCount: Int

    static let maxCells = 6

    init(earned: [EarnedAward], snapshot: AwardsEngine.Snapshot, calendar: Calendar = .current) {
        let earnedIDs = Set(earned.map(\.awardID))
        var out: [Cell] = earned
            .sorted { $0.earnedAt > $1.earnedAt }
            .compactMap { row in
                AwardsCatalog.award(row.awardID).map { Cell(award: $0, earnedAt: row.earnedAt, progress: nil) }
            }
            .prefix(Self.maxCells).map { $0 }

        // Fill remaining slots with the chase: the lowest locked tier of each collection, closest
        // progress first — the shelf teases what falls next, never a summit forty tiers away.
        if out.count < Self.maxCells {
            let nextUp = Award.Collection.allCases
                .compactMap { collection -> Cell? in
                    let next = AwardsCatalog.awards(in: collection)
                        .filter { !earnedIDs.contains($0.id) }
                        .min { $0.tier < $1.tier }
                    guard let next else { return nil }
                    let p = AwardsEngine.progress(toward: next, in: snapshot, calendar: calendar)
                    return Cell(award: next, earnedAt: nil, progress: p?.fraction ?? 0)
                }
                .sorted { ($0.progress ?? 0) > ($1.progress ?? 0) }
            out += nextUp.prefix(Self.maxCells - out.count)
        }

        self.cells = out
        self.earnedCount = earnedIDs.count
        self.totalCount = AwardsCatalog.all.count
    }
}

/// One shelf/gallery cell: medallion + name + one quiet line (earned date, or how close it is).
struct AwardCell: View {
    let award: Award
    var earnedAt: Date?
    var progress: Double?
    var size: CGFloat = 88

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            AwardMedallion(award: award, earned: earnedAt != nil, size: size,
                           progress: earnedAt == nil ? progress : nil)
            VStack(spacing: 1) {
                Text(award.name)
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.4)
                    .foregroundStyle(earnedAt != nil ? Theme.ink : Theme.inkSecondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(subline)
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Earned coins say when; locked ones say how close (only once the chase is real).
    private var subline: String {
        if let earnedAt {
            return earnedAt.formatted(.dateTime.month(.abbreviated).day().year())
        }
        if let progress, progress >= 0.05 {
            return "\(Int((progress * 100).rounded()))%"
        }
        return " "   // keeps grid rows aligned
    }

    private var accessibilityText: String {
        if let earnedAt {
            return "\(award.name), earned \(earnedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        if let progress, progress >= 0.05 {
            return "\(award.name), locked, \(Int((progress * 100).rounded())) percent there"
        }
        return "\(award.name), locked"
    }
}
