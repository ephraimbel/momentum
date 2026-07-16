import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Export + delete the user's data (PRD §13.3 — privacy: own your data, leave anytime). Local-first:
/// no account or network. Deletion is App-Store-required for any app that stores personal data.
@MainActor
enum DataManager {

    // MARK: - Export

    struct Snapshot: Codable {
        var app = "momentum"
        var schemaVersion = 1
        var exportedAt: Date
        var profile: ProfileDTO?
        var workouts: [WorkoutDTO]
    }

    struct ProfileDTO: Codable {
        let displayName: String
        let disciplines: [String]
        let goal: String
        let daysPerWeek: Int
        let weightUnit: String
        let distanceUnit: String
    }

    struct WorkoutDTO: Codable {
        let type: String
        let startedAt: Date
        let durationS: Double
        let perceivedEffort: Int?
        let title: String
        let note: String
        let distanceM: Double?
        let avgPaceSPerKm: Double?
        let elevationGainM: Double?
        let totalVolumeKg: Double?
        let totalSets: Int?
    }

    /// Background variant for the Settings row: the fetch faults every workout's gps/strength
    /// detail rows and the encode pretty-prints the lot — a perceptible hitch on the main thread
    /// at real history sizes. Runs on a fresh background context; the caller shows a busy row.
    static func exportJSON(container: ModelContainer, now: Date = Date()) async -> Data {
        await Task.detached(priority: .userInitiated) {
            exportJSON(in: ModelContext(container), now: now)
        }.value
    }

    /// A pretty, ISO-8601 JSON snapshot of the athlete's profile + every workout.
    nonisolated static func exportJSON(in context: ModelContext, now: Date = Date()) -> Data {
        let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
        let workouts = (try? context.fetch(
            FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? []

        let snapshot = Snapshot(
            exportedAt: now,
            profile: profile.map { p in
                ProfileDTO(displayName: p.displayName, disciplines: p.disciplines, goal: "\(p.goal)",
                           daysPerWeek: p.daysPerWeek, weightUnit: p.weightUnit, distanceUnit: p.distanceUnit)
            },
            workouts: workouts.map { w in
                WorkoutDTO(type: w.type.rawValue, startedAt: w.startedAt, durationS: w.durationS,
                           perceivedEffort: w.perceivedEffort, title: w.title, note: w.note,
                           distanceM: w.gps?.distanceM, avgPaceSPerKm: w.gps?.avgPaceSPerKm,
                           elevationGainM: w.gps?.elevationGainM,
                           totalVolumeKg: w.strength?.totalVolumeKg, totalSets: w.strength?.totalSets)
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(snapshot)) ?? Data()
    }

    // MARK: - Delete

    /// Wipe every piece of personal data (PRD §13.3). The bundled exercise catalog (reference data,
    /// not the user's) is preserved. After this `UserProfile` is gone, so the app returns to onboarding.
    ///
    /// Uses per-object deletes (not the bulk `delete(model:)`, which can crash on models with cascade
    /// relationships): deleting each top-level object cascades its children; standalone types are
    /// wiped directly. `Exercise` (the catalog) is intentionally left intact.
    static func deleteAllUserData(in context: ModelContext) {
        func wipe<T: PersistentModel>(_ type: T.Type) {
            for item in (try? context.fetch(FetchDescriptor<T>())) ?? [] { context.delete(item) }
        }
        wipe(UserProfile.self)     // cascades workouts (→ gps/strength), plan, prs, athlete
        wipe(Workout.self)         // any free workouts not under a profile (cascades gps/strength)
        wipe(TrainingPlan.self)
        wipe(PersonalRecord.self)
        wipe(AthleteModel.self)    // cascades its MemoryNote + FitnessSnapshot children
        wipe(ChatMessage.self)
        // Standalone records (no parent relationship to cascade through) — must be wiped explicitly
        // or a reset leaves stale coaching history, inbox notifications, and check-ins behind.
        wipe(CoachingEvent.self)
        wipe(AppNotification.self)
        wipe(DailyCheckin.self)
        wipe(Meal.self)               // food log — standalone since the Fuel tab landed
        ActiveWorkoutMarker.clear()   // drop any in-flight recovery marker
        try? context.save()
    }

    /// Interactive variant for the Settings "Delete all data" row. The synchronous wipe above ran
    /// hundreds of thousands of cascade row deletes (every GPS fix, every HR sample) on the main
    /// context — real histories hard-froze the UI for seconds, and a force-quit mid-hang skipped
    /// the single trailing save so the "deleted" data silently survived. This one runs on a
    /// background context in chunks with a save per chunk (an interrupted wipe stays consistent
    /// and finishes by simply running again), heaviest children first and `UserProfile` LAST —
    /// its disappearance is what flips RootView back to onboarding, so the UI only transitions
    /// when everything else is already gone.
    static func deleteAllUserData(container: ModelContainer) async {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            func wipe<T: PersistentModel>(_ type: T.Type, chunk: Int = 32) {
                while true {
                    var fd = FetchDescriptor<T>()
                    fd.fetchLimit = chunk
                    let batch = (try? context.fetch(fd)) ?? []
                    if batch.isEmpty { break }
                    for item in batch { context.delete(item) }
                    try? context.save()
                }
            }
            wipe(Workout.self, chunk: 8)   // cascades gps samples + strength sets — the heavy rows
            wipe(TrainingPlan.self)
            wipe(PersonalRecord.self)
            wipe(AthleteModel.self)
            wipe(ChatMessage.self)
            wipe(CoachingEvent.self)
            wipe(AppNotification.self)
            wipe(DailyCheckin.self)
            wipe(Meal.self)
            wipe(UserProfile.self)
        }.value
        ActiveWorkoutMarker.clear()   // drop any in-flight recovery marker
    }
}

/// A JSON file for `.fileExporter` (Save to Files / share).
struct JSONExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
