import SwiftUI

/// The analytics colour system for the Progress page. Each metric *domain* owns exactly one ink,
/// borrowed from the validated `Theme.Health` set (CVD-separated, ≥3:1 on both surfaces) — so the
/// Trends charts read as distinct instruments, not one repeated squiggle. The doctrine holds:
/// marks wear the domain ink, structure/text/axes stay monochrome, iridescence stays the earned
/// "you are here" pop, and the free distance chart stays pure ink — colour arrives with Pro.
/// Heart-rate zones keep their five-band palette — a recognised convention.
enum MetricColor {

    // MARK: Trend direction — legible on the light card surface.
    /// Trending the good way (up for most metrics; down for aerobic drift).
    static let positive = Color(hex: "1FA45A")   // green
    /// Trending the wrong way.
    static let negative = Color(hex: "E5484D")   // red

    /// The legacy single accent — the light route periwinkle. Still the tint for surfaces that
    /// predate the domain inks (vitals sheets pass their own ink through `TrendChartCard`).
    static let chart = Color(hex: "8E9BF0")

    // MARK: Domain inks — one per metric family, sourced from Theme.Health so the whole app
    // colours each domain identically (Health segment, Trends charts, vitals strip sparklines).
    /// Fitness — VO₂ / CTL, the long game. Deep periwinkle.
    static let fitness = Theme.Health.sleepInk
    /// Load / strain — effort accumulated. Peach ink.
    static let load = Theme.Health.strainInk
    /// Pace / HR-derived speed metrics — crisp ice.
    static let pace = Theme.Health.vitalsInk
    /// Freshness / recovery-side reads — mint ink.
    static let fresh = Theme.Health.recoveryInk

    /// The five heart-rate zones, cool → hot (the Garmin/COROS convention).
    static let zones: [Color] = [
        Color(hex: "8A94A6"),  // Z1 recovery — slate
        Color(hex: "3B9EF5"),  // Z2 easy — blue
        Color(hex: "22B07A"),  // Z3 aerobic — green
        Color(hex: "F0913A"),  // Z4 threshold — orange
        Color(hex: "EE5B5B"),  // Z5 max — red
    ]

    static func zone(_ index1: Int) -> Color { zones[max(0, min(4, index1 - 1))] }

    /// The domain ink for a summary metric — the vitals-strip sparklines carry each family's hue.
    /// Cadence/climb stay monochrome (mechanics/terrain differentiate by form, not colour).
    static func of(_ kind: TrendAnalytics.SummaryMetric.Kind) -> Color {
        switch kind {
        case .fitness: fitness
        case .form: fresh
        case .load: load
        case .cadence, .climb: Theme.ink
        case .efficiency: pace
        }
    }
}
