import Foundation
import SwiftData

/// Client for the `meal-estimate` Edge Function (FUEL pillar) — the AI's ONLY job in fueling:
/// turn "chicken rice bowl" (± a plate photo) into approximate numbers, which the deterministic
/// `FuelReadiness` engine then judges. Mirrors `AIService`'s contract: unconfigured/offline/slow →
/// nil, and the caller keeps the meal honestly `pending` with manual entry always available.
/// A meal log NEVER blocks on this.
@MainActor
struct FuelEstimator {
    struct Estimate: Decodable, Sendable {
        let kcal: Int
        let carbs_g: Int
        let protein_g: Int
        let fat_g: Int
        let sodium_mg: Int
        let fluids_ml: Int
        let confidence: Double
        let tags: [String]
        let note: String
    }

    private let session: URLSession
    private let timeoutS: TimeInterval = 10   // vision runs a beat slower than text-only reads

    init(session: URLSession = .shared) { self.session = session }

    /// nil = couldn't estimate (unconfigured, offline, slow, or the function declined) — the meal
    /// stays pending. `context` gives the model the training frame ("tomorrow's long session, 1h45m").
    func estimate(text: String, photoJPEG: Data?, sessionLabel: String?, durationS: Double?) async -> Estimate? {
        guard let endpoint, let bearer else { return nil }
        struct Context: Encodable { let session: String?; let durationS: Double? }
        struct Body: Encodable { let text: String; let photoBase64: String?; let context: Context }
        let body = Body(text: text,
                        photoBase64: photoJPEG?.base64EncodedString(),
                        context: Context(session: sessionLabel, durationS: durationS))
        var req = URLRequest(url: endpoint, timeoutInterval: timeoutS)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = await SupabaseClientProvider.accessToken() ?? bearer
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Estimate.self, from: data)
        } catch {
            return nil
        }
    }

    /// Apply an estimate onto a meal — unless the athlete already set numbers by hand (manual wins).
    static func apply(_ e: Estimate, to meal: Meal) {
        guard meal.source != "manual" else { return }
        meal.kcal = e.kcal
        meal.carbsG = e.carbs_g
        meal.proteinG = e.protein_g
        meal.fatG = e.fat_g
        meal.sodiumMg = e.sodium_mg
        meal.fluidsMl = e.fluids_ml
        meal.confidence = e.confidence
        meal.note = e.note.isEmpty ? nil : e.note
        meal.source = "ai"
    }

    private var endpoint: URL? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              !base.isEmpty, let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("functions/v1/meal-estimate")
    }

    private var bearer: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
