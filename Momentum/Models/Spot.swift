import Foundation

/// A real-world place to run or hike — a park, trailhead, nature reserve, etc. — surfaced from map
/// data near the athlete (PRD §6, "suggest running/hiking spots"). A value type, not a SwiftData
/// model: spots are fetched fresh near the user, never persisted as the source of truth.
struct Spot: Identifiable, Sendable, Hashable {
    let id: String              // stable map id (Mapbox `mapbox_id`)
    let name: String
    let kind: SpotKind
    let point: GeoPoint
    let neighborhood: String?
    /// Great-circle metres from the athlete — filled in by `SpotRanker` at ranking time.
    var distanceM: Double
    /// How busy this spot is *with Momentum athletes*. Honest-presence (see [[social-layer]]): it
    /// only ever reflects our own community's real activity, never a fabricated crowd. `.unknown`
    /// until the community-heat source is switched on (designed in now, lights up as users grow).
    var popularity: SpotPopularity = .unknown
}

/// The kinds of outdoor spot we surface. Each maps to a Mapbox Search category and declares which
/// activities it suits, so the Run/Hike filter can include the right kinds.
enum SpotKind: String, Sendable, CaseIterable {
    case park, trail, natureReserve, forest, mountain, dogPark

    /// The Mapbox Search Box category id (verified to return results).
    var mapboxCategory: String {
        switch self {
        case .park: "park"
        case .trail: "trailhead"
        case .natureReserve: "nature_reserve"
        case .forest: "forest"
        case .mountain: "mountain"
        case .dogPark: "dog_park"
        }
    }

    var title: String {
        switch self {
        case .park: "Park"
        case .trail: "Trail"
        case .natureReserve: "Nature reserve"
        case .forest: "Forest"
        case .mountain: "Peak"
        case .dogPark: "Dog park"
        }
    }

    var systemImage: String {
        switch self {
        case .park: "tree.fill"
        case .trail: "figure.hiking"
        case .natureReserve: "leaf.fill"
        case .forest: "tree"
        case .mountain: "mountain.2.fill"
        case .dogPark: "pawprint.fill"
        }
    }

    /// Which activities this kind is good for — drives the Run/Hike filter.
    var goodFor: Set<SpotActivity> {
        switch self {
        case .park, .dogPark: [.run]
        case .trail, .natureReserve: [.run, .hike]
        case .forest, .mountain: [.hike]
        }
    }
}

/// The two activities a spot can be filtered by (cycling routes itself; strength has no spot).
enum SpotActivity: String, Sendable, CaseIterable, Identifiable {
    case run, hike
    var id: String { rawValue }
    var title: String { self == .run ? "Run" : "Hike" }
    var systemImage: String { self == .run ? "figure.run" : "figure.hiking" }
}

/// How popular a spot is with Momentum athletes. Deliberately a sum type, not a raw `Int`, so the UI
/// distinguishes "we don't know yet" from "0 runs" — and so the honest-heat layer can be switched on
/// without touching call sites (see `SpotPopularitySource`).
enum SpotPopularity: Sendable, Hashable {
    case unknown
    case community(runs: Int)

    /// A real, non-zero community signal worth surfacing as a "popular" badge.
    var isPopular: Bool { if case .community(let n) = self { return n > 0 } else { return false } }
    var runs: Int? { if case .community(let n) = self { return n } else { return nil } }
}
