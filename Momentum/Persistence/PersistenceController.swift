import Foundation
import Observation
import OSLog
import SwiftData

private let persistenceLogger = Logger(
    subsystem: "com.ephraimbel.momentum.app",
    category: "persistence"
)

/// Owns the SwiftData `ModelContainer` — the **local source of truth** and the only singleton
/// in the app (PRD §17).
///
/// **Schema changes are additive-only.** Every new property on an existing model must be optional
/// or defaulted, so SwiftData's lightweight migration opens an older store. The shipped precedent is
/// `LocationSample.pausedSpan` (`Workout.swift`), added after v1.0 as "additive-only (defaults
/// false, so pre-2026-07 rows read as 'never paused')".
///
/// The schema is now genuinely versioned (`SchemaVersions.swift`, 2026-08-21) and the container
/// takes a `MomentumMigrationPlan`, so the first NON-additive change — a rename, a retype, a
/// deletion — has somewhere to go: add `SchemaV2` plus a stage. Before that existed, such a change
/// would have failed to open every shipped store and dropped the whole install base down the
/// `quarantineStore` path below. The additive rule still applies day to day; the plan is what makes
/// breaking it a decision rather than an accident.
@MainActor
@Observable
final class PersistenceController {
    static let shared = PersistenceController()

    private(set) var availableContainer: ModelContainer?
    private(set) var failureCode: String?
    var container: ModelContainer {
        guard let availableContainer else { preconditionFailure("Persistence is not ready") }
        return availableContainer
    }
    private let inMemory: Bool
    private let makeContainer: (Schema, ModelConfiguration) throws -> ModelContainer
    private var didScheduleRunningPlanBackfill = false

    /// All persisted model types — forwards to the versioned schema, which is the canonical list.
    /// Kept as a name because tests and previews build containers from it.
    static let models: [any PersistentModel.Type] = SchemaV10.models

    init(inMemory: Bool = false,
         makeContainer: @escaping (Schema, ModelConfiguration) throws -> ModelContainer = {
             try ModelContainer(for: $0, migrationPlan: MomentumMigrationPlan.self, configurations: [$1])
         }) {
        self.inMemory = inMemory
        self.makeContainer = makeContainer
        retry()
    }

