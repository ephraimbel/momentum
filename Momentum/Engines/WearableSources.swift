import Foundation

/// Which device is actually feeding Apple Health — so the provenance line can say "your Oura ring"
/// instead of the generic "your connected wearable" (owner ask 2026-08-15).
///
/// Identification is by the HealthKit sample's `sourceRevision.source`: third-party wearables write
/// through their companion app (a stable bundle id per brand), while Apple Watch writes through the
/// private `com.apple.health.*` source whose *name* is the watch's own ("Ephraim's Apple Watch").
/// The iPhone itself writes through the same private prefix — it is not a wearable and maps to nil,
/// as does any app we don't recognize: an unknown source degrades the footnote to the generic
/// wording it always had, never to a wrong brand name.
///
/// Pure and table-driven so the mapping is a test, not a hope. Icons are SF Symbols chosen by FORM
/// FACTOR (ring, watch, band, bed) — never brand logos: the design system is Apple-native and
/// monochrome, and trademarked marks don't belong in the app anyway.
enum WearableKind: String, CaseIterable, Identifiable, Comparable {
    case appleWatch, garmin, oura, whoop, coros, polar, suunto, fitbit, eightSleep, withings

    var id: String { rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// How the footnote names it, mid-sentence ("…from your Oura ring and Apple Watch").
    var displayName: String {
        switch self {
        case .appleWatch: "Apple Watch"
        case .garmin: "Garmin"
        case .oura: "Oura ring"
        case .whoop: "Whoop"
        case .coros: "COROS"
        case .polar: "Polar"
        case .suunto: "Suunto"
        case .fitbit: "Fitbit"
        case .eightSleep: "Eight Sleep"
        case .withings: "Withings"
        }
    }

    /// The subtle glyph beside the line — form factor, not logo.
    var icon: String {
        switch self {
        case .oura: "circle.circle"                            // a ring
        case .whoop, .fitbit: "capsule.portrait"               // a band
        case .eightSleep: "bed.double"                         // a mattress
        case .withings: "scalemass"                            // a scale
        case .appleWatch, .garmin, .coros, .polar, .suunto: "applewatch"
        }
    }

    /// Brand keyword → kind, checked against BOTH the source bundle id and the source name
    /// (lowercased). Bundle ids are the stable signal (Garmin Connect is `com.garmin.connect.mobile`,
    /// Oura `com.ouraring.oura`, Whoop `com.whoop.iphone`…), the name is the fallback for brands
    /// whose bundle doesn't carry the brand word (COROS ships as `com.yf.smart.coros.dist`).
    private static let keywords: [(keyword: String, kind: WearableKind)] = [
        ("ouraring", .oura), ("oura", .oura),
        ("whoop", .whoop),
        ("garmin", .garmin),
        ("coros", .coros),
        ("polarflow", .polar), ("polar", .polar),
        ("suunto", .suunto),
        ("fitbit", .fitbit),
        ("eightsleep", .eightSleep), ("eight sleep", .eightSleep),
        ("withings", .withings),
    ]

    /// The pure mapping. `nil` means "not a wearable we can name" — the iPhone's own writes, our
    /// own app, and any unrecognized third-party app all land here, and the footnote stays generic.
    static func identify(bundleID: String?, name: String?) -> WearableKind? {
        let bundle = (bundleID ?? "").lowercased()
        let sourceName = (name ?? "").lowercased()

        // Apple's private health source covers both the Watch and the iPhone; only the name
        // separates them. Match the Watch by name so "Ephraim's Apple Watch" lands and "iPhone"
        // falls through to nil.
        if sourceName.contains("apple watch") { return .appleWatch }
        if bundle.hasPrefix("com.apple.health") { return nil }   // the iPhone itself, or Health

        for (keyword, kind) in keywords where bundle.contains(keyword) || sourceName.contains(keyword) {
            return kind
        }
        return nil
    }

    /// "your Oura ring", "your Apple Watch and Garmin", "your Oura ring, Whoop, and Apple Watch" —
    /// the fragment the footnote drops into its sentence. Order is the caller's (most samples
    /// first); empty input returns nil so the caller keeps its generic wording.
    static func phrase(for kinds: [WearableKind]) -> String? {
        let names = kinds.map(\.displayName)
        switch names.count {
        case 0: return nil
        case 1: return "your \(names[0])"
        case 2: return "your \(names[0]) and \(names[1])"
        default: return "your " + names.dropLast().joined(separator: ", ") + ", and \(names.last!)"
        }
    }
}
