import Foundation

/// Distance/pace/speed display system (PRD §19). Storage is always SI; conversion happens here.
enum DistanceUnit: String, Sendable {
    case metric, imperial, auto

    /// Resolve `auto` from the current locale (imperial for US/UK-miles/Liberia/Myanmar).
    func resolved(locale: Locale = .current) -> DistanceUnit {
        guard self == .auto else { return self }
        let imperialRegions: Set<String> = ["US", "GB", "LR", "MM"]
        let region = locale.region?.identifier ?? "US"
        return imperialRegions.contains(region) ? .imperial : .metric
    }
}

enum WeightUnit: String, Sendable {
    case kg, lb

    static func `default`(locale: Locale = .current) -> WeightUnit {
        let imperialRegions: Set<String> = ["US", "GB"]
        return imperialRegions.contains(locale.region?.identifier ?? "US") ? .lb : .kg
    }
}

/// All user-facing number formatting. SI in, display string out.
enum Formatters {
    static let metersPerMile = 1609.344
    static let kgPerLb = 0.45359237
    static let lbPerKg = 2.2046226218

    // MARK: Pace — "m:ss /km|/mi", "--:--" when undefined
    static func pace(secPerKm: Double, unit: DistanceUnit) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "--:--" }
        let u = unit.resolved()
        let secPerUnit = u == .imperial ? secPerKm * (metersPerMile / 1000) : secPerKm
        let total = Int(secPerUnit.rounded())
        let suffix = u == .imperial ? "/mi" : "/km"
        return "\(total / 60):\(String(format: "%02d", total % 60)) \(suffix)"
    }

    // MARK: Speed — km/h|mph, 1 decimal
    static func speed(ms: Double, unit: DistanceUnit) -> String {
        guard ms.isFinite, ms >= 0 else { return "0.0" }
        let u = unit.resolved()
        let value = u == .imperial ? ms * 2.2369362920544 : ms * 3.6
        let suffix = u == .imperial ? "mph" : "km/h"
        return String(format: "%.1f %@", value, suffix)
    }

    // MARK: Distance — 2 decimals < 100, else integer
    static func distance(meters: Double, unit: DistanceUnit) -> String {
        let u = unit.resolved()
        let value = u == .imperial ? meters / metersPerMile : meters / 1000
        let suffix = u == .imperial ? "mi" : "km"
        let str = value < 100 ? String(format: "%.2f", value) : String(Int(value.rounded()))
        return "\(str) \(suffix)"
    }

    // MARK: Weight — rounded to nearest 0.5 kg or 1 lb
    static func weight(kg: Double, unit: WeightUnit) -> String {
        switch unit {
        case .kg:
            let rounded = (kg * 2).rounded() / 2
            let str = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return "\(str) kg"
        case .lb:
            let lb = (kg * lbPerKg).rounded()
            return "\(Int(lb)) lb"
        }
    }

    // MARK: Duration — H:MM:SS or M:SS
    static func duration(s: Double) -> String {
        let total = Int(max(0, s).rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    // MARK: Time of day
    static func clock(date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
