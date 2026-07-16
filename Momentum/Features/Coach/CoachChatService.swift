import Foundation

/// Client for the `coach-chat` Edge Function (PRD §4.7, §8.8). When Supabase is configured
/// (Info.plist `SupabaseURL` + `SupabaseAnonKey`), this POSTs the recent conversation + a compact
/// context digest and returns the model's reply — optionally carrying ONE `CoachCardPayload` (a
/// typed proposal/nav card the app re-validates before rendering Apply). Any failure/timeout/
/// unconfigured state returns nil so the caller falls back to the deterministic `CoachResponder` —
/// the chat never blocks.
@MainActor
final class CoachChatService {
    private let session: URLSession
    private let timeoutS: TimeInterval = 8

    init(session: URLSession = .shared) { self.session = session }

    var isConfigured: Bool { endpoint != nil && bearer != nil }

    struct Turn: Encodable { let role: String; let text: String }   // role: "user" | "assistant"

    /// One reply off the wire: the coach's text + at most one (untrusted) card.
    struct CoachTurn: Sendable {
        let text: String
        let card: CoachCardPayload?
    }

    /// One parsed server-sent event.
    struct SSEEvent: Equatable, Sendable {
        let name: String
        let data: String
    }

    /// Minimal incremental SSE parser for the coach stream's `event:`/`data:` line pairs. Pure and
    /// stateless-per-line so it's unit-testable; dispatches on each `data:` line (never relies on
    /// blank-line separators, which `AsyncLineSequence` may not surface).
    struct SSEParser {
        private var currentEvent = "message"

