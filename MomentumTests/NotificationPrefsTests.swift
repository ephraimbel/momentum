import Foundation
import Testing
@testable import Momentum

/// The learned-reminder contract (enterprise pass 2026-08-15): timing follows the athlete's own
/// training-hour histogram once there's enough evidence, a Settings custom time always wins, and
/// thin data never guesses.
struct ReminderTimingTests {

    private func histogram(peak: Int, count: Int) -> [Int] {
        var h = Array(repeating: 0, count: 24)
        h[peak] = count
        return h
    }

    @Test func thinDataFallsBackTo730() {
        let t = ReminderTiming.reminderTime(histogram: histogram(peak: 18, count: 9))
        #expect(t == (7, 30))
    }

    @Test func emptyOrMalformedHistogramFallsBack() {
        #expect(ReminderTiming.reminderTime(histogram: []) == (7, 30))
        #expect(ReminderTiming.reminderTime(histogram: Array(repeating: 0, count: 24)) == (7, 30))
        #expect(ReminderTiming.reminderTime(histogram: Array(repeating: 5, count: 12)) == (7, 30))
    }

    @Test func eveningRunnerGetsTwoHourLead() {
        // Habitual 6 pm runner → 4 pm knock, not dawn.
        let t = ReminderTiming.reminderTime(histogram: histogram(peak: 18, count: 12))
        #expect(t == (16, 0))
    }

    @Test func dawnRunnerNeverWokenBeforeSix() {
        // 6 am runner: one-hour lead would be 5 am — floored to 6:00.
        let t = ReminderTiming.reminderTime(histogram: histogram(peak: 6, count: 20))
        #expect(t == (6, 0))
    }

    @Test func morningRunnerGetsOneHourLead() {
        let t = ReminderTiming.reminderTime(histogram: histogram(peak: 8, count: 15))
        #expect(t == (7, 0))
    }

    @Test func nightLifterClampedToEight() {
        // Habitual 11 pm sessions → the 9 pm+ knock stays civil at 20:00.
        let t = ReminderTiming.reminderTime(histogram: histogram(peak: 23, count: 30))
        #expect(t == (20, 0))
    }

    @Test func customTimeBeatsTheHistogram() {
        let t = ReminderTiming.reminderTime(histogram: histogram(peak: 18, count: 50),
                                            custom: (12, 15))
        #expect(t == (12, 15))
    }
}

/// One background coaching push per local day — the anti-nag budget.
struct CoachPushBudgetTests {

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "coach-push-budget-tests")!
        d.removePersistentDomain(forName: "coach-push-budget-tests")
        return d
    }

    @Test func firstConsumeOfTheDaySucceedsSecondFails() {
        let d = freshDefaults()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        #expect(CoachPushBudget.tryConsume(now: noon, defaults: d))
        #expect(!CoachPushBudget.tryConsume(now: noon, defaults: d))
        // Later the same day — still spent.
        let evening = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: noon)!
        #expect(!CoachPushBudget.tryConsume(now: evening, defaults: d))
    }

    @Test func budgetResetsAtLocalMidnight() {
        let d = freshDefaults()
        let today = Calendar.current.startOfDay(for: Date())
        #expect(CoachPushBudget.tryConsume(now: today, defaults: d))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        #expect(CoachPushBudget.tryConsume(now: tomorrow, defaults: d))
        #expect(!CoachPushBudget.tryConsume(now: tomorrow, defaults: d))
    }
}

/// The readiness refresh fires at the next 6:30 — same-day when it's still ahead, else tomorrow.
@MainActor
struct MorningReadinessRefreshTests {

    @Test func nextMorningIsTheComingSixThirty() {
        let cal = Calendar.current
        let fiveAM = cal.date(bySettingHour: 5, minute: 0, second: 0, of: Date())!
        let next = MorningReadinessRefresh.nextMorning(after: fiveAM, calendar: cal)
        #expect(cal.component(.hour, from: next) == 6)
        #expect(cal.component(.minute, from: next) == 30)
        #expect(cal.isDate(next, inSameDayAs: fiveAM))       // 6:30 still ahead → today

        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let tomorrow = MorningReadinessRefresh.nextMorning(after: noon, calendar: cal)
        #expect(tomorrow > noon)
        #expect(!cal.isDate(tomorrow, inSameDayAs: noon))    // this morning's has passed → tomorrow
        #expect(cal.component(.hour, from: tomorrow) == 6)
    }
}

/// The prefs storage contract: absent keys read as ON (opt-out per type), and the custom reminder
/// time round-trips only when the mode is actually "custom" with sane values.
struct NotificationPrefsTests {

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "notification-prefs-tests")!
        d.removePersistentDomain(forName: "notification-prefs-tests")
        return d
    }

    @Test func absentKeysDefaultToOn() {
        let d = freshDefaults()
        #expect(NotificationPrefs.sessionRemindersEnabled(d))
        #expect(NotificationPrefs.coachingEnabled(d))
        #expect(NotificationPrefs.streakEnabled(d))
        #expect(NotificationPrefs.weeklyEnabled(d))
        #expect(NotificationPrefs.morningReadinessEnabled(d))
    }

    @Test func togglesPersist() {
        let d = freshDefaults()
        NotificationPrefs.set(NotificationPrefs.coachingKey, to: false, in: d)
        #expect(!NotificationPrefs.coachingEnabled(d))
        NotificationPrefs.set(NotificationPrefs.coachingKey, to: true, in: d)
        #expect(NotificationPrefs.coachingEnabled(d))
    }

    @Test func onboardingChoiceMatchesThePermissionPromise() {
        let d = freshDefaults()
        NotificationPrefs.setOnboardingChoice(enabled: true, in: d)
        #expect(NotificationPrefs.sessionRemindersEnabled(d))
        #expect(NotificationPrefs.coachingEnabled(d))
        #expect(!NotificationPrefs.streakEnabled(d))
        #expect(!NotificationPrefs.weeklyEnabled(d))
        #expect(!NotificationPrefs.morningReadinessEnabled(d))

        NotificationPrefs.setOnboardingChoice(enabled: false, in: d)
        #expect(!NotificationPrefs.sessionRemindersEnabled(d))
        #expect(!NotificationPrefs.coachingEnabled(d))
    }

    @Test func customTimeRoundTripsAndClears() {
        let d = freshDefaults()
        #expect(NotificationPrefs.customReminderTime(d) == nil)
        NotificationPrefs.setCustomReminderTime(hour: 17, minute: 45, in: d)
        #expect(NotificationPrefs.customReminderTime(d)! == (17, 45))
        NotificationPrefs.clearCustomReminderTime(in: d)
        #expect(NotificationPrefs.customReminderTime(d) == nil)
    }

    @Test func garbageCustomTimeIsIgnored() {
        let d = freshDefaults()
        d.set("custom", forKey: NotificationPrefs.reminderModeKey)
        d.set(31, forKey: NotificationPrefs.customHourKey)
        d.set(0, forKey: NotificationPrefs.customMinuteKey)
        #expect(NotificationPrefs.customReminderTime(d) == nil)
    }
}
