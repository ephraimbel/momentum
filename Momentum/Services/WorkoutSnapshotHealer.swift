import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Renders and persists the route map snapshot for saved workouts that are missing one.
///
/// The snapshot is normally rendered once at run-finish — but that single render can fail (radio
/// still flaky right after an outdoor run, one bad tile fetch) and the workout was then stuck with
/// a route-silhouette tile in the profile grid and History forever (user report 2026-07-11). Every
/// display surface now self-heals: tiles request a render on appearance, and a launch sweep fixes
/// the most recent stragglers so History thumbnails recover without being visited individually.
@MainActor
enum WorkoutSnapshotHealer {
    private static var inFlight: Set<UUID> = []
    /// Workouts that failed to render this session — retried next launch, not per appearance.
    private static var failed: Set<UUID> = []
    /// At most this many live render engines at once (same guard as the community feed).
    private static let maxConcurrent = 2
    private static var active = 0

    /// Render + persist the snapshot for one workout, if it's missing and a route exists.
    /// Renders with the workout's own map style (save-screen choice, else the app-wide style) and
    /// STAMPS that style so the workout's map identity never drifts with later app-style changes.
    static func healIfNeeded(_ workout: Workout, context: ModelContext) async {
        guard let gps = workout.gps, gps.mapSnapshotData == nil else { return }
        let id = workout.id
        // Cheap Set dedupe BEFORE deriving coordinates: a failed-this-session workout otherwise
        // re-paid the full sample fault + Kalman walk on every tile appearance just to bail here.
        guard !inFlight.contains(id), !failed.contains(id) else { return }
        let coords = gps.routeCoordinates(type: workout.type)
        guard coords.count > 1 else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        while active >= maxConcurrent { do { try await Task.sleep(for: .milliseconds(150)) } catch { return } }
        active += 1
        let style = gps.mapStyle
        // Card on the clean canvas; the workout's own style is stamped for the interactive pager.
        let data = await RouteSnapshotter.snapshot(coordinates: coords,
                                                   size: RouteSnapshotter.workoutTileSize,
                                                   styleURI: RouteSnapshotter.tileStyle,
                                                   insets: RouteSnapshotter.workoutTileInsets)
        active -= 1
        guard let data else { failed.insert(id); return }
        gps.mapSnapshotData = data
        gps.mapSnapshotVersion = RouteSnapshotter.renderVersion
        gps.mapStyleRaw = style.rawValue
        try? context.save()
    }

    /// One pass over the most recent GPS workouts missing their snapshot — run once per launch so
    /// History thumbnails heal without each workout being opened. Bounded: old stragglers heal
    /// when their tile appears.
    static func sweep(in context: ModelContext, limit: Int = 12) async {
        var descriptor = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 200
        guard let recent = try? context.fetch(descriptor) else { return }
        // Legacy stamp: workouts saved before per-run styles have no recorded style, so their live
        // maps (pager, detail) drifted to whatever the athlete's CURRENT app style is — mismatching
        // their own tile. Pin them once to the present app style (the style their snapshot was
        // rendered against); from here on, changing the Today map never re-skins old runs.
        let appStyle = MapStyleOption.persisted.rawValue
        var stamped = false
        for workout in recent where workout.type.isGPS {
            if let gps = workout.gps, gps.mapStyleRaw == nil {
                gps.mapStyleRaw = appStyle
                stamped = true
            }
        }
        if stamped { try? context.save() }
        let stale = recent.filter { $0.type.isGPS && $0.gps != nil && $0.gps?.mapSnapshotData == nil }
            .prefix(limit)
        for workout in stale {
            await healIfNeeded(workout, context: context)
        }
        // Look upgrade: re-render snapshots drawn by an older renderer (legacy landscape images,
        // the gradient-trace era, the tight-framing era) so the visible grid picks up the current
        // aesthetic — newest first, bounded per launch, no user action.
        let outdatedLook = recent.filter { workout in
            guard workout.type.isGPS, let gps = workout.gps, gps.mapSnapshotData != nil else { return false }
            return gps.mapSnapshotVersion < RouteSnapshotter.renderVersion
        }.prefix(limit)
        for workout in outdatedLook {
            await rerender(workout, style: workout.gps?.mapStyle ?? .persisted, context: context)
        }
    }

    /// Re-render a workout's snapshot in a NEW style (save-screen style change). Replaces the old
    /// image; on failure the previous snapshot is kept and the tile heals later.
    static func rerender(_ workout: Workout, style: MapStyleOption, context: ModelContext) async {
        guard let gps = workout.gps else { return }
        let id = workout.id
        // Same in-flight guard as `healIfNeeded`: the save screen's style change and a tile
        // appearing can both ask for the same workout, and two engines rendering one row raced to
        // write it.
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let coords = gps.routeCoordinates(type: workout.type)
        guard coords.count > 1 else { return }
        while active >= maxConcurrent { do { try await Task.sleep(for: .milliseconds(150)) } catch { return } }
        active += 1
        let data = await RouteSnapshotter.snapshot(coordinates: coords,
                                                   size: RouteSnapshotter.workoutTileSize,
                                                   styleURI: RouteSnapshotter.tileStyle,
                                                   insets: RouteSnapshotter.workoutTileInsets)
        active -= 1
        guard let data else { return }
        gps.mapSnapshotData = data
        gps.mapSnapshotVersion = RouteSnapshotter.renderVersion
        gps.mapStyleRaw = style.rawValue
        try? context.save()
    }
}
