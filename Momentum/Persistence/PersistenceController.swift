import Foundation
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
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer
    private var didScheduleRunningPlanBackfill = false

    /// All persisted model types — forwards to the versioned schema, which is the canonical list.
    /// Kept as a name because tests and previews build containers from it.
    static let models: [any PersistentModel.Type] = SchemaV4.models

    private init(inMemory: Bool = false) {
        // V2 adds only the running planner's scalar-ID sidecars, V3 the athlete-state sidecar.
        // `MomentumMigrationPlan` upgrades a released store in place without changing the existing
        // plan/workout object graph.
        let schema = Schema(versionedSchema: SchemaV4.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, migrationPlan: MomentumMigrationPlan.self,
                                           configurations: [config])
        } catch {
            // A failed lightweight migration or a corrupt store must NOT become a permanent launch
            // crash-loop escapable only by delete-and-reinstall — and it must not silently delete
            // the athlete's training history either, which is what this path did until 2026-07-28.
            // The store is MOVED ASIDE intact so it stays recoverable by hand (Settings → Data &
            // privacy), and the app relaunches on an empty one. In-memory configs have no file to
            // move, so a failure there is genuinely fatal.
            if !inMemory { Self.quarantineStore(at: config.url) }
            do {
                container = try ModelContainer(for: schema, migrationPlan: MomentumMigrationPlan.self,
                                               configurations: [config])
            } catch {
                fatalError("Failed to create ModelContainer even after quarantining the store: \(error)")
            }
        }
        ExerciseLibrarySeed.seedIfNeeded(into: container.mainContext)
        #if DEBUG
        DemoSeed.seedIfRequested(container.mainContext)
        #endif
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
        /// `false` when the move itself failed and the store had to be removed to make the app
        /// launchable at all. Recorded honestly so nothing reports a rescue that did not happen.
        var recovered: Bool
        /// Set once the event has reached analytics, so a relaunch cannot re-report the same
        /// incident. The record itself stays until the athlete dismisses it in Settings.
        var reported: Bool = false
    }

    private static let quarantineKey = "com.momentum.store.quarantine"

    /// The last quarantine, if any. `nil` on every healthy install, which is almost all of them.
    static var quarantineRecord: QuarantineRecord? {
        get {
            guard let data = UserDefaults.standard.data(forKey: quarantineKey) else { return nil }
            return try? JSONDecoder().decode(QuarantineRecord.self, from: data)
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

    /// Move the SwiftData store and its SQLite sidecars aside so a corrupt or unmigratable store can
    /// be recreated empty on the retry **without losing the original**. One timestamped directory per
    /// incident, so a second failure can never overwrite the first recoverable copy.
    ///
    /// Only if the move of the store file itself fails do we remove it — a permanently unlaunchable
    /// app is worse than an empty one — and the record then says `recovered: false`.
    private static func quarantineStore(at url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        // Seconds-since-epoch plus a short random suffix. Wall-clock seconds alone are neither
        // monotonic nor collision-proof — two failures inside one second, or a clock that steps
        // backwards, would otherwise land in a directory that already holds a real rescue.
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let folder = dir.appendingPathComponent("Quarantine/\(stamp)", isDirectory: true)
        var recovered = false
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: folder.appendingPathComponent(name))
            recovered = true
        } catch {
            recovered = false
        }
        // A sidecar left beside a missing store is the one state that would confuse the retry:
        // SQLite binds a -wal by filename and can replay it into the fresh store, which is the
        // crash-loop this whole function exists to prevent. So removal is the FALLBACK, never a
        // swallowed failure — a quarantine that loses the WAL tail is still a rescue; one that
        // leaves it behind is a bug.
        for side in ["\(name)-wal", "\(name)-shm"] {
            let src = dir.appendingPathComponent(side)
            guard fm.fileExists(atPath: src.path) else { continue }
            if recovered, (try? fm.moveItem(at: src, to: folder.appendingPathComponent(side))) != nil { continue }
            try? fm.removeItem(at: src)
        }
        if !recovered {
            try? fm.removeItem(at: url)
            // Only ever reclaim a directory this call created and left empty. A blind remove here
            // would delete a previous incident's recoverable copy on any name collision.
            if ((try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? false) {
                try? fm.removeItem(at: folder)
            }
        }
        quarantineRecord = QuarantineRecord(path: recovered ? folder.path : "",
                                            at: Date(), recovered: recovered)
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
