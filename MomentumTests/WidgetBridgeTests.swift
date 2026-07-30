import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The Home Screen widget's snapshot composition — today's session, done detection, the week
/// ribbon's earned/planned/rest states, and the no-shame rule (misses never mark).
@MainActor
struct WidgetBridgeTests {

    /// Returns the container ALONGSIDE its context — the caller must keep the container alive for
    /// the whole test. `let ctx = makeContainer().mainContext` releases the container immediately,
    /// leaving a dangling in-memory store that crashes SwiftData at a later access.
    private func makeStore() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(PersistenceController.models)
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return (container, container.mainContext)
    }

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()).addingTimeInterval(9 * 3600) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    private func makeProfile(in ctx: ModelContext) -> UserProfile {
        let profile = UserProfile()
        let plan = TrainingPlan()
        ctx.insert(profile)
        ctx.insert(plan)
        profile.plan = plan
        try? ctx.save()
        return profile
    }

    @Test func plannedSessionBecomesTheHero() throws {
        let (container, ctx) = try makeStore()
        let profile = makeProfile(in: ctx)
        let session = PlannedSession()
        session.date = today
        session.discipline = .running
        session.runType = .long
        session.status = .planned
        session.targetDistanceM = 10_000
        session.targetPaceSPerKm = 360
        ctx.insert(session)
        profile.plan?.sessions.append(session)
        try? ctx.save()

        let snap = WidgetBridge.build(profile: profile, workouts: [], today: today)
        #expect(snap.sessionTitle == "Long run")
        #expect(snap.sessionHero?.isEmpty == false)      // "10.00 km" / "6.21 mi" by locale
        #expect(snap.sessionDone == false)
        #expect(snap.describesToday)
        #expect(snap.week.count == 7)
        #expect(snap.week.contains { $0.isToday && $0.state == .planned })
        _ = container   // keep the store alive through every SwiftData access above
    }

    @Test func loggedWorkoutMarksTodayDone() throws {
        let (container, ctx) = try makeStore()
        let profile = makeProfile(in: ctx)
        let w = Workout(); w.type = .run; w.startedAt = today; w.durationS = 1_800
        ctx.insert(w)
        try? ctx.save()

        let snap = WidgetBridge.build(profile: profile, workouts: [w], today: today)
        #expect(snap.sessionDone)
        #expect(snap.week.contains { $0.isToday && $0.state == .done })
        _ = container
    }

    @Test func restDayIsQuietAndMissesNeverMark() throws {
        let (container, ctx) = try makeStore()
        let profile = makeProfile(in: ctx)
        // A session earlier this week that never happened — the ribbon must show quiet rest,
        // never a "missed" state (no-shame).
        guard let week = cal.dateInterval(of: .weekOfYear, for: today),
              cal.startOfDay(for: today) > week.start else { return }   // skip on week's first day
        let past = PlannedSession()
        past.date = week.start.addingTimeInterval(9 * 3600)
        past.discipline = .running
        past.runType = .easy
        past.status = .missed
        ctx.insert(past)
        profile.plan?.sessions.append(past)
        try? ctx.save()

        let snap = WidgetBridge.build(profile: profile, workouts: [], today: today)
        #expect(snap.sessionTitle == nil)                 // nothing planned today → rest
        #expect(snap.sessionDone == false)
        #expect(!snap.week.contains { $0.state.rawValue == "missed" })
        _ = container
    }

    @Test func dayStampRollsHonestly() {
        let stamp = WidgetSnapshot.dayStamp(for: today)
        var snap = WidgetSnapshot.preview
        snap.dayStamp = stamp
        #expect(snap.describesToday)
        snap.dayStamp = WidgetSnapshot.dayStamp(for: day(-1))
        #expect(!snap.describesToday)
    }
}
