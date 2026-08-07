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
        return "\(distanceNumeral(value)) \(u == .imperial ? "mi" : "km")"
    }

    /// The numeral alone, already in display units — for heroes that render the unit as a separate
    /// label beneath. Same rounding as `distance(meters:unit:)`, which is written in terms of it.
    static func distanceNumeral(_ value: Double) -> String {
        if value >= 100 { return String(Int(value.rounded())) }
        let hundredths = (value * 100).rounded() / 100
        if hundredths == hundredths.rounded() {
            return String(Int(hundredths))                          // 6.00 → "6"
        } else if (hundredths * 10) == (hundredths * 10).rounded() {
            return String(format: "%.1f", hundredths)               // 3.50 → "3.5"
        }
        return String(format: "%.2f", hundredths)                   // 5.03 → "5.03"
    }

    /// A numeral formatter for a count-up hero: the decimal places are chosen from the FINAL value
    /// and then held for every frame.
    ///
    /// Dropping trailing zeros per-frame the way `distanceNumeral` does would change the number's
    /// digit COUNT mid-animation ("3" → "3.1" → "3.14"), and the number would visibly change width
    /// as it counted. Tabular figures can't fix that — they equalise digit *width*, not how many
    /// there are. So a clean 5 km run counts "0 → 5", and a 4.45 counts "0.00 → 4.45".
    static func steadyNumeral(target: Double) -> (Double) -> String {
        let hundredths = (target * 100).rounded() / 100
        let places: Int
        if target >= 100 || hundredths == hundredths.rounded() {
            places = 0
        } else if (hundredths * 10) == (hundredths * 10).rounded() {
            places = 1
        } else {
            places = 2
        }
        return { String(format: "%.\(places)f", $0) }
    }

    /// Whole distance units for stat tiles that render the number and its unit separately — a big
    /// numeral above a small "mi · 12 wk" caption. Exists so a tile never hardcodes "km": doing that
    /// told every imperial athlete their mileage was kilometres, in an app whose default resolves to
    /// imperial for its largest market.
    static func wholeDistance(meters: Double, unit: DistanceUnit) -> (value: Int, unit: String) {
        let u = unit.resolved()
        let value = u == .imperial ? meters / metersPerMile : meters / 1000
        return (Int(value.rounded()), u == .imperial ? "mi" : "km")
    }

    // MARK: Elevation — whole feet or metres ("421 ft" / "128 m"). Exists so no surface hardcodes
    // "m" for gain/loss numbers: the summary tile did, telling every imperial athlete their climb
    // was metric in an app whose default resolves imperial for its largest market.
    static let feetPerMeter = 3.280839895
    static func elevation(meters: Double, unit: DistanceUnit) -> String {
        let u = unit.resolved()
        return u == .imperial ? "\(Int((meters * feetPerMeter).rounded())) ft"
                              : "\(Int(meters.rounded())) m"
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

    // MARK: Race countdown — one rule everywhere: days inside two weeks, weeks beyond
    /// "Race day" / "5 days to go" / "12 weeks to go". Every countdown surface (Plan header, race
    /// projection card, reveal) speaks this unit scheme so the same race never reads as "84 days"
    /// on one card and "12 weeks" on the next.
    static func raceCountdown(days: Int) -> String {
        switch days {
        case ..<1: return "Race day"
        case 1...13: return "\(days) day\(days == 1 ? "" : "s") to go"
        default: return "\(Int(ceil(Double(days) / 7.0))) weeks to go"
        }
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
