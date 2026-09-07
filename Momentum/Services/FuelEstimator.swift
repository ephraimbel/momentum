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
            /// The portion the estimate assumed, as served (ml for a drink) — the photo pass's
            /// visible portion basis (2026-09-07). Optional: the deployed text-only function
            /// never sent it, and a label or staple never weighs.
            let grams: Int?
            /// Ethanol grams. Server-side energy bookkeeping (the Atwater identity the validator
            /// reconciles kcal against); decoded so the item is complete, not surfaced.
            let alcohol_g: Int?
        }
        let items: [Item]
        let confidence: Double
        let note: String
        /// "" for a meal; "not_food" or "unreadable" when the server looked and saw nothing to
        /// estimate (photos, 2026-09-07). Optional so the deployed text-only function still decodes.
        let reason: String?
    }

    /// What actually happened, so the caller can tell "the model couldn't read this meal" apart
    /// from "we never got to ask". The retry cap exists to stop a meal re-billing an API call
    /// forever; a request that was never issued bills nothing and must not spend the budget.
    enum Outcome: Sendable {
        case estimated(Estimate)
        /// The function answered and honestly found no meal in what it was given: a photo of a
        /// desk, a blurred plate. The attempt stands (a call was made), the journal stops asking on
        /// its own, and the athlete gets a plain line instead of confident-looking zeros.
        case rejected(reason: String)
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
    /// A vision call reads the image first; give it room, but not forever.
    private let photoTimeoutS: TimeInterval = 20

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
    /// session, 1h45m"). `imageJPEG` (2026-09-07) is the plate, already downsampled and stripped
    /// of metadata by `MealPhoto`; it rides the request body as base64 and is never stored
    /// server-side. Without it the request is byte-identical to the text-only contract.
    func estimate(text: String, imageJPEG: Data? = nil, sessionLabel: String?, durationS: Double?) async -> Outcome {
        guard let endpoint, let bearer else { return .unavailable }
        if let until = Self.estimateLimitedUntil {
            if Date() < until { return .unavailable }
            Self.estimateLimitedUntil = nil
        }
        // An image the app would not send is not sent (the server refuses it anyway): the words
        // go alone. With no words either there is nothing to judge, so the attempt is spent
        // rather than refunded forever: a meal that can never be asked must come to rest.
        let image = imageJPEG.flatMap { MealPhoto.isSendable($0) ? $0 : nil }
        if image == nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .declined }
        var req = URLRequest(url: endpoint, timeoutInterval: image == nil ? timeoutS : photoTimeoutS)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = await SupabaseClientProvider.accessToken() ?? bearer
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            // Base64 of a 2.5 MB plate plus the JSON pass is real work; it runs off the main
            // actor, which is where every caller of this method lives.
            req.httpBody = try await Task.detached(priority: .userInitiated) {
                try Self.encodedBody(text: text, imageJPEG: image, sessionLabel: sessionLabel, durationS: durationS)
            }.value
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
            return Self.outcome(for: estimate)
        } catch {
            return Self.neverReachedServer(error) ? .unavailable : .declined
        }
    }

    /// The wire shape, pure, so the text-only and photo contracts can be pinned by tests.
    struct RequestBody: Encodable, Equatable, Sendable {
        struct Context: Encodable, Equatable, Sendable { let session: String?; let durationS: Double? }
        struct Image: Encodable, Equatable, Sendable { let mime: String; let base64: String }
        let text: String
        let context: Context
        /// Omitted from the JSON when nil: a text-only request never carries the key.
        let image: Image?
    }

    nonisolated static func requestBody(text: String, imageJPEG: Data?, sessionLabel: String?, durationS: Double?) -> RequestBody {
        RequestBody(text: text,
                    context: .init(session: sessionLabel, durationS: durationS),
                    image: imageJPEG.map { .init(mime: MealPhoto.mimeType, base64: $0.base64EncodedString()) })
    }

    /// The bytes on the wire. Nonisolated so the encode can run wherever the caller sends it.
    nonisolated static func encodedBody(text: String, imageJPEG: Data?, sessionLabel: String?, durationS: Double?) throws -> Data {
        try JSONEncoder().encode(requestBody(text: text, imageJPEG: imageJPEG, sessionLabel: sessionLabel, durationS: durationS))
    }

    /// A decoded answer becomes exactly one outcome: a rejection when the server said so, an
    /// estimate when every number checks out, declined otherwise. An empty item list without a
    /// reason is declined too — "nothing" is not a meal.
    static func outcome(for estimate: Estimate) -> Outcome {
        if let reason = estimate.reason, !reason.isEmpty, estimate.items.isEmpty {
            return .rejected(reason: reason)
        }
        return isValid(estimate) ? .estimated(estimate) : .declined
    }

    /// The journal's line for a rejected estimate, in the coach's voice, never a fabricated
    /// number. A photo is spoken of as a photo; a sentence the model could not read as food (the
    /// Siri lane, a text-only log) never hears about a photo it did not send.
    nonisolated static func rejectionLine(_ reason: String, hasPhoto: Bool) -> String {
        switch (reason, hasPhoto) {
        case ("not_food", true): "That photo doesn't look like a meal. Add the foods by hand, or try another photo."
        case (_, true): "That photo was too hard to read. Add the foods by hand, or try a clearer shot."
        case ("not_food", false): "That didn't read as a meal. Add the foods by hand, or say what you ate."
        default: "That was hard to read as a meal. Add the foods by hand, or try different words."
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
                     nova: $0.nova.map { min(4, max(1, $0)) },   // clamp a wild class to the real scale
                     gramsG: $0.grams)
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
                + [item.potassium_mg, item.magnesium_mg, item.calcium_mg, item.fiber_g, item.sugar_g, item.satfat_g,
                   item.grams, item.alcohol_g].compactMap { $0 }
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
