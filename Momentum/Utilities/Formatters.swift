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

    // MARK: Distance — up to 2 decimals, trailing zeros dropped so a clean prescription reads "6 mi"
    // / "3.5 mi" (not "6.00" / "3.50"), while a recorded run keeps its precision ("5.03 mi").
    static func distance(meters: Double, unit: DistanceUnit) -> String {
        let u = unit.resolved()
        let value = u == .imperial ? meters / metersPerMile : meters / 1000
        let suffix = u == .imperial ? "mi" : "km"
        let str: String
        if value >= 100 {
            str = String(Int(value.rounded()))
        } else {
            let hundredths = (value * 100).rounded() / 100
            if hundredths == hundredths.rounded() {
                str = String(Int(hundredths))                       // 6.00 → "6"
            } else if (hundredths * 10) == (hundredths * 10).rounded() {
                str = String(format: "%.1f", hundredths)            // 3.50 → "3.5"
            } else {
                str = String(format: "%.2f", hundredths)            // 5.03 → "5.03"
            }
        }
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

    // MARK: Compact number — "12.4k", "1.2M", or an integer below 1,000 (no unit)
    static func compact(_ value: Double) -> String {
        let v = abs(value)
        switch v {
        case 1_000_000...:
            return String(format: "%.1fM", value / 1_000_000)
        case 10_000...:
            return "\(Int((value / 1_000).rounded()))k"
        case 1_000...:
            return String(format: "%.1fk", value / 1_000)
        default:
            return String(Int(value.rounded()))
        }
    }
}