    /// A failed open leaves the app on a recovery screen. Never substitute an in-memory store:
    /// that would let the athlete record workouts that disappear on the next launch.
    func retry() {
        guard availableContainer == nil else { return }
        #if DEBUG
        if !inMemory, ProcessInfo.processInfo.arguments.contains("--storage-unavailable") {
            failureCode = "debug"
            return
        }
        #endif
        failureCode = nil
        let schema = Schema(versionedSchema: SchemaV10.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        var stage = "open"
        do {
            if !inMemory, let record = try StoreQuarantine.pendingRecovery(at: config.url) {
                stage = "cleanup"
                Self.quarantineRecord = record
                try StoreQuarantine.finishCleanup(at: config.url)
            }
            let opened: ModelContainer
            do {
                stage = "open"
                opened = try makeContainer(schema, config)
            } catch {
                guard !inMemory, !Self.isTemporaryStorageFailure(error) else { throw error }
                stage = "backup"
                try Self.quarantineStore(at: config.url, error: error)
                stage = "reopen"
                opened = try makeContainer(schema, config)
            }
            // A previous interrupted device erase may have left a profile pointing at an
            // already-deleted plan. Repair before any view/backfill reads plan.sessions.
            // Failure stays on the retry screen; it must never trigger store quarantine.
            stage = "repair"
            try DataManager.repairDanglingProfileReferences(in: opened.mainContext)
            ExerciseLibrarySeed.seedIfNeeded(into: opened.mainContext)
            #if DEBUG
            DemoSeed.seedIfRequested(opened.mainContext)
            #endif
            availableContainer = opened
        } catch {
            failureCode = String((error as NSError).code)
            SentryMonitor.capture(.storeUnavailable, tags: ["error_code": failureCode ?? "unknown", "status": stage])
        }
    }

    /// Permission/space failures do not establish corruption. Preserve the existing store and
    /// let unlocking the phone or making space resolve them before retrying migration.
    static func isTemporaryStorageFailure(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let value = current else { break }
            if value.domain == NSCocoaErrorDomain,
               [NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteOutOfSpaceError]
                .contains(value.code) { return true }
            if value.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM), Int(ENOSPC), Int(EROFS)]
                .contains(value.code) { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Populate running-domain sidecars after first paint, on a dedicated SwiftData executor.
    /// The repair is additive and idempotent: a failed pass rolls back and retries next launch,
    /// while the legacy plan remains live throughout the compatibility window.
    func scheduleRunningPlanBackfill() {
        guard !didScheduleRunningPlanBackfill else { return }
        didScheduleRunningPlanBackfill = true

        let worker = RunningPlanBackfillWorker(modelContainer: container)
        Task.detached(priority: .utility) {
            do {
                let report = try await worker.repair()
                if report.didSave {
                    persistenceLogger.info("Running-plan compatibility repair completed")
                }
            } catch {
                persistenceLogger.error(
                    "Running-plan compatibility repair deferred: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// In-memory container for tests and previews.
    static func inMemory() -> PersistenceController { PersistenceController(inMemory: true) }

    // MARK: Quarantine

    /// What happened the last time the store could not be opened. Persisted rather than held in
    /// memory on purpose: an athlete who hits this deserves to still find their data days later.
    struct QuarantineRecord: Codable, Equatable, Sendable {
        /// Directory the store was moved into. Empty when `recovered` is false.
        var path: String
        var at: Date
        /// Older releases could record false after failed recovery. New recovery records are
        /// created only after backing up the complete file set.
        var recovered: Bool
        /// Set once the event has reached analytics, so a relaunch cannot re-report the same
        /// incident. The record itself stays until the athlete dismisses it in Settings.
        var reported: Bool = false
        /// Numeric failure only; never persist an error description containing athlete data.
        /// Optional so records from older releases still decode and remain exportable.
        var errorCode: String? = nil
    }

    private static let quarantineKey = "com.momentum.store.quarantine"

    /// The last quarantine, if any. `nil` on every healthy install, which is almost all of them.
    static var quarantineRecord: QuarantineRecord? {
        get {
            guard let data = UserDefaults.standard.data(forKey: quarantineKey) else { return nil }
            guard var record = try? JSONDecoder().decode(QuarantineRecord.self, from: data) else { return nil }
            if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                record.path = StoreQuarantine.resolvedBackupPath(record.path, beside: support)
            }
            return record
        }
        set {
            let defaults = UserDefaults.standard
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: quarantineKey); return
            }
            defaults.set(data, forKey: quarantineKey)
        }
    }

    /// Mark the incident as reported. Separate from clearing it: the file stays offered in Settings.
    static func markQuarantineReported() {
        guard var record = quarantineRecord, !record.reported else { return }
        record.reported = true
        quarantineRecord = record
    }

    /// Back up the complete SQLite file set before removing any original. A failed backup
    /// aborts recovery instead of deleting the only copy of the athlete's history.
    private static func quarantineStore(at url: URL, error: Error) throws {
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let folder = url.deletingLastPathComponent()
            .appendingPathComponent("Quarantine/\(stamp)", isDirectory: true)
        try StoreQuarantine.backUpStore(at: url, to: folder)
        // Record the verified backup BEFORE cleanup, so even a removal error leaves a pointer
        // to the complete recovery copy. The next launch can safely retry.
        let record = QuarantineRecord(path: folder.path, at: Date(), recovered: true,
                                      errorCode: String((error as NSError).code))
        // A file journal is atomic across process death; UserDefaults alone must never decide
        // whether to delete originals, since a stale flag could erase a newly created store.
        try StoreQuarantine.beginCleanup(at: url, record: record)
        quarantineRecord = record
        try StoreQuarantine.finishCleanup(at: url)
    }

    /// Erase every quarantined store, the record that points at one, and any share-sheet zip made
    /// from one. Called by both "Delete all data" paths and by the account switch.
    ///
    /// Without this, quarantine is a data-erasure hole and a privacy hole at once: wiping the
    /// SwiftData rows would leave a complete copy of the previous athlete's GPS history on disk, and
    /// Settings would go on offering it to whoever is holding the phone next. The whole `Quarantine`
    /// directory goes, not just `record.path` — a folder orphaned by an earlier incident is
    /// unreachable from the record but is still somebody's training history.
    static func purgeQuarantine() {
        let fm = FileManager.default
        if let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false) {
            try? fm.removeItem(at: support.appendingPathComponent("Quarantine", isDirectory: true))
        }
        quarantineRecord = nil
        // The share-sheet zip is a second full copy of the same data, sitting in tmp.
        let tmp = fm.temporaryDirectory
        for file in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
        where file.hasPrefix("momentum-recovered-") {
            try? fm.removeItem(at: tmp.appendingPathComponent(file))
        }
    }
}

/// Two-phase recovery: no original file is removed until every existing sidecar is backed up.
/// The WAL may contain the most recent workout; preserving just the .store file is insufficient.
@MainActor
enum StoreQuarantine {
    static func resolvedBackupPath(_ path: String, beside directory: URL) -> String {
        guard !path.isEmpty else { return path }
        let old = URL(fileURLWithPath: path)
        guard old.deletingLastPathComponent().lastPathComponent == "Quarantine" else { return path }
        let relocated = directory.appendingPathComponent("Quarantine", isDirectory: true)
            .appendingPathComponent(old.lastPathComponent, isDirectory: true)
        return FileManager.default.fileExists(atPath: relocated.path) ? relocated.path : path
    }

