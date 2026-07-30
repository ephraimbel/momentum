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
    var coordinates: [CLLocationCoordinate2D] {
        pts.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }
    var mapStyle: MapStyleOption { MapStyleOption(rawValue: mapStyleRaw) ?? .standard }
    var sport: WorkoutType { WorkoutType(rawValue: sportRaw) ?? .run }
    var hasRoute: Bool { !pts.isEmpty }
}
