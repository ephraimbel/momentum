import Testing
import Foundation
import SwiftData
@testable import Momentum

struct SentryMonitorTests {
    @Test @MainActor func failedOpenCanRetryWithoutCreatingAVolatileWorkoutStore() throws {
        var shouldFail = true
        let persistence = PersistenceController(inMemory: true) { schema, config in
            if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
            return try ModelContainer(for: schema, configurations: [config])
        }
        #expect(persistence.availableContainer == nil)
        #expect(persistence.failureCode != nil)
        shouldFail = false
        persistence.retry()
        let opened = try #require(persistence.availableContainer)
        #expect(persistence.failureCode == nil)
        persistence.retry()
        #expect(persistence.availableContainer === opened)
    }

    @Test @MainActor func permissionAndSpaceFailuresAreNotTreatedAsCorruption() {
        let wrapped = NSError(domain: "SwiftData", code: 1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ])
        #expect(PersistenceController.isTemporaryStorageFailure(wrapped))
        #expect(PersistenceController.isTemporaryStorageFailure(CocoaError(.fileReadNoPermission)))
        #expect(!PersistenceController.isTemporaryStorageFailure(NSError(domain: NSCocoaErrorDomain, code: 134110)))
    }

    @Test @MainActor func pendingRecoverySurvivesContainerRelocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backup = directory.appendingPathComponent("Quarantine/incident")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("athlete.store")
        try Data([1]).write(to: store)
        try Data([2]).write(to: backup.appendingPathComponent("athlete.store"))
        let record = PersistenceController.QuarantineRecord(
            path: "/old/container/Application Support/Quarantine/incident", at: Date(), recovered: true)
        try StoreQuarantine.beginCleanup(at: store, record: record)
        #expect(try StoreQuarantine.pendingRecovery(at: store)?.path == backup.path)
        try StoreQuarantine.finishCleanup(at: store)
        #expect(!FileManager.default.fileExists(atPath: store.path))
        #expect(try Data(contentsOf: backup.appendingPathComponent("athlete.store")) == Data([2]))
    }

    @Test @MainActor func legacyQuarantineRecordStillDecodesWithoutErrorCode() throws {
        let data = Data(#"{"path":"/recovered/store","at":0,"recovered":true,"reported":false}"#.utf8)
        let record = try JSONDecoder().decode(PersistenceController.QuarantineRecord.self, from: data)
        #expect(record.path == "/recovered/store")
        #expect(record.recovered)
        #expect(record.errorCode == nil)
    }

    @Test @MainActor func quarantineFailureCodeSurvivesUntilDeferredReporting() throws {
        let record = PersistenceController.QuarantineRecord(
            path: "/recovered/store", at: Date(), recovered: true, errorCode: "134110")
        let data = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(PersistenceController.QuarantineRecord.self, from: data)
        #expect(restored == record)
    }

    @Test @MainActor func quarantineCopyFailurePreservesEveryOriginalIncludingWAL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("athlete.store")
        let originals = [store, directory.appendingPathComponent("athlete.store-wal"),
                         directory.appendingPathComponent("athlete.store-shm")]
        for (index, file) in originals.enumerated() { try Data([UInt8(index)]).write(to: file) }
        for failureIndex in originals.indices {
            var copies = 0
            do {
                try StoreQuarantine.backUpStore(at: store,
                    to: directory.appendingPathComponent("backup-\(failureIndex)")) { source, destination in
                    defer { copies += 1 }
                    if copies == failureIndex { throw CocoaError(.fileWriteOutOfSpace) }
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                Issue.record("A failed copy must abort recovery")
            } catch {
                for (index, file) in originals.enumerated() {
                    #expect(try Data(contentsOf: file) == Data([UInt8(index)]))
                }
            }
        }
    }

    @Test @MainActor func quarantinePreservesExternalDataAndNeverOverwritesEarlierBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("athlete.store")
        let wal = directory.appendingPathComponent("athlete.store-wal")
        let support = directory.appendingPathComponent(".athlete_SUPPORT")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data([1]).write(to: store)
        try Data([2]).write(to: wal)
        try Data([3]).write(to: support.appendingPathComponent("photo"))
        let backup = directory.appendingPathComponent("backup")
        try StoreQuarantine.backUpStore(at: store, to: backup)
        #expect(throws: (any Error).self) { try StoreQuarantine.backUpStore(at: store, to: backup) }
        // Cleanup is restartable, including when a process died after removing only one file.
        let record = PersistenceController.QuarantineRecord(path: backup.path, at: Date(), recovered: true)
        try StoreQuarantine.beginCleanup(at: store, record: record)
        try FileManager.default.removeItem(at: wal)
        #expect(try StoreQuarantine.pendingRecovery(at: store) == record)
        try StoreQuarantine.finishCleanup(at: store)
        #expect(try StoreQuarantine.pendingRecovery(at: store) == nil)
        // A later launch must not erase workouts from the newly created store.
        try Data([4]).write(to: store)
        try StoreQuarantine.finishCleanup(at: store)
        #expect(try Data(contentsOf: store) == Data([4]))
        #expect(try Data(contentsOf: backup.appendingPathComponent("athlete.store")) == Data([1]))
        #expect(try Data(contentsOf: backup.appendingPathComponent("athlete.store-wal")) == Data([2]))
        #expect(try Data(contentsOf: backup.appendingPathComponent(".athlete_SUPPORT/photo")) == Data([3]))
    }

    @Test @MainActor func missingRecoveryCopyNeverDeletesRemainingOriginals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("athlete.store")
        try Data([7]).write(to: store)
        let record = PersistenceController.QuarantineRecord(
            path: directory.appendingPathComponent("missing").path, at: Date(), recovered: true)
        try StoreQuarantine.beginCleanup(at: store, record: record)
        #expect(throws: (any Error).self) { try StoreQuarantine.finishCleanup(at: store) }
        #expect(try Data(contentsOf: store) == Data([7]))
        #expect(try StoreQuarantine.pendingRecovery(at: store) == record)
    }

    @Test func blankAndBuildPlaceholdersKeepMonitoringDark() {
        #expect(SentryMonitor.configuration(from: ["SentryDSN": ""],
                                            environment: "test") == nil)
        #expect(SentryMonitor.configuration(from: ["SentryDSN": "$(SENTRY_DSN)"],
                                            environment: "test") == nil)
    }

    @Test func onlySecureSentryCloudDSNsAreAccepted() {
        let base: [String: Any] = [
            "CFBundleIdentifier": "com.example.app",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        ]
        #expect(SentryMonitor.configuration(
            from: base.merging(["SentryDSN": "http://key@o1.ingest.sentry.io/2"]) { _, new in new },
            environment: "test") == nil)
        #expect(SentryMonitor.configuration(
            from: base.merging(["SentryDSN": "https://key@example.com/2"]) { _, new in new },
            environment: "test") == nil)

        let config = SentryMonitor.configuration(
            from: base.merging(["SentryDSN": "https://key@o1.ingest.us.sentry.io/2"]) { _, new in new },
            environment: "test")
        #expect(config?.releaseName == "com.example.app@1.2.3+42")
        #expect(config?.distribution == "42")
        #expect(config?.environment == "test")
    }

    @Test func issueTagsAreAllowlistedBoundedAndNeverCarryFreeformData() {
        let long = String(repeating: "x", count: 120)
        let result = SentryMonitor.sanitizedTags([
            "status": " 401 ",
            "error_code": " PGRST301 ",
            "byte_bucket": "under_32k",
            "auth_retried": "true",
            "placement": long,
            "email": "athlete@example.com",
            "route": "30.2,-97.7",
        ])
        #expect(result["status"] == "401")
        #expect(result["error_code"] == "PGRST301")
        #expect(result["byte_bucket"] == "under_32k")
        #expect(result["auth_retried"] == "true")
        #expect(result["placement"]?.count == 80)
        #expect(result["email"] == nil)
        #expect(result["route"] == nil)
    }
}
