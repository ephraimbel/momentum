import Foundation

/// Client for the `coach-chat` Edge Function (PRD §4.7, §8.8). When Supabase is configured
/// (Info.plist `SupabaseURL` + `SupabaseAnonKey`), this POSTs the recent conversation + a compact
/// context digest and returns the model's reply. Any failure/timeout/unconfigured state returns nil
/// so the caller falls back to the deterministic `CoachResponder` — the chat never blocks.
@MainActor
final class CoachChatService {
    private let session: URLSession
    private let timeoutS: TimeInterval = 6

    init(session: URLSession = .shared) { self.session = session }

    var isConfigured: Bool { endpoint != nil && bearer != nil }

    struct Turn: Encodable { let role: String; let text: String }   // role: "user" | "assistant"

    /// Returns the model's reply, or nil to fall back to the local responder.
    func reply(history: [Turn], context ctx: CoachResponder.Context) async -> String? {
        guard let endpoint, let bearer else { return nil }
        let body = RequestBody(messages: history, context: ContextDTO(ctx))
        do {
            var req = URLRequest(url: endpoint, timeoutInterval: timeoutS)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Prefer the user's session JWT (edge functions verify JWTs); anon key for guests.
            let token = await SupabaseClientProvider.accessToken() ?? bearer
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            let reply = decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return reply.isEmpty ? nil : reply
        } catch {
            return nil
        }
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable { let messages: [Turn]; let context: ContextDTO }
    private struct ResponseBody: Decodable { let reply: String }

    /// JSON-safe projection of the coach context (mirrors what the Edge Function's system prompt
    /// expects). Only primitives — no SwiftData models cross the wire.
    private struct ContextDTO: Encodable {
        let status: String
        let recommendation: String
        let acwr: Double
        let loadTrendPct: Double
        let distanceTrendPct: Double
        let streak: Int
        let goal: String
        let disciplines: [String]
        let todayPlan: String?
        let memory: [String]
        let preferredSessionMinutes: Int
        let topDiscipline: String?
        let overreachACWR: Double
        let paceAtEffortTrendPct: Double

        @MainActor init(_ c: CoachResponder.Context) {
            status = c.insights.status.rawValue
            recommendation = String(describing: c.insights.recommendation)
            acwr = c.insights.acwr
            loadTrendPct = c.insights.loadTrendPct
            distanceTrendPct = c.insights.distanceTrendPct
            streak = c.stats.currentStreak
            goal = String(describing: c.goal)
            disciplines = c.disciplines
            todayPlan = c.todaySession.map { PlanCoaching.brief(for: $0, distanceUnit: c.distanceUnit) }
            memory = c.athlete?.notes ?? []
            preferredSessionMinutes = c.athlete?.preferredSessionMinutes ?? 0
            topDiscipline = c.athlete?.topDiscipline
            overreachACWR = c.athlete?.overreachACWR ?? 0
            paceAtEffortTrendPct = c.athlete?.paceTrendPct ?? 0
        }
    }

    // MARK: - Configuration (absent in the default build → fallback path)

    private var endpoint: URL? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              !base.isEmpty, let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("functions/v1/coach-chat")
    }

    private var bearer: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
