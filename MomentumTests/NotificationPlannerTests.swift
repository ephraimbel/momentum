import Foundation
import SwiftData
import Testing
@testable import Momentum

/// The plan's whole notification schedule, decided in one pure pass (notification pass 2026-09-06).
/// These pin the frequency contract: one reminder per training day, at most one catch-up and it
/// lands only on an otherwise silent morning, one win-back ten days out, the Sunday preview from
/// the plan itself, race eve and morning from the plan's race sessions. Nothing fires in the past,
/// nothing carries a dash, and every id lives under the one prefix the resync replaces.
@MainActor
struct NotificationPlannerTests {

    private let cal = Calendar.current

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func makePlan(in ctx: ModelContext, sessions: [PlannedSession]) -> TrainingPlan {
        let profile = UserProfile()
        profile.distanceUnit = "metric"
        let plan = TrainingPlan()
        ctx.insert(profile)
        ctx.insert(plan)
        for s in sessions { ctx.insert(s) }
        plan.sessions = sessions
        profile.plan = plan
        try? ctx.save()
        return plan
    }

    /// A morning "now": today at 06:00, so a 7:30 reminder for today is still ahead.
    private var morning: Date { cal.date(bySettingHour: 6, minute: 0, second: 0, of: Date())! }
    private var today: Date { cal.startOfDay(for: Date()) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    private func run(_ offset: Int, km: Double = 8, type: RunType = .easy,
                     status: SessionStatus = .planned) -> PlannedSession {
        let s = PlannedSession()
        s.date = day(offset); s.discipline = .running; s.runType = type
        s.status = status; s.targetDistanceM = km * 1000; s.targetPaceSPerKm = 370
        return s
    }

    private func lift(_ offset: Int) -> PlannedSession {
        let s = PlannedSession()
        s.date = day(offset); s.discipline = .strength; s.status = .planned
        return s
    }

    private var options: NotificationPlanner.Options {
        var o = NotificationPlanner.Options()
        o.distanceUnit = .metric
        return o
    }

    // MARK: Session reminders

    @Test func oneReminderPerTrainingDayMergesARunAndALift() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let run = run(1), lift = lift(1)
        // Lift inserted first on purpose: the store hands relationships back in any order, and
        // the run must still lead (title and tap target both).
        let plan = makePlan(in: ctx, sessions: [lift, run])
        let reminders = NotificationPlanner.sessionReminders(for: plan, now: morning, hour: 7, minute: 30,
                                                             unit: .metric, calendar: cal)
        #expect(reminders.count == 1)
        let r = try #require(reminders.first)
        #expect(r.title == "Run and lift day")
        #expect(r.body.contains("Easy run 8 km"))
        #expect(r.body.contains(". "))                       // both prescriptions, as sentences
        #expect(r.route == .planSession(run.id))
        #expect(r.family == .session)
        #expect(r.sound)
        #expect(r.id.hasPrefix(NotificationPlanner.prefix))
    }

