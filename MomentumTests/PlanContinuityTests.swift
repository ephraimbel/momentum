import Foundation
import SwiftData
import Testing
@testable import Momentum

@Suite(.serialized)
@MainActor
struct PlanContinuityTests {
    private final class ContinuityURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // URLSession commonly hands a custom URLProtocol an upload stream rather than keeping
            // `httpBody` populated. Materialize it so assertions and responders inspect the bytes
            // that production actually sent instead of accidentally treating every body as empty.
            var received = request
            if received.httpBody == nil, let stream = received.httpBodyStream {
                let body = Self.read(stream)
                // `httpBody` and `httpBodyStream` are mutually exclusive. Explicitly clear the
                // stream first; otherwise Foundation can keep returning nil from `httpBody` even
                // after the assignment, causing body-aware stubs to accept every request.
                received.httpBodyStream = nil
                received.httpBody = body
            }
            Self.requests.append(received)
            let stub = Self.responder?(received) ?? (201, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.0,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.1)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                result.append(buffer, count: count)
            }
            return result
        }
    }

    private func container() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
    private func athlete(in context: ModelContext) throws -> UserProfile {
        let profile = UserProfile(), plan = TrainingPlan(), session = PlannedSession()
        profile.displayName = "Runner"; profile.disciplines = [Discipline.running.rawValue]
        profile.daysPerWeek = 3; profile.sessionMinutes = 45
        profile.weeklyRunVolumeM = 30_000; profile.longestRunM = 12_000
        plan.name = "My 10K"; plan.p5kSPerKm = 300; plan.disciplines = profile.disciplines
        session.date = Date().addingTimeInterval(86_400); session.discipline = .running
        session.runType = .tempo; session.targetDistanceM = 8_000; session.targetDurationS = 2_700
        session.targetPaceSPerKm = 320; session.intervals = "3 x 8 min"
        context.insert(profile); context.insert(plan); context.insert(session)
        plan.sessions = [session]; profile.plan = plan
        try context.save()
        return profile
    }
    private func readiness() -> IllnessResponse.Readiness {
        .init(improving: true, feverFreeWithoutMedicineFor24Hours: true,
              dailyActivitiesComfortable: true, clinicianAdvisedReturn: true, exerciseWellTolerated: true)
    }
    private func outing(in context: ModelContext, at date: Date, minutes: Double = 10) throws -> Workout {
        let workout = Workout(), gps = GPSDetail()
        workout.type = .run; workout.startedAt = date; workout.durationS = minutes * 60
        workout.elapsedS = workout.durationS; workout.perceivedEffort = 3
        gps.distanceM = minutes * 120; gps.avgPaceSPerKm = 500; workout.gps = gps
        context.insert(workout); try context.save(); return workout
    }
    private enum TestFailure: Error { case lostAcknowledgement, failedSave }
    private final class Cloud: PlanCloudTransport {
        var value: PlanCloudVersion?
        var commits = 0
        var reads = 0
        var loseNextAcknowledgement = false
        var onRead: (() -> Void)?
        func read(identity: PlanCloudIdentity) async throws -> PlanCloudVersion? {
            reads += 1
            let action = onRead; onRead = nil; action?()
            return value
        }
        func commit(data: Data, expectedRevision: Int, operationID: UUID,
                    identity: PlanCloudIdentity) async throws -> PlanCloudVersion {
            commits += 1
            if let value, value.operationID == operationID || value.revision != expectedRevision { return value }
            if value == nil, expectedRevision != 0 { throw TestFailure.failedSave }
            let next = PlanCloudVersion(revision: expectedRevision + 1,
                                        snapshot: try PlanCloudSnapshot.decode(data), operationID: operationID)
            value = next
            if loseNextAcknowledgement { loseNextAcknowledgement = false; throw TestFailure.lostAcknowledgement }
            return next
        }
    }
    private final class IdentityBox { var value: PlanCloudIdentity?; init(_ value: PlanCloudIdentity) { self.value = value } }
    private func service(_ cloud: Cloud, owner: UUID, defaults: UserDefaults? = nil) -> PlanSyncService {
        PlanSyncService(transport: cloud, defaults: defaults ?? UserDefaults(suiteName: "continuity.\(UUID())")!, identity: { PlanCloudIdentity(ownerID: owner, token: "fixture") })
    }

    @Test func freshDeviceResetSurvivesRelaunchAndRequiresChoiceForNewPlan() async throws {
        let suite = "continuity.reset.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = Cloud(), owner = UUID(), c = try container()
        _ = try athlete(in: c.mainContext)
        let first = service(cloud, owner: owner, defaults: defaults)
        await first.begin(account: "runner", isGuest: false, expectedOwner: owner, in: c.mainContext)
        let original = try #require(cloud.value).snapshot.coach.plan?.id
        first.prepareForLocalReset()
        try await DataManager.deleteAllUserData(container: c)
        first.finishLocalReset(account: "runner", isGuest: false, expectedOwner: owner, in: c.mainContext)
        first.prepareForAccountSwitch()
        let reads = cloud.reads, commits = cloud.commits
        let relaunched = service(cloud, owner: owner, defaults: defaults)
        await relaunched.begin(account: "runner", isGuest: false, expectedOwner: owner, in: c.mainContext)
        await relaunched.retry()
        #expect(relaunched.restoreChecked && relaunched.status == .local)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<UserProfile>()) == 0)
        #expect(cloud.reads == reads && cloud.commits == commits)
        let newProfile = try athlete(in: c.mainContext)
        await relaunched.retry()
        #expect(relaunched.status == .conflict)
        #expect(newProfile.plan?.id != original)
        #expect(cloud.value?.snapshot.coach.plan?.id == original)
        relaunched.prepareForAccountSwitch()
    }

    @Test func interruptedResetBlocksEveryAccountAndCanFinishAfterRelaunch() async throws {
        let suite = "continuity.reset.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = Cloud(), owner = UUID(), c = try container()
        _ = try athlete(in: c.mainContext)
        _ = try outing(in: c.mainContext, at: Date())
        let first = service(cloud, owner: owner, defaults: defaults)
        await first.begin(account: "runner", isGuest: false, expectedOwner: owner, in: c.mainContext)
        let original = cloud.value?.snapshot.coach.plan?.id
        first.prepareForLocalReset()
        let reads = cloud.reads, commits = cloud.commits
        let relaunched = service(cloud, owner: owner, defaults: defaults)
        #expect(relaunched.status == .resetRequired)
        await relaunched.begin(account: "runner", isGuest: false, expectedOwner: owner, in: c.mainContext)
        await relaunched.retry()
        relaunched.allowNewLocalPlan()
        #expect(relaunched.status == .resetRequired && !relaunched.restoreChecked)
        let guest = PlanSyncService(enabled: false, transport: cloud, defaults: defaults, identity: { nil })
        await guest.begin(account: nil, isGuest: true, in: c.mainContext)
        #expect(guest.status == .resetRequired && !guest.restoreChecked)
        #expect(cloud.reads == reads && cloud.commits == commits)
        await relaunched.finishInterruptedReset()
        #expect(relaunched.status == .local && relaunched.restoreChecked && !relaunched.finishingReset)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<UserProfile>()) == 0)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<Workout>()) == 0)
        #expect(cloud.value?.snapshot.coach.plan?.id == original)
        let third = service(cloud, owner: owner, defaults: defaults)
        await third.begin(account: "runner", isGuest: false, expectedOwner: owner, in: c.mainContext)
        #expect(third.status == .local && third.restoreChecked)
        #expect(cloud.reads == reads && cloud.commits == commits)
    }

    @Test func freshSetupFollowsOwnerAliasesWithoutBlockingOtherAccounts() async throws {
        let suite = "continuity.reset.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = Cloud(), owner = UUID(), c = try container()
        let offline = service(cloud, owner: owner, defaults: defaults)
        await offline.begin(account: "apple", isGuest: false, in: c.mainContext)
        offline.allowNewLocalPlan()
        let online = service(cloud, owner: owner, defaults: defaults)
        await online.begin(account: "apple", isGuest: false, expectedOwner: owner, in: c.mainContext)
        #expect(online.status == .local && online.restoreChecked)
        let alias = service(cloud, owner: owner, defaults: defaults)
        await alias.begin(account: "email", isGuest: false, expectedOwner: owner, in: c.mainContext)
        #expect(alias.status == .local && alias.restoreChecked)
        let p = try athlete(in: c.mainContext)
        await alias.retry()
        #expect(alias.status == .current)
        // Completing setup clears the shared owner intent, including the former login alias.
        let freshStore = try container(), originalAlias = service(cloud, owner: owner, defaults: defaults)
        await originalAlias.begin(account: "apple", isGuest: false, expectedOwner: owner, in: freshStore.mainContext)
        #expect(try freshStore.mainContext.fetch(FetchDescriptor<UserProfile>()).first?.plan?.id == p.plan?.id)
        let unrelated = service(Cloud(), owner: UUID(), defaults: defaults)
        await unrelated.begin(account: "another", isGuest: false, in: try container().mainContext)
        #expect(unrelated.status == .unavailable && !unrelated.restoreChecked)
    }

    @Test func httpTransportPreservesSnapshotAndUsesAuthenticatedRevisionedWireContract() async throws {
        let c = try container(), p = try athlete(in: c.mainContext)
        let snapshot = try PlanCloudSnapshot.capture(p, in: c.mainContext)
        let data = try snapshot.encoded(), owner = UUID(), operation = UUID()
        let object = try JSONSerialization.jsonObject(with: data)
        let row: [String: Any] = ["revision": 7, "operation_id": operation.uuidString, "snapshot": object]
        let response = try JSONSerialization.data(withJSONObject: row)
        let listResponse = try JSONSerialization.data(withJSONObject: [row])
        ContinuityURLProtocol.requests = []
        ContinuityURLProtocol.responder = { request in (200, request.httpMethod == "GET" ? listResponse : response) }
        defer { ContinuityURLProtocol.responder = nil; ContinuityURLProtocol.requests = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContinuityURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = HTTPPlanCloudTransport(session: session)
        let identity = PlanCloudIdentity(ownerID: owner, token: "fixture-token")
        let restored = try await transport.read(identity: identity)
        #expect(restored?.snapshot.coach.plan?.id == p.plan?.id)
        #expect(restored?.snapshot.coach.plan?.sessions.first?.date == p.plan?.sessions.first?.date)
        let committed = try await transport.commit(data: data, expectedRevision: 6, operationID: operation, identity: identity)
        #expect(committed.revision == 7 && committed.operationID == operation)
        let requests = ContinuityURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
        #expect(requests.first?.url?.query?.contains(owner.uuidString) == true)
        let post = try #require(requests.last)
        #expect(post.url?.path.hasSuffix("/rpc/commit_plan_continuity") == true)
        let bodyData = try #require(post.httpBody)
        let bodyObject = try JSONSerialization.jsonObject(with: bodyData)
        let body = try #require(bodyObject as? [String: Any])
        #expect(body["p_expected_revision"] as? Int == 6)
        #expect(body["p_operation_id"] as? String == operation.uuidString)
        let uploaded = try JSONSerialization.data(withJSONObject: #require(body["p_snapshot"]))
        #expect(try PlanCloudSnapshot.decode(uploaded).encoded() == data)
    }

    @Test func httpTransportRejectsExpiredAuthentication() async throws {
        ContinuityURLProtocol.responder = { _ in (401, Data("{}".utf8)) }
        defer { ContinuityURLProtocol.responder = nil; ContinuityURLProtocol.requests = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContinuityURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = HTTPPlanCloudTransport(session: session)
        do {
            _ = try await transport.read(identity: .init(ownerID: UUID(), token: "expired-fixture"))
            Issue.record("An expired token must not be treated as an empty cloud plan")
        } catch HTTPPlanCloudTransport.Failure.unauthenticated { }
    }

    @Test func snapshotRestoresPlanIdentityPreferencesAndCompletedEvidence() throws {
        let a = try container(), b = try container(), context = a.mainContext
        let p = try athlete(in: context), session = try #require(p.plan?.sessions.first)
        let workout = try outing(in: context, at: Date().addingTimeInterval(-86_400))
        PlanCoaching.markComplete(session, with: workout, in: context)
        let prefs = PlanPreferencesRecord.upsert(profileID: p.id, in: context)
        prefs.regularRunLimitS = 1_800; prefs.longRunLimitS = 5_400
        prefs.benchmarkDistanceM = 5_000; prefs.benchmarkTimeS = 1_500
        try context.save()
        let snapshot = try PlanCloudSnapshot.decode(PlanCloudSnapshot.capture(p, in: context).encoded())
        let restored = try PlanMutation.perform(in: b.mainContext) { try snapshot.restore(in: b.mainContext) }
        #expect(restored.id == p.id && restored.plan?.id == p.plan?.id)
        #expect(restored.plan?.sessions.first?.completedWorkout?.id == workout.id)
        #expect(restored.plan?.sessions.first?.completedWorkout?.gps?.distanceM == workout.gps?.distanceM)
        #expect(restored.planPreferences?.regularRunLimitS == 1_800)
        #expect(restored.planPreferences?.benchmarkTimeS == 1_500)
        #expect(try b.mainContext.fetchCount(FetchDescriptor<Workout>()) == 1)
    }

    @Test func generatedHybridRacePlanRestoresSidecarsAndStabilizesAcrossDevices() throws {
        let a = try container(), b = try container()
        ExerciseLibrarySeed.seedIfNeeded(into: a.mainContext)
        let vm = OnboardingViewModel()
        vm.activities = [.run, .strength]; vm.goal = .raceDistance
        vm.raceDistance = .half; vm.hasRace = true
        vm.raceDate = Date().addingTimeInterval(12 * 7 * 86_400)
        vm.chooseRunningBackground(.experienced)
        vm.weeklyRunVolumeM = 40_000; vm.longestRunM = 15_000
        let profile = try vm.finish(in: a.mainContext)
        let snapshot = try PlanCloudSnapshot.capture(profile, in: a.mainContext)
        #expect(!snapshot.metadata.isEmpty)
        #expect(snapshot.coach.plan?.sessions.contains { !$0.strength.isEmpty } == true)
        _ = try athlete(in: b.mainContext)
        let restored = try PlanMutation.perform(in: b.mainContext) { try snapshot.restore(in: b.mainContext) }
        let first = try PlanCloudSnapshot.capture(restored, in: b.mainContext)
        _ = try PlanMutation.perform(in: b.mainContext) { try first.restore(in: b.mainContext) }
        let second = try PlanCloudSnapshot.capture(restored, in: b.mainContext)
        #expect(try first.encoded() == second.encoded(), "An unchanged restored plan must not create endless sync revisions")
        #expect(second.coach.plan?.id == snapshot.coach.plan?.id)
        #expect(second.coach.plan?.sessions.count == snapshot.coach.plan?.sessions.count)
        #expect(try b.mainContext.fetchCount(FetchDescriptor<PlanMetadataRecord>()) == snapshot.metadata.count)
    }

    @Test func snapshotRetainsLocalWorkoutSamplesAndDoesNotDuplicateEvidence() throws {
        let c = try container(), context = c.mainContext
        let p = try athlete(in: context)
        let workout = try outing(in: context, at: Date().addingTimeInterval(-86_400))
        let snapshot = try PlanCloudSnapshot.capture(p, in: context)
        workout.note = "Keep this local edit"
        try context.save()
        _ = try PlanMutation.perform(in: context) { try snapshot.restore(in: context) }
        #expect(try context.fetchCount(FetchDescriptor<Workout>()) == 1)
        #expect(try context.fetch(FetchDescriptor<Workout>()).first?.note == "Keep this local edit")
        #expect(try context.fetch(FetchDescriptor<Workout>()).first?.id == workout.id)
    }

    @Test func injuryProtectionSurvivesNewSessionsAndRepeatedSaves() throws {
        let c = try container(), context = c.mainContext, p = try athlete(in: context)
        _ = InjuryResponse.report(area: .knee, severity: .twinge, profile: p, in: context)
        let first = try #require(p.plan?.sessions.first)
        let distance = first.targetDistanceM
        try PlanMutation.perform(in: context) { p.displayName = "Updated name" }
        #expect(first.targetDistanceM == distance)
        let added = PlannedSession()
        try PlanMutation.perform(in: context) {
            context.insert(added)
            added.date = first.date; added.discipline = .running; added.runType = .intervals
            added.targetDistanceM = 5_000; added.targetPaceSPerKm = 300
            p.plan?.sessions.append(added)
        }
        #expect(added.runType == .easy)
        #expect(added.rationale?.hasPrefix(InjuryResponse.marker) == true)
    }

    @Test func injuryKeepsRaceIdentityAndRequiresReturnBeforeStartingIt() throws {
        let c = try container(), context = c.mainContext, p = try athlete(in: context)
        let race = try #require(p.plan?.sessions.first)
        race.runType = .race; race.targetDistanceM = 10_000; race.intervals = nil
        let date = race.date, id = race.id
        try context.save()
        _ = InjuryResponse.report(area: .knee, severity: .moderate, profile: p, in: context)
        #expect(race.id == id && race.date == date && race.runType == .race)
        #expect(race.targetDistanceM == 10_000 && race.discipline == .running)
        #expect(!PlanCoaching.canStartPlannedSession(race, profile: p))
        #expect(!PlanCoaching.todaySessions(p.plan, on: date).contains { $0.id == id })
    }

    @Test func conflictingPlanChoiceCannotClearAnActiveInjury() async throws {
        for useCloud in [true, false] {
            let a = try container(), b = try container(), cloud = Cloud(), owner = UUID()
            let pa = try athlete(in: a.mainContext), sa = service(cloud, owner: owner), sb = service(cloud, owner: owner)
            await sa.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: a.mainContext)
            await sb.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: b.mainContext)
            let pb = try #require(try b.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
            _ = InjuryResponse.report(area: .knee, severity: .moderate, profile: pa, in: a.mainContext)
            pb.plan?.name = "Other plan edit"; try b.mainContext.save()
            await sa.retry(); await sb.retry()
            #expect(sb.status == .conflict)
            await sb.resolve(useCloud: useCloud)
            let selected = try #require(try b.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
            #expect(selected.activeInjuryArea == InjuryArea.knee.rawValue)
            #expect(selected.activeInjurySeverity == InjurySeverity.moderate.rawValue)
            #expect(selected.plan?.sessions.first?.discipline == .cycling)
            #expect(selected.continuity?.preservedLocalSnapshot != nil)
        }
    }

    @Test func malformedAndUnknownSnapshotsAreRejectedBeforeMutation() throws {
        let c = try container(), p = try athlete(in: c.mainContext)
        var snapshot = try PlanCloudSnapshot.capture(p, in: c.mainContext)
        snapshot.version = 2
        #expect(throws: (any Error).self) { try snapshot.restore(in: c.mainContext) }
        snapshot.version = 1
        snapshot.coach.plan?.sessions[0].targetDistanceM = -10
        #expect(throws: (any Error).self) { try snapshot.validate() }
        #expect(p.plan?.sessions.first?.targetDistanceM == 8_000)
    }

    @Test func snapshotRejectsDanglingCompletionAndDuplicateSessionIDs() throws {
        let c = try container(), p = try athlete(in: c.mainContext)
        var snapshot = try PlanCloudSnapshot.capture(p, in: c.mainContext)
        snapshot.coach.plan?.sessions[0].completedWorkoutID = UUID()
        #expect(throws: (any Error).self) { try snapshot.validate() }
        snapshot.coach.plan?.sessions[0].completedWorkoutID = nil
        let first = try #require(snapshot.coach.plan?.sessions.first)
        snapshot.coach.plan?.sessions.append(first)
        #expect(throws: (any Error).self) { try snapshot.validate() }
    }

    @Test func freshDeviceRestoresWithoutRegeneratingThePlan() async throws {
        let a = try container(), b = try container(), cloud = Cloud(), owner = UUID()
        let p = try athlete(in: a.mainContext)
        let source = service(cloud, owner: owner), destination = service(cloud, owner: owner)
        await source.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: a.mainContext)
        #expect(source.status == .current)
        await destination.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: b.mainContext)
        let restored = try #require(try b.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(destination.restoreChecked && restored.plan?.id == p.plan?.id)
        #expect(restored.plan?.sessions.first?.targetPaceSPerKm == 320)
        #expect(cloud.commits == 1)
    }

    @Test func demoIdentityNeverUploadsSeededTraining() async throws {
        let c = try container(), cloud = Cloud(), owner = UUID()
        _ = try athlete(in: c.mainContext)
        let sync = service(cloud, owner: owner)
        await sync.begin(account: "demo-user", isGuest: false, expectedOwner: owner, in: c.mainContext)
        await sync.retry()
        #expect(sync.status == .local && sync.restoreChecked)
        #expect(cloud.commits == 0 && cloud.value == nil)
    }

    @Test func lostAcknowledgementRecoversAfterReopeningTheDiskStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("outbox.store")
        let schema = Schema(versionedSchema: SchemaV8.self), cloud = Cloud(), owner = UUID()
        var operation: UUID?
        do {
            let c = try ModelContainer(for: schema, migrationPlan: MomentumMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url)])
            let p = try athlete(in: c.mainContext), sync = service(cloud, owner: owner)
            cloud.loseNextAcknowledgement = true
            await sync.begin(account: "runner", isGuest: false, expectedOwner: owner, in: c.mainContext)
            operation = try #require(p.continuity?.pendingOperationID)
            #expect(sync.status == .unavailable && cloud.value?.operationID == operation)
            sync.prepareForAccountSwitch()
        }
        let reopened = try ModelContainer(for: schema, migrationPlan: MomentumMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)])
        let p = try #require(try reopened.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(p.continuity?.pendingOperationID == operation)
        let relaunched = service(cloud, owner: owner)
        await relaunched.begin(account: "runner", isGuest: false, expectedOwner: owner, in: reopened.mainContext)
        #expect(relaunched.status == .current && p.continuity?.pendingOperationID == nil)
        #expect(p.continuity?.cloudRevision == 1 && cloud.value?.revision == 1 && cloud.commits == 1)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<TrainingPlan>()) == 1)
        relaunched.prepareForAccountSwitch()
    }

    @Test func lostAcknowledgementRetriesWithoutAnotherRevision() async throws {
        let c = try container(), cloud = Cloud(), owner = UUID(), p = try athlete(in: c.mainContext)
        let sync = service(cloud, owner: owner); cloud.loseNextAcknowledgement = true
        await sync.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: c.mainContext)
        #expect(sync.status == .unavailable && p.continuity?.pendingOperationID != nil)
        await sync.retry()
        #expect(sync.status == .current && p.continuity?.pendingOperationID == nil)
        #expect(cloud.value?.revision == 1 && cloud.commits == 1)
    }

    @Test func concurrentPlansRequireChoiceAndKeepIllnessInBothDirections() async throws {
        for useCloud in [true, false] {
            let a = try container(), b = try container(), cloud = Cloud(), owner = UUID()
            let pa = try athlete(in: a.mainContext), sa = service(cloud, owner: owner), sb = service(cloud, owner: owner)
            await sa.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: a.mainContext)
            await sb.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: b.mainContext)
            let pb = try #require(try b.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
            pa.plan?.name = "Device A edit"; try a.mainContext.save()
            try IllnessResponse.pause(profile: pb, in: b.mainContext)
            await sa.retry(); await sb.retry()
            #expect(sb.status == .conflict)
            #expect(pb.plan?.name == "My 10K")
            await sb.resolve(useCloud: useCloud)
            let selected = try #require(try b.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
            #expect(IllnessResponse.state(for: selected)?.phase == .resting)
            #expect(selected.continuity?.preservedLocalSnapshot != nil)
            #expect(selected.plan?.name == (useCloud ? "Device A edit" : "My 10K"))
        }
    }

    @Test func eitherConflictChoicePreservesBothDevicesCompletedTraining() async throws {
        for useCloud in [true, false] {
            let a = try container(), b = try container(), cloud = Cloud(), owner = UUID()
            let pa = try athlete(in: a.mainContext)
            let source = service(cloud, owner: owner), destination = service(cloud, owner: owner)
            await source.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: a.mainContext)
            await destination.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: b.mainContext)
            let pb = try #require(try b.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
            let credited = try #require(pa.plan?.sessions.first)
            let completed = try outing(in: a.mainContext, at: Date().addingTimeInterval(-86_400))
            PlanCoaching.markComplete(credited, with: completed, in: a.mainContext)
            let localWorkout = try outing(in: b.mainContext, at: Date().addingTimeInterval(-2 * 86_400))
            pb.plan?.name = "Device B choice"; try b.mainContext.save()
            await source.retry(); await destination.retry()
            #expect(destination.status == .conflict)
            await destination.resolve(useCloud: useCloud)
            let restored = try #require(try b.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
            let session = try #require(restored.plan?.sessions.first { $0.id == credited.id })
            #expect(session.status == .completed && session.completedWorkout?.id == completed.id)
            #expect(Set(try b.mainContext.fetch(FetchDescriptor<Workout>()).map(\.id)) == [completed.id, localWorkout.id])
            #expect(restored.plan?.name == (useCloud ? "My 10K" : "Device B choice"))
            await destination.retry()
            #expect(cloud.value?.snapshot.workouts.count == 2)
            #expect(cloud.value?.snapshot.coach.plan?.sessions.first?.completedWorkoutID == completed.id)
        }
    }

    @Test func restoringAnOlderCopyKeepsLocalCompletionAndItsOriginalPrescription() throws {
        let c = try container(), context = c.mainContext, p = try athlete(in: context)
        let session = try #require(p.plan?.sessions.first)
        let older = try PlanCloudSnapshot.capture(p, in: context)
        let originalDate = Date().addingTimeInterval(-86_400)
        session.date = originalDate; session.targetDistanceM = 6_000
        let workout = try outing(in: context, at: originalDate)
        PlanCoaching.markComplete(session, with: workout, in: context)
        _ = try PlanMutation.perform(in: context) { try older.restore(in: context) }
        let restored = try #require(p.plan?.sessions.first)
        #expect(restored.status == .completed && restored.completedWorkout?.id == workout.id)
        #expect(restored.date == originalDate && restored.targetDistanceM == 6_000)
        #expect(workout.plannedSession?.id == restored.id)
    }

    @Test func completedExtraSessionSurvivesRestoringTheSamePlan() throws {
        let c = try container(), context = c.mainContext, p = try athlete(in: context)
        let older = try PlanCloudSnapshot.capture(p, in: context)
        let extra = PlannedSession(), workout = try outing(in: context, at: Date().addingTimeInterval(-86_400))
        context.insert(extra); extra.date = workout.startedAt; extra.discipline = .running
        extra.runType = .easy; extra.targetDistanceM = 2_000
        p.plan?.sessions.append(extra)
        PlanCoaching.markComplete(extra, with: workout, in: context)
        _ = try PlanMutation.perform(in: context) { try older.restore(in: context) }
        #expect(p.plan?.sessions.count == 2)
        #expect(p.plan?.sessions.first { $0.id == extra.id }?.completedWorkout?.id == workout.id)
    }

    @Test func changedIdentityDuringRequestCannotRestoreAnotherAccount() async throws {
        let source = try container(), destination = try container(), cloud = Cloud(), owner = UUID()
        _ = try athlete(in: source.mainContext)
        await service(cloud, owner: owner).begin(account: "fixture", isGuest: false, expectedOwner: owner, in: source.mainContext)
        let identity = IdentityBox(.init(ownerID: owner, token: "fixture"))
        let sync = PlanSyncService(transport: cloud, identity: { identity.value })
        cloud.onRead = { identity.value = .init(ownerID: UUID(), token: "different") }
        await sync.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: destination.mainContext)
        #expect(try destination.mainContext.fetchCount(FetchDescriptor<UserProfile>()) == 0)
    }

    @Test func localEditsDuringReadAreNeverOverwritten() async throws {
        let c = try container(), cloud = Cloud(), owner = UUID(), p = try athlete(in: c.mainContext)
        let sync = service(cloud, owner: owner)
        await sync.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: c.mainContext)
        cloud.onRead = { p.plan?.name = "Edited while waiting" }
        await sync.retry()
        #expect(p.plan?.name == "Edited while waiting" && sync.status == .pending)
        #expect(cloud.commits == 1)
    }

    @Test func missingPreviouslySyncedPlanIsNotRecreatedSilently() async throws {
        let c = try container(), cloud = Cloud(), owner = UUID()
        _ = try athlete(in: c.mainContext)
        let sync = service(cloud, owner: owner)
        await sync.begin(account: "fixture", isGuest: false, expectedOwner: owner, in: c.mainContext)
        cloud.value = nil
        await sync.retry()
        #expect(sync.status == .unavailable && cloud.commits == 1)
    }

    @Test func accountBindingRequiresMatchingProviderIdentity() {
        let id = UUID()
        #expect(AuthController.boundCloudOwner(localID: "email:\(id.uuidString)", cloudID: id, appleIDs: []) == id)
        #expect(AuthController.boundCloudOwner(localID: "google:\(UUID().uuidString)", cloudID: id, appleIDs: []) == nil)
        #expect(AuthController.boundCloudOwner(localID: "apple-subject", cloudID: id, appleIDs: ["apple-subject"]) == id)
        #expect(AuthController.boundCloudOwner(localID: "someone-else", cloudID: id, appleIDs: ["apple-subject"]) == nil)
    }

    @Test func illnessRestNeverExpiresAndGenericResumeIsBlocked() throws {
        let c = try container(), p = try athlete(in: c.mainContext)
        try IllnessResponse.pause(profile: p, now: Date().addingTimeInterval(-30 * 86_400), in: c.mainContext)
        let s = try #require(p.plan?.sessions.first)
        #expect(!IllnessResponse.canStart(s, profile: p))
        #expect(IllnessResponse.blocked(.resumePlan, profile: p) != nil)
        #expect(NotificationPlanner.payloads(for: p.plan, hour: 9, minute: 0).isEmpty)
    }

    @Test func firstOutingCapsWholePrescriptionWithoutCompoundingSaves() throws {
        let c = try container(), p = try athlete(in: c.mainContext), now = Date()
        try IllnessResponse.pause(profile: p, now: now, in: c.mainContext)
        try IllnessResponse.checkIn(readiness(), profile: p, now: now, in: c.mainContext)
        let s = try #require(p.plan?.sessions.first), first = IllnessResponse.Prescription(s)
        #expect(s.runType == .recovery && s.intervals == nil)
        #expect((s.targetDurationS ?? 0) <= 900 && (s.targetDistanceM ?? 0) > 0)
        try PlanMutation.perform(in: c.mainContext) { p.displayName = "Another save" }
        #expect(IllnessResponse.Prescription(s) == first)
    }

    @Test func rebuildCannotRemoveRecoveryOrCreateHardReturnSessions() throws {
        let c = try container(), p = try athlete(in: c.mainContext)
        try IllnessResponse.pause(profile: p, in: c.mainContext)
        try IllnessResponse.checkIn(readiness(), profile: p, in: c.mainContext)
        let episode = try #require(IllnessResponse.state(for: p)?.episodeID)
        _ = try PlanMutation.perform(in: c.mainContext) {
            try PlanService.stageRegenerate(for: p, in: c.mainContext)
        }
        #expect(IllnessResponse.state(for: p)?.episodeID == episode)
        let openRuns = p.plan?.sessions.filter {
            $0.discipline == .running && $0.status == .planned && !PlanCoaching.isFixedDate($0)
        } ?? []
        #expect(!openRuns.isEmpty)
        #expect(openRuns.allSatisfy { $0.runType == .recovery && $0.intervals == nil && ($0.targetDurationS ?? 0) <= 900 })
    }

    @Test func failedRestoreSaveRollsBackOriginalPlanAndWorkouts() throws {
        let source = try container(), destination = try container()
        let incoming = try athlete(in: source.mainContext)
        incoming.plan?.name = "Incoming plan"
        let original = try athlete(in: destination.mainContext), originalID = original.plan?.id
        let workout = try outing(in: destination.mainContext, at: Date().addingTimeInterval(-86_400))
        let snapshot = try PlanCloudSnapshot.capture(incoming, in: source.mainContext)
        #expect(throws: (any Error).self) {
            try PlanMutation.perform(in: destination.mainContext, commit: { _ in throw TestFailure.failedSave }) {
                _ = try snapshot.restore(in: destination.mainContext)
            }
        }
        let restored = try #require(try destination.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(restored.id == original.id && restored.plan?.id == originalID && restored.plan?.name == "My 10K")
        #expect(try destination.mainContext.fetch(FetchDescriptor<Workout>()).map(\.id) == [workout.id])
    }

    @Test func returnRequiresElapsedResponseAndPositiveExerciseFeedback() throws {
        let c = try container(), p = try athlete(in: c.mainContext), now = Date()
        let start = now.addingTimeInterval(-2 * 86_400)
        try IllnessResponse.pause(profile: p, now: start, in: c.mainContext)
        try IllnessResponse.checkIn(readiness(), profile: p, now: start, in: c.mainContext)
        let w = try outing(in: c.mainContext, at: start.addingTimeInterval(60))
        IllnessResponse.record(w, profile: p, now: now, in: c.mainContext)
        #expect(throws: (any Error).self) {
            try IllnessResponse.checkIn(readiness(), profile: p, now: start.addingTimeInterval(3_600), in: c.mainContext)
        }
        var unanswered = readiness(); unanswered.exerciseWellTolerated = false
        #expect(throws: (any Error).self) { try IllnessResponse.checkIn(unanswered, profile: p, now: now, in: c.mainContext) }
        try IllnessResponse.checkIn(readiness(), profile: p, now: now, in: c.mainContext)
        #expect(IllnessResponse.state(for: p)?.phase == .building)
    }

    @Test func deletingRecordedOutingCannotUnlockReturn() throws {
        let c = try container(), p = try athlete(in: c.mainContext), now = Date(), start = Date().addingTimeInterval(-2 * 86_400)
        try IllnessResponse.pause(profile: p, now: start, in: c.mainContext)
        try IllnessResponse.checkIn(readiness(), profile: p, now: start, in: c.mainContext)
        let w = try outing(in: c.mainContext, at: start.addingTimeInterval(60))
        IllnessResponse.record(w, profile: p, now: now, in: c.mainContext)
        c.mainContext.delete(w); try c.mainContext.save()
        #expect(throws: (any Error).self) { try IllnessResponse.checkIn(readiness(), profile: p, now: now, in: c.mainContext) }
        #expect(IllnessResponse.state(for: p)?.phase == .firstOuting)
    }

    @Test func hardOrOversizedOutingsDoNotCountAsEasyReturnEvidence() throws {
        let c = try container(), p = try athlete(in: c.mainContext), now = Date(), start = Date().addingTimeInterval(-2 * 86_400)
        try IllnessResponse.pause(profile: p, now: start, in: c.mainContext)
        try IllnessResponse.checkIn(readiness(), profile: p, now: start, in: c.mainContext)
        let w = try outing(in: c.mainContext, at: start.addingTimeInterval(60), minutes: 60)
        IllnessResponse.record(w, profile: p, now: now, in: c.mainContext)
        #expect(IllnessResponse.state(for: p)?.firstOutingID == nil)
        w.durationS = 600; w.elapsedS = 600; w.perceivedEffort = 8
        IllnessResponse.record(w, profile: p, now: now, in: c.mainContext)
        #expect(IllnessResponse.state(for: p)?.firstOutingID == nil)
    }

    @Test func redFlagsPersistAndStaleUndoCannotClearThem() throws {
        let c = try container(), p = try athlete(in: c.mainContext), now = Date()
        let previous = try #require(CoachUndo.capture(p))
        try IllnessResponse.pause(profile: p, now: now, in: c.mainContext)
        var answers = readiness(); answers.concerningSymptoms = true
        #expect(throws: (any Error).self) { try IllnessResponse.checkIn(answers, profile: p, now: now, in: c.mainContext) }
        #expect(IllnessResponse.state(for: p)?.needsClinicalAdvice == true)
        #expect(CoachUndo.restore(previous, profile: p, in: c.mainContext))
        #expect(IllnessResponse.state(for: p)?.needsClinicalAdvice == true)
        answers.concerningSymptoms = false; answers.clinicianAdvisedReturn = false
        #expect(throws: (any Error).self) { try IllnessResponse.checkIn(answers, profile: p, now: now, in: c.mainContext) }
    }

    @Test func returningBaselineExcludesPreIllnessMileageEvenAfterClearingState() throws {
        let c = try container(), p = try athlete(in: c.mainContext), now = Date()
        let old = try outing(in: c.mainContext, at: now.addingTimeInterval(-3 * 86_400), minutes: 60)
        old.gps?.distanceM = 20_000; try c.mainContext.save()
        try IllnessResponse.pause(profile: p, now: now.addingTimeInterval(-86_400), in: c.mainContext)
        try IllnessResponse.save(nil, profile: p, in: c.mainContext)
        let baseline = PlanService.observedFitness(for: p, on: now, in: c.mainContext)
        #expect(baseline.weeklyM == 0 && baseline.longestM == 0)
    }

    @Test func v7StoreMigratesAndPersistsRecoveryAndDurableOutbox() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v7.store"), profileID = UUID(), operationID = UUID()
        do {
            let schema = Schema(versionedSchema: SchemaV7.self)
            let c = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let p = UserProfile(); p.id = profileID; p.displayName = "Existing runner"
            c.mainContext.insert(p); try c.mainContext.save()
        }
        do {
            let schema = Schema(versionedSchema: SchemaV8.self)
            let c = try ModelContainer(for: schema, migrationPlan: MomentumMigrationPlan.self,
                                       configurations: [ModelConfiguration(schema: schema, url: url)])
            let p = try #require(try c.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
            #expect(p.id == profileID && p.displayName == "Existing runner")
            #expect(p.continuity == nil)
            let record = PlanContinuityRecord.upsert(profileID: p.id, in: c.mainContext)
            record.pendingOperationID = operationID; record.pendingSnapshot = Data("durable operation".utf8)
            try IllnessResponse.save(.init(startedAt: Date(), checkedAt: Date()), profile: p, in: c.mainContext)
            try c.mainContext.save()
        }
        let schema = Schema(versionedSchema: SchemaV8.self)
        let reopened = try ModelContainer(for: schema, migrationPlan: MomentumMigrationPlan.self,
                                          configurations: [ModelConfiguration(schema: schema, url: url)])
        let p = try #require(try reopened.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(p.continuity?.pendingOperationID == operationID)
        #expect(p.continuity?.pendingSnapshot == Data("durable operation".utf8))
        #expect(IllnessResponse.state(for: p)?.phase == .resting)
    }
}
