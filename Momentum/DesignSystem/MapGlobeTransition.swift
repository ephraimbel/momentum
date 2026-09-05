import Foundation

/// Latest-intent ownership for Mapbox callbacks. A previous exit must not finish a newer exit
/// (enter → exit → enter → exit is an ABA race if callbacks only test a Boolean).
struct MapGlobeTransition {
    enum Phase { case home, waitingForMap, entering, world, exiting }
    private(set) var phase: Phase = .home
    private(set) var revision = UUID()

    mutating func enter(mapReady: Bool) -> UUID {
        revision = UUID()
        phase = mapReady ? .entering : .waitingForMap
        return revision
    }

    mutating func mapReady() -> UUID? {
        guard phase == .waitingForMap else { return nil }
        phase = .entering
        return revision
    }

    mutating func entered(_ token: UUID) -> Bool {
        guard token == revision, phase == .entering else { return false }
        phase = .world
        return true
    }

    mutating func exit() -> UUID {
        revision = UUID()
        phase = .exiting
        return revision
    }

    mutating func exited(_ token: UUID) -> Bool {
        guard token == revision, phase == .exiting else { return false }
        phase = .home
        return true
    }

    mutating func settle(inWorld: Bool) {
        revision = UUID()
        phase = inWorld ? .world : .home
    }
}