    @Test func remindersCoverSevenDaysAndSkipTodayOnceItsTimeHasPassed() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = makePlan(in: ctx, sessions: [run(0), run(3), run(7), run(8)])
        let evening = cal.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        let reminders = NotificationPlanner.sessionReminders(for: plan, now: evening, hour: 7, minute: 30,
                                                             unit: .metric, calendar: cal)
        // Today's 7:30 has passed; +8 is past the horizon.
        #expect(reminders.map { $0.fire.day } == [cal.component(.day, from: day(3)), cal.component(.day, from: day(7))])
    }

    // MARK: Catch-up

    @Test func catchUpLandsOnTheFirstSilentMorningAfterASession() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        // Today, tomorrow, +3. Tomorrow morning has its own reminder, so the first silent
        // morning after a session is +2.
        let plan = makePlan(in: ctx, sessions: [run(0), run(1), run(3)])
        let catchUp = try #require(NotificationPlanner.catchUp(for: plan, now: morning, hour: 7, minute: 30, calendar: cal))
        #expect(catchUp.id == NotificationPlanner.catchUpID)
        #expect(cal.date(from: catchUp.fire) == cal.date(bySettingHour: 7, minute: 30, second: 0, of: day(2)))
        #expect(catchUp.title == "Yesterday's run moves forward")
        #expect(catchUp.route == .plan)
        #expect(!catchUp.sound)                                // quiet: a morning after, never a jolt
        #expect(catchUp.family == .catchUp)
    }

    @Test func catchUpSpeaksTheSessionsDiscipline() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = makePlan(in: ctx, sessions: [lift(0)])
        let catchUp = try #require(NotificationPlanner.catchUp(for: plan, now: morning, hour: 7, minute: 30, calendar: cal))
        #expect(catchUp.title == "Yesterday's lift moves forward")
    }

    @Test func aDoneSessionEarnsNoCatchUp() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = makePlan(in: ctx, sessions: [run(0, status: .completed)])
        #expect(NotificationPlanner.catchUp(for: plan, now: morning, hour: 7, minute: 30, calendar: cal) == nil)
    }

    @Test func atMostOneCatchUpPerResync() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = makePlan(in: ctx, sessions: [run(0), run(2), run(4)])
        let all = NotificationPlanner.payloads(for: plan, now: morning, hour: 7, minute: 30,
                                               options: options, calendar: cal)
        #expect(all.filter { $0.family == .catchUp }.count == 1)
    }

    // MARK: Win-back

    @Test func winbackIsTenDaysOutAtTheReminderTime() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = makePlan(in: ctx, sessions: [run(2)])
        let winback = try #require(NotificationPlanner.winback(for: plan, now: morning, hour: 17, minute: 0, calendar: cal))
        #expect(cal.date(from: winback.fire) == cal.date(bySettingHour: 17, minute: 0, second: 0, of: day(10)))
        #expect(winback.route == .plan)
        #expect(!winback.sound)
        #expect(winback.title == "Your plan kept your place")
    }

    @Test func aFinishedPlanHasNoPlaceToKeep() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = makePlan(in: ctx, sessions: [run(-3, status: .completed), run(-1, status: .completed)])
        #expect(NotificationPlanner.winback(for: plan, now: morning, hour: 7, minute: 30, calendar: cal) == nil)
    }

    // MARK: Weekly

    @Test func nextSundayEveningIsTheComingSundayAtSix() {
        let sunday = NotificationPlanner.nextSundayEvening(after: morning, calendar: cal)!
        #expect(cal.component(.weekday, from: sunday) == 1)
        #expect(cal.component(.hour, from: sunday) == 18)
        #expect(sunday > morning)
        #expect(cal.dateComponents([.day], from: today, to: sunday).day! <= 7)
        // From Sunday 19:00 the coming one is a week away; from Sunday 17:00 it is tonight.
        let late = cal.date(bySettingHour: 19, minute: 0, second: 0, of: sunday)!
        let next = NotificationPlanner.nextSundayEvening(after: late, calendar: cal)!
        #expect(cal.dateComponents([.day], from: cal.startOfDay(for: sunday), to: next).day == 7)
        let early = cal.date(bySettingHour: 17, minute: 0, second: 0, of: sunday)!
        #expect(cal.isDate(NotificationPlanner.nextSundayEvening(after: early, calendar: cal)!, inSameDayAs: sunday))
    }

    @Test func weeklyPreviewsTheSevenDaysAfterItFires() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let sunday = NotificationPlanner.nextSundayEvening(after: morning, calendar: cal)!
        let sundayStart = cal.startOfDay(for: sunday)
        func after(_ n: Int) -> Int { cal.dateComponents([.day], from: today, to: sundayStart).day! + n }
        let long = run(after(6), km: 16, type: .long)
        let plan = makePlan(in: ctx, sessions: [run(after(1), km: 6), run(after(3), km: 8), long,
                                               lift(after(2)), run(after(9), km: 30)])   // +9 is past the preview
        let weekly = try #require(NotificationPlanner.weekly(for: plan, now: morning, unit: .metric, calendar: cal))
        #expect(weekly.id == NotificationPlanner.weeklyID)
        #expect(weekly.fire.hour == 18 && weekly.fire.minute == 0)
        #expect(weekly.route == .progress("Trends"))
        #expect(weekly.body == "Next week: 3 runs and 1 lift, 30 km of running. Long run \(long.date.formatted(.dateTime.weekday(.wide))).")
    }

    @Test func weeklyWithOnlyRunsSpeaksTheTotal() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let sunday = NotificationPlanner.nextSundayEvening(after: morning, calendar: cal)!
        let offset = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: sunday)).day!
        let plan = makePlan(in: ctx, sessions: [run(offset + 2, km: 10), run(offset + 4, km: 12)])
        let weekly = try #require(NotificationPlanner.weekly(for: plan, now: morning, unit: .metric, calendar: cal))
        #expect(weekly.body == "Next week: 2 runs, 22 km in total.")
    }

    @Test func weeklyFallsBackWhenNothingIsPlannedAhead() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = makePlan(in: ctx, sessions: [run(-2, status: .completed)])
        let weekly = try #require(NotificationPlanner.weekly(for: plan, now: morning, unit: .metric, calendar: cal))
        #expect(weekly.body == "See how the week landed and what comes next.")
    }

    // MARK: Race

    @Test func raceEveAndMorningComeFromTheRaceSession() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let race = run(5, km: 21.1, type: .race)
        let plan = makePlan(in: ctx, sessions: [run(1), race])
        let notes = NotificationPlanner.raceNotes(for: plan, now: morning, unit: .metric, calendar: cal)
        #expect(notes.count == 2)
        let eve = try #require(notes.first { $0.id.contains("race.eve") })
        let day = try #require(notes.first { $0.id.contains("race.day") })
        #expect(cal.date(from: eve.fire) == cal.date(bySettingHour: 19, minute: 0, second: 0, of: self.day(4)))
        #expect(cal.date(from: day.fire) == cal.date(bySettingHour: 6, minute: 0, second: 0, of: self.day(5)))
        #expect(eve.body.hasPrefix("21.1 km tomorrow."))
        #expect(eve.route == .planSession(race.id) && day.route == .planSession(race.id))
        #expect(eve.sound && !day.sound)                        // the morning one never wakes anyone
        #expect(eve.relevance == 1.0 && day.relevance == 1.0)
    }

    @Test func aRunRaceOrAPastOneSchedulesNothing() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = makePlan(in: ctx, sessions: [run(-2, type: .race), run(3, type: .race, status: .completed)])
        #expect(NotificationPlanner.raceNotes(for: plan, now: morning, unit: .metric, calendar: cal).isEmpty)
    }

    // MARK: The whole schedule

    @Test func everyPayloadIsFutureCleanAndPrefixed() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let strength = lift(2); strength.strengthLabel = "push"
        let plan = makePlan(in: ctx, sessions: [run(0), run(1, type: .tempo), strength, run(4, km: 16, type: .long),
                                               run(6, type: .intervals), run(9, km: 21.1, type: .race)])
        let all = NotificationPlanner.payloads(for: plan, now: morning, hour: 7, minute: 30,
                                               options: options, calendar: cal)
        #expect(!all.isEmpty)
        for p in all {
            #expect(p.id.hasPrefix(NotificationPlanner.prefix), "\(p.id)")
            #expect(NotificationCopy.isClean(p.title), "\(p.title)")
            #expect(NotificationCopy.isClean(p.body), "\(p.body)")
            #expect(!p.title.contains("!") && !p.body.contains("!"), "\(p.body)")
            let fire = try #require(cal.date(from: p.fire))
            #expect(fire > morning, "\(p.id)")
        }
        // No two requests share an id (a duplicate would silently replace the first).
        #expect(Set(all.map(\.id)).count == all.count)
        // The families that exist in this fixture.
        let families = Set(all.map(\.family))
        #expect(families.isSuperset(of: [.session, .catchUp, .winback, .weekly, .race]))
    }

    @Test func noPlanMeansNothingAndTogglesGateTheirFamilies() throws {
        #expect(NotificationPlanner.payloads(for: nil, now: morning, hour: 7, minute: 30, options: options, calendar: cal).isEmpty)
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = makePlan(in: ctx, sessions: [run(1), run(3)])
        var noSessions = options; noSessions.sessionReminders = false
        let onlyWeekly = NotificationPlanner.payloads(for: plan, now: morning, hour: 7, minute: 30, options: noSessions, calendar: cal)
        #expect(onlyWeekly.map(\.family) == [.weekly])
        var noWeekly = options; noWeekly.weekly = false
        let rest = NotificationPlanner.payloads(for: plan, now: morning, hour: 7, minute: 30, options: noWeekly, calendar: cal)
        #expect(!rest.contains { $0.family == .weekly })
        #expect(rest.contains { $0.family == .session })
    }

    @Test func dayTitlesReadAsACoachWould() {
        let r = run(0), l = lift(0), w = PlannedSession(); w.discipline = .walking
        #expect(NotificationPlanner.dayTitle([r]) == "Run day")
        #expect(NotificationPlanner.dayTitle([l]) == "Lift day")
        #expect(NotificationPlanner.dayTitle([r, l]) == "Run and lift day")
        #expect(NotificationPlanner.dayTitle([r, r]) == "Run day")   // two runs are still a run day
        #expect(NotificationPlanner.dayTitle([w]) == "Walk day")
        #expect(NotificationPlanner.dayTitle([]) == "Session day")
    }
}
