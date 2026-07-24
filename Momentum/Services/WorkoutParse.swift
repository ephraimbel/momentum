import Foundation

/// Client for the `workout-parse` Edge Function — the server rung of the offline-log ladder.
/// The local grammar (`WorkoutLogParser`) reads instantly and offline; when the athlete's text is
/// richer than what it caught ("worked up to 225 on bench for 3, then incline dumbbells…"), this
/// sends the WHOLE sentence to be read and returns the same `WorkoutLogParser.Result` shape.
/// Every number is clamped deterministically on-device, the merged receipt is still confirmed by
/// the athlete before anything saves, and a log NEVER blocks on this — offline, rate-limited, or
/// failed, the grammar's receipt stands and manual entry is always there.
@MainActor
struct WorkoutParseService {
    struct Response: Decodable, Sendable {
        struct WorkoutPayload: Decodable, Sendable {
            struct Exercise: Decodable, Sendable {
                let name: String
                let sets: Int
                let reps: Int
                let weight_kg: Double
            }
            let type: String
            let indoor: Bool
            let duration_s: Double
            let distance_m: Double
            let effort: Int
            let day_offset: Int
            let time_of_day: String
            let exercises: [Exercise]
        }
        /// One entry per distinct workout in the athlete's account — "lifted, then ran 4 miles"
        /// comes back as two.
        let workouts: [WorkoutPayload]
        let confidence: Double
    }

    enum Outcome: Sendable {
        case parsed([WorkoutLogParser.Result])
        /// Offline, unconfigured, rate-limited, or the function failed — all one answer for the
        /// composer: the grammar receipt stands, a quiet retry is offered.
        case unavailable
    }

    private let session: URLSession
    private let timeoutS: TimeInterval = 10

    init(session: URLSession = .shared) { self.session = session }

