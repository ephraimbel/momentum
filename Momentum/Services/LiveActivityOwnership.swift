/// Startup cleanup may run after a user starts a workout. Remember this process's IDs so
/// delayed cleanup never mistakes a new card/timer for an activity from a previous launch.
struct LiveActivityOwnership {
    private var startedHere: Set<String> = []

    mutating func record(_ id: String) { startedHere.insert(id) }
    func isOrphan(_ id: String) -> Bool { !startedHere.contains(id) }
}
