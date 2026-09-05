import Foundation
import SwiftData

/// Client for the `meal-estimate` Edge Function (FUEL pillar) — the AI's ONLY job in fueling:
/// turn "chicken rice bowl" into approximate numbers, which the deterministic
/// `FuelReadiness` engine then judges. Mirrors `AIService`'s contract: unconfigured/offline/slow →
/// nil, and the caller keeps the meal honestly `pending` with manual entry always available.
/// A meal log NEVER blocks on this.
@MainActor
struct FuelEstimator {
    struct Estimate: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let name: String
            let qty: Double
            let unit: String
            let kcal: Int
            let carbs_g: Int
            let protein_g: Int
            let fat_g: Int
            let sodium_mg: Int
            let fluids_ml: Int
            // Optional decode: resilient if a provider omits the endurance micros.
            let potassium_mg: Int?
            let magnesium_mg: Int?
            let iron_mg: Double?
            let calcium_mg: Int?
            // Food-quality signals (2026-08-15) — optional for the same reason; they feed the
            // deterministic HealthScore, and a provider that omits them just scores more roughly.
            let fiber_g: Int?
            let sugar_g: Int?
            let satfat_g: Int?
            let nova: Int?
        }
        let items: [Item]
        let confidence: Double
        let note: String
    }

    /// What actually happened, so the caller can tell "the model couldn't read this meal" apart
    /// from "we never got to ask". The retry cap exists to stop a meal re-billing an API call
    /// forever; a request that was never issued bills nothing and must not spend the budget.
    enum Outcome: Sendable {
        case estimated(Estimate)
        /// The function answered and we still have no usable numbers (non-200, undecodable body),
        /// **or** the request went out and died in flight (timeout, dropped mid-stream). Server
        /// work may well have been done, so this counts against the meal's attempts.
        case declined
        /// Nothing left the device: unconfigured, rate-limited before sending, or no route to the
        /// host. Free, and the athlete's meal did nothing wrong — it owes no attempt.
        case unavailable
    }

    /// URL errors that prove the request never reached the function. `timedOut` is deliberately
    /// absent: those bytes went out, the model may be running right now, and a meal that times out
    /// on every visit is exactly the standing API tax the cap is here to stop.
    private static let neverSent: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed,
        .appTransportSecurityRequiresSecureConnection,
    ]

    /// Did this failure prove the function was never reached? The one judgment the retry cap turns
    /// on — pure and callable without a network so the accounting can be pinned by tests. Anything
    /// unrecognized answers false: the cap must fail toward BOUNDING cost, never toward a meal
    /// that re-fires forever.
    static func neverReachedServer(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return neverSent.contains(url.code)
    }

    private let session: URLSession
    private let timeoutS: TimeInterval = 8   // text-only extraction; covers the server's Haiku fallback

    /// The server capped today's estimates (429 — generous daily limit, abuse guard only). Remember
    /// until local midnight and skip the network: retries would be futile, and every meal still
    /// logs fine with manual numbers. Resets itself the moment the day turns. PERSISTED
    /// (2026-08-20): the latch was process-static, so a relaunch on a capped day re-fired doomed
    /// calls — one per pending meal — before rediscovering the cap.
    private static let limitedUntilKey = "com.momentum.fuel.estimateLimitedUntil"
    private static var estimateLimitedUntil: Date? {
        get { UserDefaults.standard.object(forKey: limitedUntilKey) as? Date }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: limitedUntilKey) }
            else { UserDefaults.standard.removeObject(forKey: limitedUntilKey) }
        }
    }

    init(session: URLSession = .shared) { self.session = session }

    /// Anything but `.estimated` leaves the meal pending — the log already succeeded and manual
    /// entry is always there. `context` gives the model the training frame ("tomorrow's long
    /// session, 1h45m"). Text-only: the server reads `text` and `context` and nothing else (photos
    /// left the app 2026-07-16 and the function never looked at the base64 blob we used to send).
    func estimate(text: String, sessionLabel: String?, durationS: Double?) async -> Outcome {
        guard let endpoint, let bearer else { return .unavailable }
        if let until = Self.estimateLimitedUntil {
            if Date() < until { return .unavailable }
            Self.estimateLimitedUntil = nil
        }
        struct Context: Encodable { let session: String?; let durationS: Double? }
        struct Body: Encodable { let text: String; let context: Context }
        let body = Body(text: text, context: Context(session: sessionLabel, durationS: durationS))
        var req = URLRequest(url: endpoint, timeoutInterval: timeoutS)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = await SupabaseClientProvider.accessToken() ?? bearer
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .declined }
            if http.statusCode == 429 {
                let cal = Calendar.current
                Self.estimateLimitedUntil = cal.date(byAdding: .day, value: 1,
                                                     to: cal.startOfDay(for: Date()))
                // The server refused to look at this meal at all — the athlete's sentence was
                // never judged, so it owes nothing. (We also stop asking until midnight.)
                return .unavailable
            }
            guard http.statusCode == 200 else { return .declined }
            let estimate = try JSONDecoder().decode(Estimate.self, from: data)
            return Self.isValid(estimate) ? .estimated(estimate) : .declined
        } catch {
            return Self.neverReachedServer(error) ? .unavailable : .declined
        }
    }

    /// Apply an estimate onto a meal — unless the athlete already set numbers by hand (manual wins).
    /// Items land as the breakdown; the meal's totals are Σ items (one source of truth).
    static func apply(_ e: Estimate, to meal: Meal) {
        guard meal.source != "manual", isValid(e) else { return }
        meal.items = e.items.map {
            MealItem(name: $0.name, qty: $0.qty, unit: $0.unit, kcal: $0.kcal,
                     carbsG: $0.carbs_g, proteinG: $0.protein_g, fatG: $0.fat_g,
                     sodiumMg: $0.sodium_mg, fluidsMl: $0.fluids_ml,
                     potassiumMg: $0.potassium_mg, magnesiumMg: $0.magnesium_mg,
                     ironMg: $0.iron_mg, calciumMg: $0.calcium_mg,
                     fiberG: $0.fiber_g, sugarG: $0.sugar_g, satFatG: $0.satfat_g,
                     nova: $0.nova.map { min(4, max(1, $0)) })   // clamp a wild class to the real scale
        }
        meal.confidence = e.confidence
        meal.note = e.note.isEmpty ? nil : e.note
        meal.source = "ai"
    }

    /// Reject the entire response before touching a saved meal. A malformed item must not
    /// produce a negative total, an overflow, or a resolved-but-empty journal entry.
    static func isValid(_ estimate: Estimate) -> Bool {
        guard !estimate.items.isEmpty, estimate.items.count <= 100,
              estimate.confidence.isFinite, (0...1).contains(estimate.confidence) else { return false }
        return estimate.items.allSatisfy { item in
            let numbers = [item.kcal, item.carbs_g, item.protein_g, item.fat_g, item.sodium_mg, item.fluids_ml]
                + [item.potassium_mg, item.magnesium_mg, item.calcium_mg, item.fiber_g, item.sugar_g, item.satfat_g].compactMap { $0 }
            return !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !item.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && item.qty.isFinite && (0.001...10_000).contains(item.qty)
                && numbers.allSatisfy { (0...1_000_000).contains($0) }
                && (item.iron_mg.map { $0.isFinite && (0...1_000_000).contains($0) } ?? true)
        }
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
