import Foundation
import SwiftData
import CoreLocation
import Observation

/// Bridges `GPSTrackingEngine` to SwiftUI (PRD §4.3, §8.3). Pumps `LocationService.fixes()` into
/// the engine and republishes a snapshot for the live map + hero metric.
@MainActor
@Observable
final class CardioViewModel {
    let type: WorkoutType
    let distanceUnit: DistanceUnit
    let startedAt = Date()

    private let engine: GPSTrackingEngine
    private let store: GPSWorkoutStore
    private let location: LocationService

    private(set) var snapshot: GPSTrackingEngine.LiveSnapshot?
    private(set) var lastAccuracyM: Double?
    private(set) var workoutId: UUID?
    private var pumpTask: Task<Void, Never>?

    init(type: WorkoutType, container: ModelContainer, distanceUnit: DistanceUnit = .auto) {
        self.type = type
        self.distanceUnit = distanceUnit
        self.location = LocationService()
        let store = GPSWorkoutStore(modelContainer: container)
        self.store = store
        self.engine = GPSTrackingEngine(type: type, sink: store)
    }

    func start() async {
        location.requestAuthorization()
        await engine.begin(now: startedAt)
        workoutId = ActiveWorkoutMarker.pendingID
        snapshot = await engine.snapshot()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await fix in self.location.fixes() {
                self.lastAccuracyM = fix.accuracyM
                await self.engine.ingest(fix)
                self.snapshot = await self.engine.snapshot()
            }
        }
    }

    func pause() async { await engine.pause(); snapshot = await engine.snapshot() }
    func resume() async { await engine.resume(); snapshot = await engine.snapshot() }

    func finish() async -> UUID? {
        pumpTask?.cancel()
        location.stop()
        await engine.finish()
        // Render the Strava-style route snapshot from accepted coordinates (PRD §8.5).
        let coords = coordinates
        if coords.count > 1, let data = await RouteSnapshotter.snapshot(coordinates: coords) {
            await store.attachSnapshot(data)
        }
        return workoutId
    }

    // MARK: Derived display

    var state: GPSTrackingEngine.State { snapshot?.state ?? .idle }

    var coordinates: [CLLocationCoordinate2D] {
        (snapshot?.route ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    var distanceM: Double { snapshot?.distanceM ?? 0 }
    var movingTimeS: TimeInterval { snapshot?.movingTimeS ?? 0 }

    /// The discipline's hero metric (PRD §4.3): run → pace, ride → speed, walk → distance.
    var heroValue: String {
        switch type {
        case .ride:
            let speed = movingTimeS > 0 ? distanceM / movingTimeS : 0
            return Formatters.speed(ms: speed, unit: distanceUnit)
        case .walk, .hike:
            return Formatters.distance(meters: distanceM, unit: distanceUnit)
        default:
            return Formatters.pace(secPerKm: snapshot?.smoothedPaceSPerKm ?? 0, unit: distanceUnit)
        }
    }

    var heroLabel: String {
        switch type {
        case .ride: "Speed"
        case .walk, .hike: "Distance"
        default: "Pace"
        }
    }

    var secondaryDistance: String { Formatters.distance(meters: distanceM, unit: distanceUnit) }

    var isPaused: Bool { state == .paused || state == .autoPaused }

    /// 0 (weak) … 1 (strong) GPS strength from the latest fix accuracy.
    var gpsStrength: Double {
        guard let acc = lastAccuracyM, acc > 0 else { return 0 }
        return max(0, min(1, (40 - acc) / 30))
    }
}
