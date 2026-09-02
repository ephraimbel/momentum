import Foundation

/// Athlete-facing interpretation of the app's existing 7-day : recent-28-day load ratio.
///
/// `ProgressInsights` and `ACWRGovernor` still own the established math and protective behavior.
/// This type owns the language boundary: the ratio describes a change in training exposure; it is
/// not an injury prediction, a universal safe zone, or permission to add work. Keeping that boundary
/// in one pure type stops Progress, Recovery, Coach, and AI context from telling different stories.
enum TrainingLoadContext {
    enum Band: String, CaseIterable, Sendable, Equatable {
        case learning
        case lighterThanRecent
        case nearRecentNorm
        case aboveRecentNorm
        case muchAboveRecentNorm

        var displayName: String {
            switch self {
            case .learning: "Building baseline"
            case .lighterThanRecent: "Lighter than recent"
            case .nearRecentNorm: "Near recent norm"
            case .aboveRecentNorm: "Above recent norm"
            case .muchAboveRecentNorm: "Much above recent"
            }
        }
    }

    /// Existing operational bands, preserved so this truth/copy pass cannot change plan behavior.
    /// They are context labels—not physiological or injury-risk thresholds.
    static func band(ratio: Double, hasBaseline: Bool = true) -> Band {
        guard hasBaseline, ratio.isFinite, ratio > 0 else { return .learning }
        return switch ratio {
        case ..<0.8: .lighterThanRecent
        case 0.8..<1.3: .nearRecentNorm
        case 1.3..<1.5: .aboveRecentNorm
        default: .muchAboveRecentNorm
        }
    }

    static let methodExplanation =
        "Load change compares the last 7 days with the average week in your recent 28-day pattern. "
        + "It helps identify a change in training exposure, but it cannot predict injury or decide "
        + "whether a load is safe. Pain, illness, recovery signals, and how the work felt still matter."

    static func summary(ratio: Double, hasBaseline: Bool = true) -> String {
        let context = band(ratio: ratio, hasBaseline: hasBaseline)
        guard context != .learning else {
            return "Your recent training baseline is still taking shape. We will use your completed "
                + "sessions and feedback before drawing conclusions from load change."
        }

        let ratioText = String(format: "%.2f×", ratio)
        let observation: String = switch context {
        case .learning:
            ""
        case .lighterThanRecent:
            "lighter than your recent pattern"
        case .nearRecentNorm:
            "close to your recent pattern"
        case .aboveRecentNorm:
            "above your recent pattern"
        case .muchAboveRecentNorm:
            "much higher than your recent pattern"
        }
        return "Your last 7 days are \(ratioText) your recent weekly norm — \(observation). "
            + "Use that as context alongside recovery and how you feel."
    }
}
