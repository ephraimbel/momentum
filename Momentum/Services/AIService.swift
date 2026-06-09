import Foundation
import SwiftData

/// The post-workout AI read client (PRD §8.8, `docs/ATHLETE-MODEL.md` §6–§7). When the Supabase
/// Edge Function is configured (Info.plist `SupabaseURL` + `SupabaseAnonKey`), this POSTs an
/// enriched request — a `WorkoutDigest` plus the athlete's facts and memory notes — to
/// `workout-analysis`, renders the personalized narrative, and applies the returned `memoryUpdates`
/// back onto the persisted `AthleteModel` (one folded round trip). Until then — and whenever the
/// model is slow or down — it renders the deterministic template, so the moment never blocks.
@MainActor
final class AIService: AIServing {
    private let session: URLSession
    private let timeoutS: TimeInterval = 4

    init(session: URLSession = .shared) { self.session = session }

    func workoutRead(for workout: Workout, planned: Bool,
                     weightUnit: WeightUnit, distanceUnit: DistanceUnit) async -> WorkoutRead {
        let template = WorkoutReadTemplates.read(for: workout, planned: planned,
                                                 weightUnit: weightUnit, distanceUnit: distanceUnit)
        // Not configured (the default build) → deterministic template, no network.
        guard let endpoint, let bearer else { return template }

        let request = AnalysisRequest(
            workout: WorkoutDigest(workout),
            planned: plannedDigest(workout, planned: planned),
            units: .init(weight: weightUnit == .lb ? "lb" : "kg", distance: distanceUnit.rawValueString),
            athlete: athleteContext()
        )

        do {
            let response = try await post(request, to: endpoint, bearer: bearer)
            applyMemoryUpdates(response.memoryUpdates ?? [])
            return WorkoutRead(
                narrative: WorkoutReadTemplates.sanitize(response.narrative),
                insights: response.insights.map { .init(label: $0.label, value: $0.value, note: $0.note) },
                planAdjustment: (response.planAdjustment?.changed == true) ? response.planAdjustment?.summary : nil
            )
        } catch {
            return template   // any failure/timeout → template; never block (§8.8)
        }
    }

    // MARK: - Networking

    private func post(_ body: AnalysisRequest, to url: URL, bearer: String) async throws -> AnalysisResponse {
        var req = URLRequest(url: url, timeoutInterval: timeoutS)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AnalysisResponse.self, from: data)
    }

    // MARK: - Athlete context (read from the local store)

    private var mainContext: ModelContext { PersistenceController.shared.container.mainContext }

    private func currentProfile() -> UserProfile? {
        (try? mainContext.fetch(FetchDescriptor<UserProfile>()))?.first
    }

    private func athleteContext() -> AthleteContextDTO {
        guard let profile = currentProfile(), let m = profile.athlete else {
            return AthleteContextDTO(facts: [:], notes: [], recentNarratives: [])
        }
        let notes = m.notes.filter(\.isActive).map {
            AthleteContextDTO.NoteDTO(id: $0.id.uuidString, category: $0.category,
                                      text: $0.text, confidence: $0.confidence, pinned: $0.pinned)
        }
        let recent = profile.workouts.sorted { $0.startedAt > $1.startedAt }
            .prefix(2).compactMap(\.aiSummary)
        return AthleteContextDTO(facts: Self.compactFacts(m), notes: notes, recentNarratives: Array(recent))
    }

    /// A compact, human-readable projection of the confident Tier-A facts for the prompt.
    static func compactFacts(_ m: AthleteModel) -> [String: String] {
        var f: [String: String] = [:]
        if let day = daypart(m.trainingHourHistogram) {
            let mins = Int(m.preferredSessionMinutes)
            f["rhythm"] = mins > 0 ? "\(day), ~\(mins)min" : day
        }
        if m.planAdherence28d > 0 { f["adherence28d"] = "\(Int((m.planAdherence28d * 100).rounded()))%" }
        if !m.disciplineShare.isEmpty {
            f["disciplineMix"] = m.disciplineShare.sorted { $0.value > $1.value }.prefix(3)
                .map { "\(WorkoutType(rawValue: $0.key)?.title ?? $0.key) \(Int(($0.value * 100).rounded()))%" }
                .joined(separator: ", ")
        }
        if m.paceAtEffortTrendPct <= -1 {
            f["fitness"] = "easy pace \(Int(m.paceAtEffortTrendPct.rounded()))% at the same effort"
        }
        if m.currentACWR > 0 {
            f["load"] = "ACWR \(String(format: "%.2f", m.currentACWR)), overreach past \(String(format: "%.1f", m.overreachThresholdACWR))"
        }
        return f
    }

    private static func daypart(_ hist: [Int]) -> String? {
        guard hist.count == 24, hist.reduce(0, +) > 0 else { return nil }
        let peak = hist.indices.max { hist[$0] < hist[$1] } ?? 0
        switch peak {
        case 5..<11: return "early-morning"
        case 11..<17: return "afternoon"
        case 17..<22: return "evening"
        default: return "late-night"
        }
    }

    private func plannedDigest(_ w: Workout, planned: Bool) -> PlannedDigest? {
        guard planned, let s = w.plannedSession else { return nil }
        return PlannedDigest(type: s.runType?.rawValue, targetDistanceM: s.targetDistanceM, rationale: s.rationale)
    }

    // MARK: - Memory write-back

    private func applyMemoryUpdates(_ updates: [MemoryUpdate]) {
        guard !updates.isEmpty, let model = currentProfile()?.athlete else { return }
        let before = model.notes.map {
            NoteState(id: $0.id, category: $0.category, text: $0.text, confidence: $0.confidence,
                      source: $0.source, pinned: $0.pinned, isActive: $0.isActive, createdAt: $0.createdAt)
        }
        let after = MemoryConsolidation.apply(updates, to: before, now: Date())

        let beforeIDs = Set(before.map(\.id))
        let byID = Dictionary(model.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for state in after {
            if let note = byID[state.id] {
                note.text = state.text
                note.confidence = state.confidence
                note.isActive = state.isActive
                note.updatedAt = Date()
            } else if !beforeIDs.contains(state.id) {
                let note = MemoryNote()
                note.id = state.id
                note.category = state.category
                note.text = state.text
                note.confidence = state.confidence
                note.source = state.source
                note.pinned = state.pinned
                note.isActive = state.isActive
                mainContext.insert(note)
                model.notes.append(note)
            }
        }
        try? mainContext.save()
    }

    // MARK: - Configuration (absent in the default build → template path)

    private var endpoint: URL? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              !base.isEmpty, let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("functions/v1/workout-analysis")
    }

    private var bearer: String? {
        // Phase 4 uses the project anon key; real per-user JWTs arrive with auth (Phase 6).
        (Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

private extension DistanceUnit {
    /// Stable string for the request payload regardless of how `DistanceUnit` is represented.
    var rawValueString: String {
        switch resolved() { case .imperial: "imperial"; default: "metric" }
    }
}
