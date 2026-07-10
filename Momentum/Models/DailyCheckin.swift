import Foundation
import SwiftData

/// The 10-second morning check-in (ENDURANCE-FOCUS §8.2) — the athlete-reported half of readiness.
/// Wearables say what the body did; this says how it feels. Feeds the daily adaptation as warning
/// signals; pain routes straight into the injury loop.
@Model
final class DailyCheckin {
    enum Energy: String, Codable, Sendable, CaseIterable, Identifiable {
        case low, ok, full
        var id: String { rawValue }
        // Chip-length labels — all three must fit a third-width chip without scaling ("Running
        // on empty" overflowed its card).
        var label: String { switch self { case .low: "Drained"; case .ok: "Alright"; case .full: "Full tank" } }
        var icon: String { switch self { case .low: "battery.25percent"; case .ok: "battery.75percent"; case .full: "battery.100percent.bolt" } }
    }
    enum Legs: String, Codable, Sendable, CaseIterable, Identifiable {
        case fresh, ok, heavy, sore
        var id: String { rawValue }
        var label: String { switch self { case .fresh: "Fresh"; case .ok: "Normal"; case .heavy: "Heavy"; case .sore: "Sore" } }
    }

    var date: Date = Date()
    var energyRaw: String = Energy.ok.rawValue
    var legsRaw: String = Legs.ok.rawValue

    var energy: Energy { Energy(rawValue: energyRaw) ?? .ok }
    var legs: Legs { Legs(rawValue: legsRaw) ?? .ok }

    init() {}
    init(date: Date = Date(), energy: Energy, legs: Legs) {
        self.date = date
        self.energyRaw = energy.rawValue
        self.legsRaw = legs.rawValue
    }

    /// Today's check-in, if the athlete already answered.
    static func today(in checkins: [DailyCheckin], calendar: Calendar = .current, now: Date = Date()) -> DailyCheckin? {
        checkins.first { calendar.isDate($0.date, inSameDayAs: now) }
    }
}
