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

    /// A pretty, ISO-8601 JSON snapshot of the athlete's profile + every workout.
    static func exportJSON(in context: ModelContext, now: Date = Date()) -> Data {
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
        wipe(AthleteModel.self)
        wipe(ChatMessage.self)
        ActiveWorkoutMarker.clear()   // drop any in-flight recovery marker
        try? context.save()
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
