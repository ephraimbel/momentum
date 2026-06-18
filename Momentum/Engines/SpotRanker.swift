import Foundation

/// Orders nearby spots for the athlete (PRD §6). Pure and deterministic — given the same spots, origin
/// and popularity it always returns the same order, so it's fully unit-testable. Annotates each spot
/// with its real distance + popularity, filters to the chosen activity and a sane radius, then sorts by
/// a blended score: **nearness leads, community popularity bumps** (the honest-heat layer, all
/// `.unknown` until that source ships — see [[social-layer]]).
enum SpotRanker {
    static func rank(_ spots: [Spot], from origin: GeoPoint, activity: SpotActivity?,
                     popularity: [String: SpotPopularity] = [:], maxRadiusM: Double = 40_000) -> [Spot] {
        spots.compactMap { spot -> Spot? in
            if let activity, !spot.kind.goodFor.contains(activity) { return nil }
            let d = origin.distance(to: spot.point)
            guard d <= maxRadiusM else { return nil }
            var ranked = spot
            ranked.distanceM = d
            ranked.popularity = popularity[spot.id] ?? .unknown
            return ranked
        }
        .sorted { lhs, rhs in
            let (l, r) = (score(lhs), score(rhs))
            if l != r { return l > r }
            return lhs.distanceM < rhs.distanceM      // stable tiebreak
        }
    }

    /// Higher surfaces first. Nearness is the primary signal; a popular spot gets a gentle, capped bump
    /// so a beloved trail slightly farther can edge out a dull park next door — but popularity never
    /// swamps distance.
    static func score(_ spot: Spot) -> Double {
        let nearness = 1.0 / (1.0 + spot.distanceM / 1000.0)        // 1.0 @0km, 0.5 @1km, 0.09 @10km
        let runs = Double(spot.popularity.runs ?? 0)
        let popBoost = runs > 0 ? min(0.4, log(1 + runs) / 12) : 0
        return nearness + popBoost
    }
}
