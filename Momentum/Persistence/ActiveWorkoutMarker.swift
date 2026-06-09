import Foundation

/// Records the id of the workout currently being captured so a force-quit mid-activity can be
/// recovered on relaunch (PRD §8.3/§8.4 "Resume?"). Set on `begin`, cleared on `finish`.
/// Lightweight on purpose — the durable data lives in SwiftData; this is just the pointer.
enum ActiveWorkoutMarker {
    private static let key = "momentum.activeWorkoutID"

    static func set(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var pendingID: UUID? {
        UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
    }
}
