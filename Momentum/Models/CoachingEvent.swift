import Foundation
import SwiftData

/// A recorded coaching decision — an easing, a recovery insertion, or a pace recalibration — so the
/// athlete can see *why* their plan changed over time (the adaptation history on Progress). This makes
/// the closed coaching loop legible: the plan doesn't just quietly shift, it explains itself and keeps
/// the receipt.
@Model
final class CoachingEvent {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case ease          // block eased (subjective RPE or objective load)
        case recover       // next session turned into a recovery day
        case recalibrate   // paces got faster off a strong run

        var systemImage: String {
            switch self {
            case .ease: "arrow.down.right.circle"
            case .recover: "moon.zzz"
            case .recalibrate: "gauge.with.dots.needle.67percent"
            }
        }
    }

    var id: UUID = UUID()
    var date: Date = Date()
    var kindRaw: String = CoachingEvent.Kind.ease.rawValue
    var headline: String = ""
    var detail: String = ""

    var kind: Kind { Kind(rawValue: kindRaw) ?? .ease }

    init(kind: Kind, headline: String, detail: String, date: Date) {
        self.kindRaw = kind.rawValue
        self.headline = headline
        self.detail = detail
        self.date = date
    }

    /// Log a coaching decision. Deduped: skips if the same kind was already recorded today (the
    /// ≤1/week adaptation gates mean this rarely collides, but a same-day recalibrate + ease shouldn't
    /// double-log the same nudge).
    static func record(kind: Kind, headline: String, detail: String, on date: Date, in context: ModelContext,
                       calendar: Calendar = .current) {
        let dayStart = calendar.startOfDay(for: date)
        let existing = (try? context.fetch(FetchDescriptor<CoachingEvent>())) ?? []
        let dup = existing.contains { $0.kindRaw == kind.rawValue && calendar.isDate($0.date, inSameDayAs: dayStart) }
        guard !dup else { return }
        context.insert(CoachingEvent(kind: kind, headline: headline, detail: detail, date: date))
    }
}
