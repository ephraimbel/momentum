import Foundation

/// Where a VO₂max sits against population norms, so a number becomes a judgement the athlete
/// understands ("Good for your age", not just "48.2"). Age- and sex-banded cut points approximate the
/// Cooper Institute / ACSM fitness norms (ml·kg⁻¹·min⁻¹). Pure + testable. No medical claim — a fitness
/// bucket, not a diagnosis.
enum VO2maxNorms {
    enum Rating: String, Sendable, CaseIterable {
        case poor = "Poor", fair = "Fair", good = "Good", excellent = "Excellent", superior = "Superior"
    }

    /// The four cut points [fair, good, excellent, superior] separating the five ratings.
    static func thresholds(age: Int, male: Bool) -> [Double] {
        let band = age < 30 ? 0 : age < 40 ? 1 : age < 50 ? 2 : age < 60 ? 3 : 4
        let men: [[Double]]   = [[38, 44, 51, 56], [36, 42, 48, 53], [34, 40, 45, 50], [30, 36, 42, 46], [26, 32, 37, 42]]
        let women: [[Double]] = [[32, 38, 44, 49], [30, 36, 41, 45], [28, 33, 38, 43], [25, 30, 35, 39], [22, 27, 32, 36]]
        return (male ? men : women)[band]
    }

    static func rating(vo2: Double, age: Int, male: Bool) -> Rating {
        let t = thresholds(age: age, male: male)
        switch vo2 {
        case ..<t[0]: return .poor
        case ..<t[1]: return .fair
        case ..<t[2]: return .good
        case ..<t[3]: return .excellent
        default:      return .superior
        }
    }

    /// Normalized 0…1 position for a range bar — a floor a little below the Poor cut, a ceiling a little
    /// above the Superior cut, so the marker never pins to an edge.
    static func position(vo2: Double, age: Int, male: Bool) -> Double {
        let t = thresholds(age: age, male: male)
        let lo = t.first! - 8, hi = t.last! + 8
        return max(0, min(1, (vo2 - lo) / (hi - lo)))
    }

    /// A friendly one-liner for the rating.
    static func blurb(_ rating: Rating) -> String {
        switch rating {
        case .poor:      "Room to grow — every easy week builds it."
        case .fair:      "Below average for your age. Trending the right way."
        case .good:      "Above average for your age. Solid aerobic base."
        case .excellent: "Well above average for your age. Strong engine."
        case .superior:  "Elite for your age. Exceptional aerobic fitness."
        }
    }
}
