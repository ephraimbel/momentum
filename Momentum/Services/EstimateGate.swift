import Foundation

/// Process-wide registry of meals with a billed estimate in flight. FuelView's task map is
/// view-local and the Siri intent runs entirely outside it — without one shared gate, an athlete
/// opening Fuel while Siri was mid-estimate double-billed the same meal and raced the writes.
///
/// Owner tokens, not a bare set: the composer's "Estimate again" cancels and restarts its own
/// task, and the cancelled task's late cleanup must not release the RESTART's claim — `end` is a
/// no-op unless the token still owns the slot.
@MainActor
enum EstimateGate {
    private static var inFlight: [UUID: Int] = [:]
    private static var nextToken = 0

    /// Claim the slot if nobody holds it. Returns the owner token, or nil when another path is
    /// already estimating this meal (one bill only — skip).
    static func begin(_ id: UUID) -> Int? {
        guard inFlight[id] == nil else { return nil }
        nextToken += 1
        inFlight[id] = nextToken
        return nextToken
    }

    /// Force-claim (the composer restarting ITS OWN estimate) — the previous owner's `end`
    /// becomes a no-op.
    static func take(_ id: UUID) -> Int {
        nextToken += 1
        inFlight[id] = nextToken
        return nextToken
    }

    /// Release — only if `token` still owns the slot.
    static func end(_ id: UUID, token: Int) {
        guard inFlight[id] == token else { return }
        inFlight[id] = nil
    }

    static func isEstimating(_ id: UUID) -> Bool { inFlight[id] != nil }

    /// Guard both result application AND view-local cleanup; an old task must not remove the
    /// replacement task's spinner or make its row editable while it is still estimating.
    static func owns(_ id: UUID, token: Int) -> Bool { inFlight[id] == token }
}
