import Foundation
import SwiftData
import Observation
import Supabase

struct PlanCloudIdentity: Equatable { var ownerID: UUID; var token: String }
@MainActor
struct PlanCloudVersion: Decodable {
    var revision: Int
    var snapshot: PlanCloudSnapshot
    var operationID: UUID
    enum CodingKeys: String, CodingKey { case revision, snapshot; case operationID = "operation_id" }
    func validate() throws {
        guard revision > 0 else { throw HTTPPlanCloudTransport.Failure.malformedResponse }
        try snapshot.validate()
    }
}
@MainActor
protocol PlanCloudTransport {
    func read(identity: PlanCloudIdentity) async throws -> PlanCloudVersion?
    func commit(data: Data, expectedRevision: Int, operationID: UUID,
                identity: PlanCloudIdentity) async throws -> PlanCloudVersion
}

/// Private, authenticated transport. The server compares revisions while holding a row lock;
/// retries of the same operation ID are idempotent even when an acknowledgement was lost.
@MainActor
final class HTTPPlanCloudTransport: PlanCloudTransport {
    enum Failure: Error { case unavailable, unauthenticated, rejected(Int), malformedResponse }
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    private func request(path: String, identity: PlanCloudIdentity, body: Data? = nil) async throws -> Data {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              let url = URL(string: base + "/rest/v1/" + path), !key.isEmpty else { throw Failure.unavailable }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(identity.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard response.statusCode != 401 else { throw Failure.unauthenticated }
        guard (200..<300).contains(response.statusCode) else { throw Failure.rejected(response.statusCode) }
        guard data.count <= PlanCloudSnapshot.maximumBytes + 65_536 else { throw Failure.malformedResponse }
        return data
    }
    func read(identity: PlanCloudIdentity) async throws -> PlanCloudVersion? {
        let data = try await request(path: "plan_continuity?select=revision,snapshot,operation_id&user_id=eq.\(identity.ownerID.uuidString)&limit=1", identity: identity)
        let rows = try JSONDecoder().decode([PlanCloudVersion].self, from: data)
        guard rows.count <= 1 else { throw Failure.malformedResponse }
        if let row = rows.first { try row.validate() }
        return rows.first
    }
    func commit(data: Data, expectedRevision: Int, operationID: UUID,
                identity: PlanCloudIdentity) async throws -> PlanCloudVersion {
        let body = try JSONSerialization.data(withJSONObject: [
            "p_expected_revision": expectedRevision,
            "p_operation_id": operationID.uuidString,
            "p_snapshot": JSONSerialization.jsonObject(with: data)
        ])
        let response = try await request(path: "rpc/commit_plan_continuity", identity: identity, body: body)
        let row = try JSONDecoder().decode(PlanCloudVersion.self, from: response)
        try row.validate()
        return row
    }
}

@MainActor
@Observable
final class PlanSyncService {
    enum Status: Equatable {
        case local, checking, current, pending, conflict, unavailable, resetRequired
    }
    private(set) var status: Status = .local
    private(set) var restoreChecked = false
    private(set) var detail = "Your plan is saved on this device."
    private(set) var cloudName: String?
    private(set) var finishingReset = false
    private let transport: any PlanCloudTransport
    private let identity: () async -> PlanCloudIdentity?
    private let enabled: Bool
    private let defaults: UserDefaults
    var isEnabled: Bool { enabled }
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var localAccount: String?
    @ObservationIgnored private var expectedOwner: UUID?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var mayRestoreEmpty = true

    init(enabled: Bool = true, transport: (any PlanCloudTransport)? = nil,
         defaults: UserDefaults = .standard,
         identity: @escaping () async -> PlanCloudIdentity? = {
             guard let client = SupabaseClientProvider.client, let session = try? await client.auth.session else { return nil }
             return PlanCloudIdentity(ownerID: session.user.id, token: session.accessToken)
         }) {
        self.enabled = enabled; self.transport = transport ?? HTTPPlanCloudTransport(); self.identity = identity
        self.defaults = defaults
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--plan-reset-interrupted") {
            defaults.set(true, forKey: resetKey)
        }
        #endif
        if defaults.bool(forKey: resetKey) { status = .resetRequired }
    }