    func parse(text: String, weightUnit: WeightUnit, distanceUnit: DistanceUnit) async -> Outcome {
        guard let endpoint, let bearer else { return .unavailable }
        struct Context: Encodable { let weight_unit: String; let distance_unit: String }
        struct Body: Encodable { let text: String; let context: Context }
        let body = Body(text: text,
                        context: Context(weight_unit: weightUnit.rawValue,
                                         distance_unit: distanceUnit == .imperial ? "mi" : "km"))
        var req = URLRequest(url: endpoint, timeoutInterval: timeoutS)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = await SupabaseClientProvider.accessToken() ?? bearer
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return .unavailable }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let list = Self.results(from: decoded)
            return list.isEmpty ? .unavailable : .parsed(list)
        } catch {
            return .unavailable
        }
    }

    // MARK: Deterministic mapping — the model proposes, these clamps dispose

    /// Server response → parser-result cards, empties dropped, capped at 3 like the grammar.
    static func results(from r: Response) -> [WorkoutLogParser.Result] {
        r.workouts.prefix(3).map(result(from:)).filter { !$0.isEmpty }
    }

    /// One workout payload → parser-result shape. Every number passes a sanity clamp here so a
    /// model hallucination can never put an absurd figure on the receipt (let alone in SwiftData).
    static func result(from r: Response.WorkoutPayload) -> WorkoutLogParser.Result {
        var out = WorkoutLogParser.Result()
        out.type = WorkoutType(rawValue: r.type)
        out.indoor = r.indoor
        if r.duration_s >= 60, r.duration_s <= 24 * 3600 { out.durationS = r.duration_s.rounded() }
        if r.distance_m >= 100, r.distance_m <= 1_000_000 { out.distanceM = r.distance_m.rounded() }
        if (1...10).contains(r.effort) { out.effort = r.effort }
        out.dayOffset = max(-7, min(0, r.day_offset))
        out.timeHint = switch r.time_of_day {
        case "morning": .morning
        case "afternoon": .afternoon
        case "evening": .evening
        default: nil
        }
        out.exercises = r.exercises.prefix(15).compactMap { ex in
            let name = ex.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48)
            // "Named it, no numbers" (reps 0) stays off the receipt — a set line with invented
            // reps would be a lie; the workout still logs as a timed lift.
            guard !name.isEmpty, ex.reps >= 1 else { return nil }
            // Absurd weights DROP (the grammar's rule) — clamping 5000 kg to 600 would still lie.
            let weightKg: Double? = ex.weight_kg > 0 && ex.weight_kg <= 600 ? ex.weight_kg : nil
            return WorkoutLogParser.ParsedExercise(name: String(name),
                                                   sets: max(1, min(20, ex.sets)),
                                                   reps: min(100, ex.reps),
                                                   weightKg: weightKg)
        }
        // A set list with no sport word is still a lift; a distance with no sport is still a run.
        if out.type == nil, !out.exercises.isEmpty { out.type = .strength }
        if out.type == nil, out.distanceM != nil { out.type = .run }
        return out
    }

    /// Card-list merge: the server read the whole text, so its card COUNT stands (it may have
    /// split a lift-then-run the grammar read as one); the grammar's primary read backfills the
    /// first card's gaps. Grammar-only when the server returned nothing.
    ///
    /// One exception — corrections. The grammar splits only on discipline change, so when it
    /// read ONE workout and the server returned several cards of the SAME discipline, the extras
    /// are almost always a restatement ("…actually it was a hard effort") the model mistook for
    /// a second workout. Those collapse into one card: later fields win (the correction), earlier
    /// stated facts survive (the pace that derived the duration). Cards carrying their own
    /// distinct time context ("ran this morning… ran again tonight") are genuinely separate and
    /// keep the split.
    static func merge(ai: [WorkoutLogParser.Result], grammar: [WorkoutLogParser.Result]) -> [WorkoutLogParser.Result] {
        guard !ai.isEmpty else { return grammar }
        var ai = ai
        if grammar.count == 1, ai.count > 1,
           Set(ai.compactMap { $0.type?.discipline }).count <= 1 {
            var collapsed = ai[0]
            var didCollapse = true
            for later in ai.dropFirst() {
                guard later.timeHint == nil || later.timeHint == collapsed.timeHint,
                      later.dayOffset == 0 || later.dayOffset == collapsed.dayOffset else {
                    didCollapse = false
                    break
                }
                collapsed.type = later.type ?? collapsed.type
                collapsed.indoor = collapsed.indoor || later.indoor
                collapsed.durationS = later.durationS ?? collapsed.durationS
                collapsed.distanceM = later.distanceM ?? collapsed.distanceM
                collapsed.effort = later.effort ?? collapsed.effort
                collapsed.timeHint = collapsed.timeHint ?? later.timeHint
                if collapsed.dayOffset == 0 { collapsed.dayOffset = later.dayOffset }
                for ex in later.exercises where !collapsed.exercises.contains(ex) {
                    collapsed.exercises.append(ex)
                }
            }
            if didCollapse { ai = [collapsed] }
        }
        var out = ai
        if let g = grammar.first { out[0] = merge(ai: out[0], grammar: g) }
        return out
    }

    /// Field-wise merge for one card: the server read the WHOLE text, so its fields win where
    /// present; the grammar keeps anything the server left empty (it may have read "45 min" that
    /// the model dropped). The athlete's explicit sport pick is applied above both, in the view.
    static func merge(ai: WorkoutLogParser.Result, grammar: WorkoutLogParser.Result) -> WorkoutLogParser.Result {
        var out = ai
        out.type = ai.type ?? grammar.type
        out.indoor = ai.indoor || grammar.indoor
        out.durationS = ai.durationS ?? grammar.durationS
        out.distanceM = ai.distanceM ?? grammar.distanceM
        out.effort = ai.effort ?? grammar.effort
        if out.dayOffset == 0 { out.dayOffset = grammar.dayOffset }
        out.timeHint = ai.timeHint ?? grammar.timeHint
        if out.exercises.isEmpty { out.exercises = grammar.exercises }
        return out
    }

    private var endpoint: URL? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              !base.isEmpty, let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("functions/v1/workout-parse")
    }

    private var bearer: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
