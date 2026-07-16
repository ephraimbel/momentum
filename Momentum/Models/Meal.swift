import Foundation
import SwiftData

/// One logged meal, snack, or drink — the FUEL pillar (decision 2026-07-16, extends ENDURANCE-FOCUS
/// §11 from guidance to tracking). Deliberately athlete-framed: the numbers exist to answer "am I
/// fueled for the work?", never to run a diet ledger. Energy is a FLOOR (fund the training), carbs
/// are the readiness signal, protein the recovery signal, sodium the endurance electrolyte. No
/// weight-loss framing anywhere, ever.
///
/// A meal saves instantly offline — one sentence and/or a photo. The `meal-estimate` Edge Function
/// fills the numbers when reachable (`source == "ai"`); the athlete can always set or correct them
/// (`source == "manual"`, which a later estimate never overwrites); until either happens the meal
/// sits honestly `pending` and the day's totals simply exclude it.
@Model
final class Meal {
    var id: UUID = UUID()
    /// When it was eaten (defaults to logging time; editable so a forgotten lunch lands right).
    var eatenAt: Date = Date()
    /// The athlete's own words — "chicken rice bowl", "2 gels + half a banana", "big pasta dinner".
    var text: String = ""
    /// Optional plate snap, downscaled like workout photos before persisting.
    @Attribute(.externalStorage) var photoData: Data?

    // Estimated (AI) or entered (manual) nutrition. nil = unknown/pending — never treated as zero
    // in a way that shames; totals just note the gap. All SI-adjacent units: g, mg, ml, kcal.
    var kcal: Int?
    var carbsG: Int?
    var proteinG: Int?
    var fatG: Int?
    var sodiumMg: Int?
    var fluidsMl: Int?

    /// "ai" | "manual" | "pending" — provenance of the numbers. Manual always wins.
    var source: String = "pending"
    /// One coach-toned line from the estimator ("Solid pre-long-run fuel."). Display only.
    var note: String?
    /// Estimator confidence 0–1 (surfaced as a quiet "≈" — every number here is approximate).
    var confidence: Double?

    init() {}
}
