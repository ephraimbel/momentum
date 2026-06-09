import Foundation

/// Wire types + pure memory logic for the enriched `workout-analysis` Edge Function
/// (`docs/ATHLETE-MODEL.md` §6–§7). One folded round trip returns the personalized read **and**
/// memory updates. Everything here is deterministic and testable; `AIService` does the networking.

// MARK: - Request

/// A compact, derived view of a workout — never raw GPS samples (too big, unusable by the LLM).
struct WorkoutDigest: Codable, Sendable {
    let type: String
    let durationS: Double
    let perceivedEffort: Int?
    let gps: GPSDigest?
    let strength: StrengthDigest?

    struct GPSDigest: Codable, Sendable {
        let distanceM: Double
        let avgPaceSPerKm: Double
        let avgSpeedMS: Double
        let elevationGainM: Double
        let avgHR: Int?
        let splitSecondsPerUnit: [Double]
    }
    struct StrengthDigest: Codable, Sendable {
        let totalVolumeKg: Double
        let totalSets: Int
        let topSets: [TopSet]
        struct TopSet: Codable, Sendable {
            let lift: String; let weightKg: Double; let reps: Int; let e1rm: Double
        }
    }

    init(_ w: Workout) {
        type = w.type.rawValue
        durationS = w.durationS
        perceivedEffort = w.perceivedEffort
        if let g = w.gps, g.distanceM > 0 {
            gps = GPSDigest(distanceM: g.distanceM, avgPaceSPerKm: g.avgPaceSPerKm,
                            avgSpeedMS: g.avgSpeedMS, elevationGainM: g.elevationGainM, avgHR: g.avgHR,
                            splitSecondsPerUnit: g.splits.sorted { $0.index < $1.index }.map(\.durationS))
        } else { gps = nil }
        if w.type == .strength, let s = w.strength {
            var tops: [StrengthDigest.TopSet] = []
            for row in s.exercises {
                let working = row.sets.filter { $0.isComplete && $0.type == .working }
                    .compactMap { set -> StrengthMath.WorkingSet? in
                        guard let kg = set.weightKg, let reps = set.reps else { return nil }
                        return .init(weightKg: kg, reps: reps)
                    }
                guard !working.isEmpty, let name = row.exercise?.name else { continue }
                let best = working.max { StrengthMath.e1RM(weightKg: $0.weightKg, reps: $0.reps)
                                       < StrengthMath.e1RM(weightKg: $1.weightKg, reps: $1.reps) }!
                tops.append(.init(lift: name, weightKg: best.weightKg, reps: best.reps,
                                  e1rm: StrengthMath.e1RM(weightKg: best.weightKg, reps: best.reps)))
            }
            strength = StrengthDigest(totalVolumeKg: s.totalVolumeKg, totalSets: s.totalSets, topSets: tops)
        } else { strength = nil }
    }
}

struct PlannedDigest: Codable, Sendable {
    let type: String?
    let targetDistanceM: Double?
    let rationale: String?
}

struct AthleteContextDTO: Codable, Sendable {
    let facts: [String: String]                 // compact confident-signal projection
    let notes: [NoteDTO]
    let recentNarratives: [String]

    struct NoteDTO: Codable, Sendable {
        let id: String; let category: String; let text: String; let confidence: String; let pinned: Bool
    }
}

struct AnalysisRequest: Codable, Sendable {
    let workout: WorkoutDigest
    let planned: PlannedDigest?
    let units: Units
    let athlete: AthleteContextDTO
    struct Units: Codable, Sendable { let weight: String; let distance: String }
}

// MARK: - Response

struct AnalysisResponse: Codable, Sendable {
    let narrative: String
    let insights: [Insight]
    let planAdjustment: PlanAdjustment?
    let memoryUpdates: [MemoryUpdate]?
    struct Insight: Codable, Sendable { let label: String; let value: String; let note: String }
    struct PlanAdjustment: Codable, Sendable { let changed: Bool; let summary: String }
}

/// One memory op the model returns. `op` ∈ add | revise | retire.
struct MemoryUpdate: Codable, Sendable {
    let op: String
    let id: String?
    let category: String?
    let text: String?
    let confidence: String?
    let evidenceKeys: [String]?
}

// MARK: - Pure memory consolidation (ATHLETE-MODEL.md §5, §11)

/// A SwiftData-free mirror of a `MemoryNote`, so the apply rules are unit-testable in isolation.
struct NoteState: Equatable, Sendable {
    var id: UUID
    var category: String
    var text: String
    var confidence: String
    var source: String
    var pinned: Bool
    var isActive: Bool
    var createdAt: Date
}

/// Applies the model's `memoryUpdates` to the note set: sanitizes (no-shame/no-medical, ≤140 chars),
/// honors pinned user corrections (never auto-retired), and caps the active set. Pure & deterministic.
enum MemoryConsolidation {
    static let maxActiveNotes = 20
    private static let banned = ["injur", "pain", "diagnos", "medical", "rehab"]

    /// Returns trimmed text, or nil if it trips the no-medical/no-shame filter.
    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if banned.contains(where: { lower.contains($0) }) { return nil }
        return trimmed.count <= 140 ? trimmed : String(trimmed.prefix(140))
    }

    static func apply(_ updates: [MemoryUpdate], to notes: [NoteState],
                      now: Date, newID: () -> UUID = UUID.init) -> [NoteState] {
        var result = notes
        for u in updates {
            switch u.op {
            case "add":
                guard let t = u.text.flatMap(clean) else { continue }
                result.append(NoteState(id: newID(), category: u.category ?? MemoryCategory.habit.rawValue,
                                        text: t, confidence: u.confidence ?? Confidence.emerging.rawValue,
                                        source: MemorySource.ai.rawValue, pinned: false, isActive: true, createdAt: now))
            case "revise":
                guard let id = u.id.flatMap(UUID.init),
                      let i = result.firstIndex(where: { $0.id == id && $0.isActive }) else { continue }
                if let t = u.text.flatMap(clean) { result[i].text = t }
                if let c = u.confidence { result[i].confidence = c }
            case "retire":
                guard let id = u.id.flatMap(UUID.init),
                      let i = result.firstIndex(where: { $0.id == id }) else { continue }
                if !result[i].pinned { result[i].isActive = false }
            default:
                continue
            }
        }
        enforceCap(&result)
        return result
    }

    /// Keep total active notes at or under the cap by retiring the weakest active, non-pinned notes
    /// (lowest confidence, then oldest). Pinned notes are always kept, even if that exceeds the cap.
    private static func enforceCap(_ notes: inout [NoteState]) {
        let activeCount = notes.filter(\.isActive).count
        guard activeCount > maxActiveNotes else { return }
        let rank = [Confidence.emerging.rawValue: 0, Confidence.growing.rawValue: 1, Confidence.confident.rawValue: 2]
        let candidates = notes.indices
            .filter { notes[$0].isActive && !notes[$0].pinned }
            .sorted { a, b in
                let ra = rank[notes[a].confidence] ?? 0, rb = rank[notes[b].confidence] ?? 0
                if ra != rb { return ra < rb }
                return notes[a].createdAt < notes[b].createdAt
            }
        for i in candidates.prefix(activeCount - maxActiveNotes) { notes[i].isActive = false }
    }
}
