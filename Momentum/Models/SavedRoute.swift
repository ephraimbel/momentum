import Foundation
import SwiftData
import CoreLocation

/// A route bookmarked from a community post (2026-07-29) — the moment community content becomes
/// training material: see a loop you like on the wall, save it, run it later. Local-only for now
/// (a saved route is a private training note, not a social act — nothing publishes).
///
/// Additive schema entity (PersistenceController rule: new models are safe; new properties on
/// OLD models must be optional/defaulted).
@Model
final class SavedRoute {
    @Attribute(.unique) var id: UUID = UUID()
    /// The source post — dedupes saves and lets the pager's bookmark reflect saved state.
    var postID: UUID = UUID()
    var title: String = ""
    var authorName: String = ""
    var authorHandle: String?
    var city: String?
    var km: Double = 0
    /// [[lat, lon]] JSON — the exact drawn polyline (a bundled street loop, so the map is honest).
    /// Empty for a saved post with no route (a strength day, a swim) — see `sportRaw`.
    var ptsJSON: Data = Data()
    var mapStyleRaw: String = MapStyleOption.standard.rawValue
    var savedAt: Date = Date()
    /// The post's sport (WorkoutType rawValue). Every post is saveable (owner call 2026-07-30 —
    /// the rail is identical on every post), and a save without a route renders in the library
    /// as its sport glyph instead of a phantom silhouette. Defaulted: additive property on an
    /// existing model (PersistenceController rule), and every pre-existing save WAS a route.
    var sportRaw: String = WorkoutType.run.rawValue

    init(postID: UUID, title: String, authorName: String, authorHandle: String?,
         city: String?, km: Double, pts: [[Double]], mapStyle: MapStyleOption,
         sport: WorkoutType = .run) {
        self.id = UUID()
        self.postID = postID
        self.title = title
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.city = city
        self.km = km
        self.ptsJSON = (try? JSONEncoder().encode(pts)) ?? Data()
        self.mapStyleRaw = mapStyle.rawValue
        self.savedAt = Date()
        self.sportRaw = sport.rawValue
    }

    var pts: [[Double]] { (try? JSONDecoder().decode([[Double]].self, from: ptsJSON)) ?? [] }
    /// Reject malformed saved geometry as a whole; dropping a bad point could invent a shortcut.
    var coordinates: [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for pair in pts {
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite else { return [] }
            let point = CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            guard CLLocationCoordinate2DIsValid(point) else { return [] }
            if let last = result.last, last.latitude == point.latitude, last.longitude == point.longitude { continue }
            result.append(point)
        }
        return result
    }
    var mapStyle: MapStyleOption { MapStyleOption(rawValue: mapStyleRaw) ?? .standard }
    var sport: WorkoutType { WorkoutType(rawValue: sportRaw) ?? .run }
    var hasRoute: Bool { coordinates.count > 1 }
}