    private enum SetupIntent: String { case resetting, fresh }
    private let resetKey = "momentum.planContinuity.deviceResetPending"
    // The wipe affects the whole local store, so an interrupted wipe blocks every account.
    // Fresh setup belongs to the account; remember its owner alias for offline relaunches.
    private var freshSetupKey: String? {
        if let owner = expectedOwner {
            return "momentum.planContinuity.fresh.owner.\(owner.uuidString)"
        }
        guard let localAccount else { return nil }
        let alias = defaults.string(forKey: "momentum.planContinuity.owner.\(localAccount)")
        return alias.map { "momentum.planContinuity.fresh.owner.\($0)" }
            ?? "momentum.planContinuity.fresh.account.\(localAccount)"
    }
    private var setupIntent: SetupIntent? {
        if defaults.bool(forKey: resetKey) { return .resetting }
        return freshSetupKey.map { defaults.bool(forKey: $0) } == true ? .fresh : nil
    }
    private func saveSetupIntent(_ intent: SetupIntent?) {
        defaults.set(intent == .resetting, forKey: resetKey)
        if let key = freshSetupKey { defaults.set(intent == .fresh, forKey: key) }
    }
    private func rememberOwner() {
        guard let localAccount, let expectedOwner else { return }
        let legacyKey = "momentum.planContinuity.fresh.account.\(localAccount)"
        if defaults.bool(forKey: legacyKey), let key = freshSetupKey {
            defaults.set(true, forKey: key)
        }
        defaults.removeObject(forKey: legacyKey)
        defaults.set(expectedOwner.uuidString, forKey: "momentum.planContinuity.owner.\(localAccount)")
    }
    func begin(account: String?, isGuest: Bool, expectedOwner: UUID? = nil, in context: ModelContext) async {
        epoch += 1; scheduled?.cancel(); self.context = context
        localAccount = isGuest ? nil : account
        self.expectedOwner = expectedOwner
        #if DEBUG
        // Demo data never belongs to a signed-in cloud account, including after device reset.
        if localAccount == "demo-user" { localAccount = nil }
        #endif
        mayRestoreEmpty = true; restoreChecked = false; cloudName = nil
        rememberOwner()
        if setupIntent == .resetting {
            status = .resetRequired; restoreChecked = false
            detail = "Your device reset was interrupted. Finish removing this device's data to start fresh. Your account's saved plan is kept."
            return
        }
        guard enabled, localAccount != nil else {
            restoreChecked = true; status = .local; return
        }
        mayRestoreEmpty = setupIntent == nil
        if setupIntent == .fresh, (try? context.fetchCount(FetchDescriptor<UserProfile>())) == 0 {
            restoreChecked = true; status = .local
            detail = "Create your new plan on this device. Your account's previous plan is still saved."
            return
        }
        guard expectedOwner != nil else {
            status = .unavailable
            detail = "Sign in to your account to check for a saved plan. Your local training is safe."
            return
        }
        status = .checking
        await synchronize()
    }
    /// Save notifications are debounced and never race a live recorder. Foreground re-entry also
    /// calls this, so offline/outbox retries don't depend on the athlete visiting the Plan tab.
    func schedule() {
        guard enabled, localAccount != nil, status != .conflict, setupIntent != .resetting else { return }
        // Saving the outbox/acknowledgement also emits didSave. Never cancel the task doing that
        // save, and never poll an unresolved conflict in a save → sync → save loop.
        if running { needsAnotherPass = true; return }
        scheduled?.cancel()
        scheduled = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.synchronize()
        }
    }
    func allowNewLocalPlan() {
        guard setupIntent != .resetting else { return }
        saveSetupIntent(.fresh)
        restoreChecked = true; mayRestoreEmpty = false
    }
    func retry() async { await synchronize() }

    private func valid(_ generation: Int, owner: UUID) async -> Bool {
        guard generation == epoch, localAccount != nil, !Task.isCancelled else { return false }
        let current = await identity()
        return generation == epoch && expectedOwner == owner && current?.ownerID == owner && !Task.isCancelled
    }
    private func payload(_ profile: UserProfile, in context: ModelContext) throws -> Data {
        try PlanCloudSnapshot.capture(profile, in: context).encoded()
    }
    private func finishPass() {
        running = false
        if needsAnotherPass { needsAnotherPass = false; schedule() }
    }
    func synchronize() async {
        guard enabled, localAccount != nil, let context else { return }
        guard setupIntent != .resetting else { status = .resetRequired; return }
        guard !running else { needsAnotherPass = true; return }
        guard ActiveWorkoutMarker.pendingID == nil else { status = .pending; detail = "Plan sync will finish after your workout."; return }
        running = true; let generation = epoch
        defer { finishPass() }
        do {
            guard let account = await identity(), account.ownerID == expectedOwner, generation == epoch else { throw HTTPPlanCloudTransport.Failure.unauthenticated }
            let profiles = try context.fetch(FetchDescriptor<UserProfile>())
            guard profiles.count <= 1 else { throw PlanCloudSnapshot.Failure.invalidSnapshot }
            let profile = profiles.first
            if setupIntent == .fresh {
                guard profile?.plan != nil else {
                    restoreChecked = true; status = .local
                    detail = "Create your new plan on this device. Your account's previous plan is still saved."
                    return
                }
                saveSetupIntent(nil)
            }
            let before = try profile.map { try payload($0, in: context) }
            let beforeHash = before.map(PlanCloudSnapshot.fingerprint)
            if let owner = profile?.continuity?.cloudOwnerID, owner != account.ownerID {
                throw HTTPPlanCloudTransport.Failure.unauthenticated
            }
            let remote = try await transport.read(identity: account)
            guard await valid(generation, owner: account.ownerID) else { return }
            try remote?.validate()
            guard ActiveWorkoutMarker.pendingID == nil else { status = .pending; return }
            // A local edit made while the request was in flight gets its own pass, never overwritten.
            let currentProfiles = try context.fetch(FetchDescriptor<UserProfile>())
            guard currentProfiles.first?.id == profile?.id,
                  try currentProfiles.first.map({ try payload($0, in: context) }).map(PlanCloudSnapshot.fingerprint) == beforeHash else {
                status = .pending; needsAnotherPass = true; return
            }
            guard let profile, let before, let beforeHash else {
                if let remote, mayRestoreEmpty {
                    try apply(remote, preserving: nil, account: account, in: context)
                }
                restoreChecked = true; mayRestoreEmpty = false; status = .current
                detail = remote == nil ? "No saved plan yet. Your new plan will sync after setup." : "Your saved plan is ready."
                return
            }
            let journal = PlanContinuityRecord.upsert(profileID: profile.id, in: context)
            if let remote {
                guard remote.revision >= journal.cloudRevision else { throw HTTPPlanCloudTransport.Failure.malformedResponse }
                if remote.operationID == journal.pendingOperationID, let pending = journal.pendingSnapshot {
                    guard try remote.snapshot.encoded() == pending else { throw HTTPPlanCloudTransport.Failure.malformedResponse }
                    try acknowledge(remote, fingerprint: PlanCloudSnapshot.fingerprint(pending), journal: journal, owner: account.ownerID, in: context)
                    // New local changes made after preparing the acknowledged operation remain dirty.
                    if beforeHash != journal.syncedFingerprint { needsAnotherPass = true }
                    status = .current; restoreChecked = true; detail = "Your plan is synced."; return
                }
                if remote.revision != journal.cloudRevision {
                    if journal.syncedFingerprint == beforeHash && journal.cloudRevision > 0 {
                        try apply(remote, preserving: before, account: account, in: context)
                        status = .current; restoreChecked = true; detail = "Your plan is up to date."; return
                    }
                    let remoteData = try remote.snapshot.encoded()
                    if PlanCloudSnapshot.fingerprint(remoteData) == beforeHash {
                        try acknowledge(remote, fingerprint: beforeHash, journal: journal, owner: account.ownerID, in: context)
                        status = .current; restoreChecked = true; detail = "Your plan is synced."; return
                    }
                    try conflict(remote, local: before, journal: journal, owner: account.ownerID, in: context)
                    return
                }
            } else if journal.cloudRevision > 0 {
                throw HTTPPlanCloudTransport.Failure.malformedResponse
            }
            if beforeHash == journal.syncedFingerprint {
                status = .current; restoreChecked = true; detail = "Your plan is synced."; return
            }
            // Outbox is durable before transmission. If a different local change occurred since an
            // unacknowledged operation, finish that operation first; the next pass uploads the new one.
            if journal.pendingSnapshot == nil {
                try PlanMutation.perform(in: context) {
                    journal.cloudOwnerID = account.ownerID
                    journal.pendingSnapshot = before; journal.pendingOperationID = UUID()
                }
            }
            guard let pending = journal.pendingSnapshot, let operation = journal.pendingOperationID else { throw PlanCloudSnapshot.Failure.invalidSnapshot }
            let result = try await transport.commit(data: pending, expectedRevision: journal.cloudRevision,
                                                    operationID: operation, identity: account)
            guard await valid(generation, owner: account.ownerID) else { return }
            try result.validate()
            guard !profile.isDeleted, profile.modelContext != nil,
                  try context.fetch(FetchDescriptor<UserProfile>()).first?.id == profile.id else { return }
            if result.operationID != operation {
                let fresh = try payload(profile, in: context)
                try conflict(result, local: fresh, journal: journal, owner: account.ownerID, in: context)
                return
            }
            guard try result.snapshot.encoded() == pending else { throw HTTPPlanCloudTransport.Failure.malformedResponse }
            try acknowledge(result, fingerprint: PlanCloudSnapshot.fingerprint(pending), journal: journal, owner: account.ownerID, in: context)
            status = .current; restoreChecked = true; detail = "Your plan is synced."
            if try PlanCloudSnapshot.fingerprint(payload(profile, in: context)) != journal.syncedFingerprint { needsAnotherPass = true }
        } catch {
            guard generation == epoch else { return }
            status = .unavailable
            detail = "Plan sync couldn't finish. Your local plan is safe. Check your connection and account, then try again."
        }
    }
    private func acknowledge(_ remote: PlanCloudVersion, fingerprint: String, journal: PlanContinuityRecord,
                             owner: UUID, in context: ModelContext) throws {
        try PlanMutation.perform(in: context) {
            journal.cloudOwnerID = owner; journal.cloudRevision = remote.revision
            journal.syncedFingerprint = fingerprint; journal.pendingSnapshot = nil; journal.pendingOperationID = nil
            journal.conflictingSnapshot = nil; journal.conflictingRevision = nil; journal.lastSyncedAt = Date()
        }
    }
    private func conflict(_ remote: PlanCloudVersion, local: Data, journal: PlanContinuityRecord,
                          owner: UUID, in context: ModelContext) throws {
        try PlanMutation.perform(in: context) {
            journal.cloudOwnerID = owner; journal.conflictingSnapshot = try remote.snapshot.encoded()
            journal.conflictingRevision = remote.revision; journal.preservedLocalSnapshot = local
        }
        cloudName = remote.snapshot.coach.plan?.name
        status = .conflict; restoreChecked = true
        detail = "This device and your account have different plan changes. Choose which plan to continue. Both copies are kept on this device."
    }
    private func apply(_ remote: PlanCloudVersion, preserving local: Data?, account: PlanCloudIdentity,
                       protectRecovery: Bool = false,
                       in context: ModelContext) throws {
        try PlanMutation.perform(in: context) {
            var snapshot = remote.snapshot
            if protectRecovery, let local {
                snapshot = try preservingRecovery(in: snapshot, against: PlanCloudSnapshot.decode(local))
            }
            let profile = try snapshot.restore(in: context)
            try IllnessResponse.enforce(in: context)
            let journal = PlanContinuityRecord.upsert(profileID: profile.id, in: context)
            journal.cloudOwnerID = account.ownerID; journal.cloudRevision = remote.revision
            // Capture the restored graph: local workouts are retained and may be a superset.
            journal.syncedFingerprint = PlanCloudSnapshot.fingerprint(try remote.snapshot.encoded())
            journal.pendingOperationID = nil; journal.pendingSnapshot = nil
            journal.conflictingRevision = nil; journal.conflictingSnapshot = nil
            if let local { journal.preservedLocalSnapshot = local }
            journal.lastSyncedAt = Date()
        }
        NotificationCenter.default.post(name: Self.didRestore, object: nil)
    }
    private func preservingRecovery(in selected: PlanCloudSnapshot, against other: PlanCloudSnapshot) throws -> PlanCloudSnapshot {
        var result = selected
        let a = try selected.coach.illnessData.map { try JSONDecoder().decode(IllnessResponse.State.self, from: $0) }
        let b = try other.coach.illnessData.map { try JSONDecoder().decode(IllnessResponse.State.self, from: $0) }
        let state = IllnessResponse.preservingRestrictions(a, b)
        result.coach.illnessCaptured = true
        result.coach.illnessData = try state.map { try PlanCloudSnapshot.encoder().encode($0) }
        result.trainingEvidenceFrom = [selected.trainingEvidenceFrom, other.trainingEvidenceFrom].compactMap { $0 }.max()
        // A plan choice is not an injury clearance. Keep the more restrictive active report;
        // ordinary ordered synchronization can still carry an explicitly completed return.
        func rank(_ raw: String?) -> Int {
            switch raw.flatMap(InjurySeverity.init(rawValue:)) {
            case .twinge: 1
            case .moderate: 2
            case .severe, nil: 3
            }
        }
        if other.coach.activeInjuryArea != nil,
           selected.coach.activeInjuryArea == nil || rank(other.coach.activeInjurySeverity) > rank(selected.coach.activeInjurySeverity) {
            result.coach.activeInjuryArea = other.coach.activeInjuryArea
            result.coach.activeInjurySeverity = other.coach.activeInjurySeverity
        }
        result.coach.activeInjuryUntil = [selected.coach.activeInjuryUntil, other.coach.activeInjuryUntil].compactMap { $0 }.max()
        result.coach.injuryHistory = Array(Set(selected.coach.injuryHistory + other.coach.injuryHistory)).sorted()
        result.profile.activeInjuryArea = result.coach.activeInjuryArea
        result.profile.activeInjurySeverity = result.coach.activeInjurySeverity
        result.profile.activeInjuryUntil = result.coach.activeInjuryUntil
        result.profile.injuryHistory = result.coach.injuryHistory
        return try result.mergingTrainingEvidence(from: other)
    }
    static let didRestore = Notification.Name("Momentum.planRestored")

    /// Explicit conflict resolution. Re-read first so the choice cannot overwrite another device's
    /// edits that arrived while this sheet was open. Completed local workouts are always retained.
    func resolve(useCloud: Bool) async {
        guard setupIntent != .resetting, !running, let context, ActiveWorkoutMarker.pendingID == nil else { return }
        running = true; let generation = epoch
        defer { finishPass() }
        do {
            guard let account = await identity(), account.ownerID == expectedOwner, let profile = try context.fetch(FetchDescriptor<UserProfile>()).first,
                  let journal = profile.continuity, journal.cloudOwnerID == account.ownerID else { return }
            let local = try payload(profile, in: context)
            guard let remote = try await transport.read(identity: account), await valid(generation, owner: account.ownerID),
                  ActiveWorkoutMarker.pendingID == nil else { return }
            try remote.validate()
            guard remote.revision == journal.conflictingRevision else {
                try conflict(remote, local: local, journal: journal, owner: account.ownerID, in: context); return
            }
            // New local edits also require a fresh review instead of applying an obsolete choice.
            guard !profile.isDeleted, profile.modelContext != nil,
                  try context.fetch(FetchDescriptor<UserProfile>()).first?.id == profile.id,
                  try payload(profile, in: context) == local else { status = .conflict; return }
            if useCloud {
                try apply(remote, preserving: local, account: account, protectRecovery: true, in: context)
            } else {
                try PlanMutation.perform(in: context) {
                    let protected = try preservingRecovery(in: PlanCloudSnapshot.decode(local), against: remote.snapshot)
                    let restored = try protected.restore(in: context)
                    let record = PlanContinuityRecord.upsert(profileID: restored.id, in: context)
                    record.cloudOwnerID = account.ownerID
                    record.preservedLocalSnapshot = try remote.snapshot.encoded()
                    record.cloudRevision = remote.revision; record.syncedFingerprint = nil
                    record.pendingSnapshot = nil; record.pendingOperationID = nil
                    record.conflictingRevision = nil; record.conflictingSnapshot = nil
                }
                NotificationCenter.default.post(name: Self.didRestore, object: nil)
            }
            status = .pending; restoreChecked = true; detail = useCloud ? "Your saved plan is restored. Syncing your recovery state." : "Your device plan is queued to sync."
            needsAnotherPass = true
        } catch {
            guard generation == epoch else { return }
            status = .unavailable; detail = "That choice couldn't be saved. Both plan copies are still available. Try again."
        }
    }

    /// An explicit local reset must not race an in-flight restore or re-upload the erased graph.
    func prepareForLocalReset() {
        saveSetupIntent(.resetting)
        suspendForLocalChange(preserveIdentity: true)
        finishingReset = true; restoreChecked = false; status = .resetRequired
        detail = "Removing data from this device. Your account’s saved plan is kept."
    }
    private func suspendForLocalChange(preserveIdentity: Bool = false) {
        epoch += 1; scheduled?.cancel()
        if !preserveIdentity { localAccount = nil }
        mayRestoreEmpty = false
        restoreChecked = setupIntent != .resetting
        status = setupIntent == .resetting ? .resetRequired : .local
    }
    func prepareForAccountSwitch() {
        suspendForLocalChange()
        restoreChecked = false
    }

    func finishLocalReset(account: String?, isGuest: Bool, expectedOwner: UUID?, in context: ModelContext) {
        self.context = context; self.localAccount = isGuest ? nil : account; self.expectedOwner = expectedOwner
        #if DEBUG
        if localAccount == "demo-user" { localAccount = nil }
        #endif
        rememberOwner(); saveSetupIntent(.fresh)
        finishingReset = false; status = .local
        mayRestoreEmpty = false; restoreChecked = true
        // Setup will create a new local plan. A different cloud copy then becomes a reviewable
        // conflict; it must not resurrect itself during the explicit device erase.
        schedule()
    }

    func localResetFailed() {
        finishingReset = false; restoreChecked = false; status = .resetRequired
        detail = "Some device data may already be removed. Finish the reset to continue. Your account's saved plan is kept."
    }

    /// Resume only a previously requested device reset. A normal retry never deletes data.
    func finishInterruptedReset() async {
        guard !running, !finishingReset, setupIntent == .resetting, let context else { return }
        let generation = epoch, account = localAccount, owner = expectedOwner
        running = true; finishingReset = true
        defer { finishingReset = false; finishPass() }
        do {
            try await DataManager.deleteAllUserData(container: context.container)
            // While erasing, begin() blocks all accounts from using or restoring the store.
            // If identity changed, complete the device reset for the current identity too.
            if generation != epoch || localAccount != account || expectedOwner != owner {
                rememberOwner()
            }
            saveSetupIntent(.fresh)
            mayRestoreEmpty = false; restoreChecked = true; status = .local
            detail = "Your device reset is complete. Create your new plan when you are ready."
        } catch {
            guard generation == epoch else { return }
            status = .resetRequired
            detail = "The device reset couldn't finish. Your account's saved plan is kept. Try finishing the reset again."
        }
    }

    func restorePreservedCopy() async {
        guard setupIntent != .resetting, !running, let context, ActiveWorkoutMarker.pendingID == nil else { return }
        running = true; let generation = epoch
        defer { finishPass() }
        do {
            guard let account = await identity(), account.ownerID == expectedOwner,
                  let profile = try context.fetch(FetchDescriptor<UserProfile>()).first,
                  let journal = profile.continuity, journal.cloudOwnerID == account.ownerID,
                  let backup = journal.preservedLocalSnapshot else { return }
            let local = try payload(profile, in: context)
            let saved = try PlanCloudSnapshot.decode(backup)
            guard let remote = try await transport.read(identity: account),
                  await valid(generation, owner: account.ownerID), ActiveWorkoutMarker.pendingID == nil,
                  !profile.isDeleted, profile.modelContext != nil else { return }
            try remote.validate()
            guard try payload(profile, in: context) == local else { status = .pending; return }
            guard remote.revision == journal.cloudRevision else {
                try conflict(remote, local: local, journal: journal, owner: account.ownerID, in: context); return
            }
            let protected = try preservingRecovery(in: saved, against: PlanCloudSnapshot.decode(local))
            try PlanMutation.perform(in: context) {
                let restored = try protected.restore(in: context)
                let record = PlanContinuityRecord.upsert(profileID: restored.id, in: context)
                record.cloudOwnerID = account.ownerID; record.cloudRevision = remote.revision
                record.syncedFingerprint = nil; record.preservedLocalSnapshot = local
                record.pendingSnapshot = nil; record.pendingOperationID = nil
                record.conflictingSnapshot = nil; record.conflictingRevision = nil
            }
            NotificationCenter.default.post(name: Self.didRestore, object: nil)
            status = .pending; detail = "Your previous plan copy is restored and queued to sync."
            schedule()
        } catch {
            guard generation == epoch else { return }
            status = .unavailable; detail = "Your previous copy couldn't be restored. Your current plan is still here."
        }
    }

    func forgetDeletedAccount(in context: ModelContext) throws {
        if setupIntent != .resetting { saveSetupIntent(nil) }
        suspendForLocalChange()
        try PlanMutation.perform(in: context) {
            for record in try context.fetch(FetchDescriptor<PlanContinuityRecord>()) {
                record.cloudOwnerID = nil; record.cloudRevision = 0; record.syncedFingerprint = nil
                record.pendingOperationID = nil; record.pendingSnapshot = nil
                record.conflictingSnapshot = nil; record.conflictingRevision = nil
                record.preservedLocalSnapshot = nil; record.lastSyncedAt = nil
            }
        }
    }
}