        mutating func consume(line: String) -> SSEEvent? {
            if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                return nil
            }
            if line.hasPrefix("data:") {
                return SSEEvent(name: currentEvent,
                                data: String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
    }

    /// Streaming reply: text arrives via `onDelta` as the model writes it; the final turn (full
    /// text + optional card) returns at the end. Returns nil when streaming isn't available
    /// (unconfigured, older deploy without SSE, network failure before any output) — the caller
    /// falls back to one-shot `reply(...)`, then the local responder. Partial text that arrived
    /// before a mid-stream error is still returned: keep what the athlete already read.
    func stream(history: [Turn], context ctx: CoachResponder.Context,
                onDelta: (String) -> Void) async -> CoachTurn? {
        guard let endpoint, let bearer else { return nil }
        let body = RequestBody(messages: history, context: ContextDTO(ctx))
        do {
            var req = URLRequest(url: endpoint, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let token = await SupabaseClientProvider.accessToken() ?? bearer
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(body)
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream")
            else { return nil }   // JSON-only deploy → caller uses reply()

            var parser = SSEParser()
            var text = ""
            var card: CoachCardPayload?
            for try await line in bytes.lines {
                guard let event = parser.consume(line: line) else { continue }
                switch event.name {
                case "delta":
                    if let d = try? JSONDecoder().decode(DeltaDTO.self, from: Data(event.data.utf8)),
                       !d.text.isEmpty {
                        text += d.text
                        onDelta(d.text)
                    }
                case "card":
                    card = try? JSONDecoder().decode(CoachCardPayload.self, from: Data(event.data.utf8))
                case "done", "error":
                    let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !reply.isEmpty else { return nil }
                    let kept = event.name == "done" ? card : nil
                    return CoachTurn(text: reply, card: kept.flatMap { $0.kind == .none ? nil : $0 })
                default:
                    break
                }
            }
            // Connection ended without a done event — keep whatever streamed.
            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return reply.isEmpty ? nil : CoachTurn(text: reply, card: nil)
        } catch {
            return nil
        }
    }

    private struct DeltaDTO: Decodable { let text: String }

    /// Returns the model's reply, or nil to fall back to the local responder.
    func reply(history: [Turn], context ctx: CoachResponder.Context) async -> CoachTurn? {
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
            guard !reply.isEmpty else { return nil }
            // A malformed/none card never kills the reply — it just renders as plain text.
            let card = decoded.card.flatMap { $0.kind == .none ? nil : $0 }
            return CoachTurn(text: reply, card: card)
        } catch {
            return nil
        }
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable { let messages: [Turn]; let context: ContextDTO }
    private struct ResponseBody: Decodable {
        let reply: String
        let card: CoachCardPayload?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reply = try c.decode(String.self, forKey: .reply)
            card = try? c.decodeIfPresent(CoachCardPayload.self, forKey: .card)
        }
        private enum CodingKeys: String, CodingKey { case reply, card }
    }

    /// JSON-safe projection of the coach context (mirrors what the Edge Function's system prompt
    /// expects). Only primitives — no SwiftData models cross the wire. The `upcoming` ids double as
    /// the validation whitelist: the model may only reference sessions listed here.
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
        // v2 — what the coach needs to propose concrete, typed changes.
        let upcoming: [SessionDTO]
        let race: RaceDTO?
        let settings: SettingsDTO
        let feasibility: FeasibilityDTO?
        let adaptLock: AdaptLockDTO
        let isPaused: Bool
        let activeInjuryArea: String?
        let injuryAreas: [String]        // valid InjuryArea raw values (echo for injuryReport)
        let lastWorkout: LastWorkoutDTO?
        let memoryCategories: [String]   // valid MemoryCategory raw values (echo for rememberNote)
        let fueling: String?             // today's fueling digest — nil until a meal is logged

        struct SessionDTO: Encodable {
            let id: String
            let dateISO: String
            let weekday: String
            let brief: String
            let discipline: String
            let status: String
        }
        struct RaceDTO: Encodable {
            let dateISO: String
            let distanceM: Double?
            let goalFinishTimeS: Double?
            let weeksOut: Int
        }
        struct SettingsDTO: Encodable {
            let daysPerWeek: Int
            let sessionMinutes: Int
            let equipment: String
            let preferredDays: [Int]
            let planIntensity: String?
            let goalOptions: [String]        // valid Goal raw values (echo for changeGoal)
            let equipmentOptions: [String]   // valid Equipment raw values
        }
        struct FeasibilityDTO: Encodable {
            let verdict: String
            let headline: String
            let weeksAvailable: Int
            let weeksNeeded: Int
        }
        struct AdaptLockDTO: Encodable {
            let lastAdaptedAtISO: String?
            let canAdaptLoad: Bool
        }
        struct LastWorkoutDTO: Encodable {
            let dateISO: String
            let type: String
            let distanceM: Double?
            let durationS: Double
            let avgPaceSPerKm: Double?
            let avgHR: Int?
            let rpe: Int?
            let plannedBrief: String?
            let splitNote: String?
            let repsNote: String?
        }

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

            let dayFmt = DateFormatter()
            dayFmt.locale = Locale(identifier: "en_US_POSIX")
            dayFmt.dateFormat = "yyyy-MM-dd"
            upcoming = c.upcoming.map {
                SessionDTO(id: $0.id.uuidString,
                           dateISO: dayFmt.string(from: $0.date),
                           weekday: $0.date.formatted(.dateTime.weekday(.wide)),
                           brief: $0.brief,
                           discipline: $0.discipline,
                           status: $0.status)
            }
            race = c.race.map {
                RaceDTO(dateISO: dayFmt.string(from: $0.date), distanceM: $0.distanceM,
                        goalFinishTimeS: $0.goalFinishTimeS, weeksOut: $0.weeksOut)
            }
            settings = SettingsDTO(daysPerWeek: c.settings.daysPerWeek,
                                   sessionMinutes: c.settings.sessionMinutes,
                                   equipment: c.settings.equipment,
                                   preferredDays: c.settings.preferredDays,
                                   planIntensity: c.settings.planIntensity,
                                   goalOptions: Goal.allCases.map(\.rawValue),
                                   equipmentOptions: Equipment.allCases.map(\.rawValue))
            feasibility = c.feasibility.map {
                FeasibilityDTO(verdict: $0.verdict.rawValue, headline: $0.headline,
                               weeksAvailable: $0.weeksAvailable, weeksNeeded: $0.weeksNeeded)
            }
            adaptLock = AdaptLockDTO(
                lastAdaptedAtISO: c.lastAdaptedAt.map { dayFmt.string(from: $0) },
                canAdaptLoad: c.canAdaptLoad)
            isPaused = c.isPaused
            activeInjuryArea = c.activeInjuryArea
            injuryAreas = InjuryArea.allCases.map(\.rawValue)
            lastWorkout = c.lastWorkout.map {
                LastWorkoutDTO(dateISO: dayFmt.string(from: $0.date), type: $0.typeTitle,
                               distanceM: $0.distanceM, durationS: $0.durationS,
                               avgPaceSPerKm: $0.avgPaceSPerKm, avgHR: $0.avgHR,
                               rpe: $0.perceivedEffort, plannedBrief: $0.plannedBrief,
                               splitNote: $0.splitNote, repsNote: $0.repsNote)
            }
            memoryCategories = MemoryCategory.allCases.map(\.rawValue)
            fueling = c.fueling
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