    static func files(at url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        // Core Data's external binary storage is adjacent to the SQLite store. Preserve it too
        // when present, including the extension-bearing spelling used by some store names.
        let names = [name, "\(name)-wal", "\(name)-shm",
                     ".\(url.deletingPathExtension().lastPathComponent)_SUPPORT", ".\(name)_SUPPORT"]
        return Array(Set(names)).sorted().map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func backUpStore(at url: URL, to folder: URL,
                            copy: (URL, URL) throws -> Void = {
                                try FileManager.default.copyItem(at: $0, to: $1)
                            }) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        // Refuse an existing destination instead of ever overwriting an earlier rescue.
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            for source in files(at: url) {
                try copy(source, folder.appendingPathComponent(source.lastPathComponent))
            }
        } catch {
            // Originals are untouched; this call's incomplete duplicate can be discarded.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func pendingRecovery(at url: URL) throws -> PersistenceController.QuarantineRecord? {
        let journal = url.appendingPathExtension("recovery")
        guard FileManager.default.fileExists(atPath: journal.path) else { return nil }
        var record = try JSONDecoder().decode(PersistenceController.QuarantineRecord.self,
                                              from: Data(contentsOf: journal))
        record.path = resolvedBackupPath(record.path, beside: url.deletingLastPathComponent())
        return record
    }

    static func beginCleanup(at url: URL, record: PersistenceController.QuarantineRecord) throws {
        try JSONEncoder().encode(record).write(to: url.appendingPathExtension("recovery"), options: .atomic)
    }

    static func finishCleanup(at url: URL) throws {
        guard let record = try pendingRecovery(at: url) else { return }
        let backupStore = URL(fileURLWithPath: record.path).appendingPathComponent(url.lastPathComponent)
        guard FileManager.default.fileExists(atPath: backupStore.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try removeOriginals(at: url)
        // Only after this succeeds may the caller create a new database at the original URL.
        try FileManager.default.removeItem(at: url.appendingPathExtension("recovery"))
    }

    static func removeOriginals(at url: URL) throws {
        for source in files(at: url) { try FileManager.default.removeItem(at: source) }
    }
}
