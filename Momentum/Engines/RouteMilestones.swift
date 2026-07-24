import Foundation
import CoreLocation

/// Places the km/mile markers a finished route is annotated with (summary map, immersive pager) —
/// one badge per whole display unit, positioned by walking the **drawn** polyline. Deliberately the
/// display line, not the recorded samples: a marker's job is to sit on the line the athlete is
/// looking at, and the drawn line (splined, possibly map-matched) is what they see. The recorded
/// distance stays authoritative for every number; these are annotations, never a measurement
/// (PRD: distance is never re-derived from the line).
enum RouteMilestones {

    struct Milestone: Equatable {
        /// 1-based whole-unit index — the number printed in the badge ("1", "2", …).
        let index: Int
        let coordinate: CLLocationCoordinate2D

        static func == (lhs: Milestone, rhs: Milestone) -> Bool {
            lhs.index == rhs.index
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    /// Walk `coords` accumulating haversine distance and drop a milestone each `unitMeters`,
    /// linearly interpolating within the segment that crosses each boundary (segments are meters
    /// long, so linear lat/lon interpolation is exact to well under a meter).
    static func along(_ coords: [CLLocationCoordinate2D], unitMeters: Double) -> [Milestone] {
        guard unitMeters > 0, coords.count > 1 else { return [] }
        var milestones: [Milestone] = []
        var nextBoundaryM = unitMeters
        var cumulativeM = 0.0
        for k in 1..<coords.count {
            let a = coords[k - 1], b = coords[k]
            let segmentM = Geo.distance(lat1: a.latitude, lon1: a.longitude,
                                        lat2: b.latitude, lon2: b.longitude)
            // The 1 µm epsilon only absorbs float dust: a boundary that lands exactly on the
            // route's final vertex must still produce its marker (2999.999…9 vs 3000).
            while cumulativeM + segmentM >= nextBoundaryM - 1e-6 {
                let frac = segmentM > 0 ? (nextBoundaryM - cumulativeM) / segmentM : 0
                milestones.append(Milestone(
                    index: milestones.count + 1,
                    coordinate: CLLocationCoordinate2D(
                        latitude: a.latitude + frac * (b.latitude - a.latitude),
                        longitude: a.longitude + frac * (b.longitude - a.longitude))))
                nextBoundaryM += unitMeters
            }
            cumulativeM += segmentM
        }
        return milestones
    }
}
