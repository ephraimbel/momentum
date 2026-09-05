import Foundation
import SwiftData

/// Water belongs to hydration, never to the meal journal or food-quality score.
@Model
final class WaterEntry {
    var id: UUID = UUID()
    var drankAt: Date = Date()
    var amountMl: Double = 0

    init(amountMl: Double, drankAt: Date = Date()) {
        self.amountMl = amountMl
        self.drankAt = drankAt
    }

    static func total(_ entries: [WaterEntry], on day: Date, calendar: Calendar = .current) -> Double {
        entries.filter { !$0.isDeleted && calendar.isDate($0.drankAt, inSameDayAs: day) }
            .map(\.amountMl).filter { $0.isFinite && $0 > 0 }.reduce(0, +)
    }
}
