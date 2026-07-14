import SwiftUI

/// The analytics colour system for the Progress page. Kept intentionally restrained so the charts
/// read as one clean family, not a rainbow: every line/area/sparkline uses the app's light
/// periwinkle route accent, iridescence stays the "you are here / earned" pop on top, and the only
/// other colour is a legible green/red on the trend percentages. Heart-rate zones keep their
/// five-band palette — a recognised convention that classifies effort at a glance.
enum MetricColor {

    // MARK: Trend direction — legible on the light card surface.
    /// Trending the good way (up for most metrics; down for aerobic drift).
    static let positive = Color(hex: "1FA45A")   // green
    /// Trending the wrong way.
    static let negative = Color(hex: "E5484D")   // red

    /// The single chart accent — the light route periwinkle, nudged a shade deeper/more saturated
    /// than `Theme.route` (#B8C0FF) so a thin line reads clearly on the light card without losing
    /// its light-purple character. Area fills + sparkline washes stay soft via low opacity.
    static let chart = Color(hex: "8E9BF0")

    /// The five heart-rate zones, cool → hot (the Garmin/COROS convention).
    static let zones: [Color] = [
        Color(hex: "8A94A6"),  // Z1 recovery — slate
        Color(hex: "3B9EF5"),  // Z2 easy — blue
        Color(hex: "22B07A"),  // Z3 aerobic — green
        Color(hex: "F0913A"),  // Z4 threshold — orange
        Color(hex: "EE5B5B"),  // Z5 max — red
    ]

    static func zone(_ index1: Int) -> Color { zones[max(0, min(4, index1 - 1))] }

    /// Every summary metric shares the one chart accent.
    static func of(_ kind: TrendAnalytics.SummaryMetric.Kind) -> Color { chart }
}
