import Foundation
import SwiftData

/// One earned award, persisted the moment its threshold first fell. `awardID` keys into the fixed
/// `AwardsCatalog`; the row carries only what history can't recompute cheaply — when it was earned,
/// which workout sealed it, and whether the unlock moment has been shown. Standalone (no parent
/// relationship) — wiped explicitly by `DataManager.deleteAllUserData`, alongside the other
/// standalone records.
@Model
final class EarnedAward {
    var awardID: String = ""
    var earnedAt: Date = Date()
    /// False until the unlock celebration has played — the presenter drains unseen awards.
    var seen: Bool = true
    var workout: Workout?

    init() {}

    init(awardID: String, earnedAt: Date, seen: Bool, workout: Workout? = nil) {
        self.awardID = awardID
        self.earnedAt = earnedAt
        self.seen = seen
        self.workout = workout
    }
}
