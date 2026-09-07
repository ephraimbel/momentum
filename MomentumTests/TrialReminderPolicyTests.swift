import Testing
import Foundation
@testable import Momentum

/// When the "your trial ends" reminder fires, and what it says. The defect this pins: on a three
/// day trial the old rule fired the morning after subscribing, before the first run.
@Suite("TrialReminderPolicy")
struct TrialReminderPolicyTests {
    let cal = Calendar(identifier: .gregorian)
    /// Monday 2026-09-07 20:15 local: an evening purchase, the common case.
    var start: Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 20, minute: 15))! }

    @Test func aWeekLongTrialWarnsTwoDaysOutAndAShortOneTheDayBefore() {
        #expect(TrialReminderPolicy.leadDays(trialDays: 7) == 2)
        #expect(TrialReminderPolicy.leadDays(trialDays: 14) == 2)
        #expect(TrialReminderPolicy.leadDays(trialDays: 3) == 1)
        #expect(TrialReminderPolicy.leadDays(trialDays: 5) == 1)
        #expect(TrialReminderPolicy.leadDays(trialDays: 2) == nil)
        #expect(TrialReminderPolicy.leadDays(trialDays: 0) == nil)
    }

    /// Three day trial bought Monday evening: bills Thursday evening; the reminder is Wednesday at
    /// nine in the morning, never Tuesday morning, and after two possible run days.
    @Test func aThreeDayTrialNeverHearsItOnDayOne() throws {
        let fire = try #require(TrialReminderPolicy.fireDate(trialStart: start, trialDays: 3, now: start, calendar: cal))
        let c = cal.dateComponents([.weekday, .hour, .minute], from: fire)
        #expect(c.weekday == 4 && c.hour == 9 && c.minute == 0)          // Wednesday 09:00
        #expect(fire.timeIntervalSince(start) > 24 * 3600)                 // never inside the first day
        #expect(TrialReminderPolicy.endDate(trialStart: start, trialDays: 3).timeIntervalSince(fire) > 24 * 3600)
    }

    @Test func aSevenDayTrialHearsItTwoDaysBeforeAtNine() throws {
        let fire = try #require(TrialReminderPolicy.fireDate(trialStart: start, trialDays: 7, now: start, calendar: cal))
        let c = cal.dateComponents([.weekday, .hour], from: fire)
        #expect(c.weekday == 7 && c.hour == 9)                             // Saturday 09:00 for a Monday start
    }

    @Test func aReminderWhoseMomentHasPassedIsNotScheduled() {
        let late = start.addingTimeInterval(2.5 * 86_400)                  // Thursday morning already
        #expect(TrialReminderPolicy.fireDate(trialStart: start, trialDays: 3, now: late, calendar: cal) == nil)
    }

    /// The body opens with the athlete's own work when there is any, then the terms, then the way
    /// out. Plain sentences, no dash marks.
    @Test @MainActor func theBodyLeadsWithWhatTheAthleteHasDone() {
        let end = TrialReminderPolicy.endDate(trialStart: start, trialDays: 3)
        let none = TrialReminderPolicy.body(completedSessions: 0, renewText: "$79.99/year", endDate: end)
        let one = TrialReminderPolicy.body(completedSessions: 1, renewText: "$79.99/year", endDate: end)
        let two = TrialReminderPolicy.body(completedSessions: 2, renewText: "$79.99/year", endDate: end)
        #expect(none.hasPrefix("momentum Pro renews at $79.99/year on"))
        #expect(one.hasPrefix("One session in the book with your plan."))
        #expect(two.hasPrefix("Two sessions in the book with your plan."))
        for b in [none, one, two] {
            #expect(b.hasSuffix("Cancel anytime before then."))
            #expect(NotificationCopy.isClean(b), "\(b)")
            CoachVoiceTests.assertCoachVoice(b, "trial reminder")
        }
        #expect(TrialReminderPolicy.title(trialDays: 3) == "Your free trial ends tomorrow")
        #expect(TrialReminderPolicy.title(trialDays: 7) == "Your free trial ends in 2 days")
    }
}
