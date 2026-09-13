import CoreLocation
import Foundation
import SwiftData
import UIKit

/// Repairs route thumbnails without retaining SwiftData rows across suspension points.
/// A deletion, sign-out, or replaced GPS detail can happen during any map render.
@MainActor
enum WorkoutSnapshotHealer {
    private static var inFlight: Set<UUID> = []
    private static var failed: Set<UUID> = []
    private static let maxConcurrent = 2
    private static var active = 0

    typealias Renderer = @MainActor ([CLLocationCoordinate2D], MapStyleOption) async -> Data?

    static func healIfNeeded(_ workout: Workout, context: ModelContext) async {
        guard !workout.isDeleted, workout.modelContext === context else { return }
        await repair(workoutID: workout.id, in: context)
    }

    static func rerender(_ workout: Workout, style: MapStyleOption, context: ModelContext) async {
        guard !workout.isDeleted, workout.modelContext === context else { return }
        await repair(workoutID: workout.id, in: context, styleOverride: style)
    }

    /// Capture only IDs before awaiting. MOMENTUM-IOS-P filtered the original `recent` models
    /// after healing suspended, when one of those workouts had already been deleted.
    static func sweep(in context: ModelContext, limit: Int = 12) async {
        guard limit > 0 else { return }
        var query = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        query.fetchLimit = 200
        guard let recent = try? context.fetch(query) else { return }
        let ids = recent.map(\.id)
        var missing: [UUID] = [], outdated: [UUID] = []
        var stamped = false
        for id in ids {
            guard let workout = find(id, in: context), workout.type.isGPS,
                  let gps = detail(for: workout, in: context) else { continue }
            if gps.mapStyleRaw == nil {
                gps.mapStyleRaw = MapStyleOption.persisted.rawValue
                stamped = true
            }
            if gps.mapSnapshotData == nil { missing.append(id) }
            else if gps.mapSnapshotVersion < RouteSnapshotter.renderVersion { outdated.append(id) }
        }
        if stamped { try? context.save() }
        for id in missing.prefix(limit) {
            guard !Task.isCancelled else { return }
            await repair(workoutID: id, in: context)
        }
        for id in outdated.prefix(limit) {
            guard !Task.isCancelled else { return }
            await repair(workoutID: id, in: context, refreshOutdated: true)
        }
    }

    private struct Input {
        let detailID: PersistentIdentifier
        let type: WorkoutType
        let style: MapStyleOption
        let originalStyle: String?
        let originalImage: Data?
        let originalVersion: Int
    }

    private static func find(_ id: UUID, in context: ModelContext) -> Workout? {
        var q = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id })
        q.fetchLimit = 1
        guard let value = try? context.fetch(q).first,
              !value.isDeleted, value.modelContext === context else { return nil }
        return value
    }

    private static func detail(for workout: Workout, in context: ModelContext) -> GPSDetail? {
        guard let id = workout.gps?.persistentModelID else { return nil }
        var q = FetchDescriptor<GPSDetail>(predicate: #Predicate { $0.persistentModelID == id })
        q.fetchLimit = 1
        guard let value = try? context.fetch(q).first,
              !value.isDeleted, value.modelContext === context else { return nil }
        return value
    }

    private static func input(_ id: UUID, in context: ModelContext, style: MapStyleOption?,
                              refreshOutdated: Bool) -> Input? {
        guard let workout = find(id, in: context), workout.type.isGPS,
              let gps = detail(for: workout, in: context) else { return nil }
        if style == nil {
            guard gps.mapSnapshotData == nil ||
                (refreshOutdated && gps.mapSnapshotVersion < RouteSnapshotter.renderVersion) else { return nil }
        }
        return Input(detailID: gps.persistentModelID, type: workout.type, style: style ?? gps.mapStyle,
                     originalStyle: gps.mapStyleRaw, originalImage: gps.mapSnapshotData,
                     originalVersion: gps.mapSnapshotVersion)
    }

    /// Renderer injection exercises deletion/replacement/cancellation during the actual await.
    static func repair(workoutID id: UUID, in context: ModelContext,
                       styleOverride: MapStyleOption? = nil, refreshOutdated: Bool = false,
                       renderer: Renderer = render) async {
        guard !Task.isCancelled, !inFlight.contains(id),
              styleOverride != nil || !failed.contains(id),
              let input = input(id, in: context, style: styleOverride, refreshOutdated: refreshOutdated) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let container = context.container, detailID = input.detailID, type = input.type
        let coordinates = await Task.detached(priority: .utility) {
            let reader = ModelContext(container)
            // model(for:) can return a fault for a nonexistent row; fetch proves it exists.
            var q = FetchDescriptor<GPSDetail>(predicate: #Predicate { $0.persistentModelID == detailID })
            q.fetchLimit = 1
            guard let gps = try? reader.fetch(q).first else { return [CLLocationCoordinate2D]() }
            return gps.routeCoordinates(type: type)
        }.value
        guard !Task.isCancelled, coordinates.count > 1 else { return }
        while active >= maxConcurrent {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        guard !Task.isCancelled, find(id, in: context) != nil else { return }
        active += 1
        let data = await renderer(coordinates, input.style)
        active -= 1
        guard !Task.isCancelled,
              let workout = find(id, in: context),
              let gps = detail(for: workout, in: context),
              gps.persistentModelID == input.detailID,
              gps.mapStyleRaw == input.originalStyle,
              gps.mapSnapshotData == input.originalImage,
              gps.mapSnapshotVersion == input.originalVersion else { return }
        guard let data else { failed.insert(id); return }
        gps.mapSnapshotData = data
        gps.mapSnapshotVersion = RouteSnapshotter.renderVersion
        if styleOverride != nil || gps.mapStyleRaw == nil { gps.mapStyleRaw = input.style.rawValue }
        try? context.save()
    }

    private static func render(_ coordinates: [CLLocationCoordinate2D], _ style: MapStyleOption) async -> Data? {
        await RouteSnapshotter.snapshot(coordinates: coordinates, size: RouteSnapshotter.workoutTileSize,
                                       styleURI: style.styleURI, insets: RouteSnapshotter.workoutTileInsets)
    }
}
