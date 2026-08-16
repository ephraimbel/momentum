import Foundation

/// The athlete's notification choices (Settings → Notifications) — enterprise pass 2026-08-15.
/// UserDefaults-backed with **true defaults**: an absent key means "on", so existing installs keep
/// their behavior until the athlete says otherwise. Every scheduler in `NotificationService` (and
/// the coaching-push path in `CoachSurface`) consults these before scheduling; turning a type off
/// also clears anything of that type already pending.
enum NotificationPrefs {
    static let sessionKey = "notify.sessionReminders"
    static let coachingKey = "notify.coaching"
    static let streakKey = "notify.streak"
    static let weeklyKey = "notify.weekly"
    static let morningKey = "notify.morningReadiness"
    /// "learned" (default — the reminder rides the athlete's own training rhythm) | "custom".
    static let reminderModeKey = "notify.reminderMode"
    static let customHourKey = "notify.customHour"
    static let customMinuteKey = "notify.customMinute"

    /// Absent = true — notifications are opt-out per type, having been opted into at the system level.
    private static func flag(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func sessionRemindersEnabled(_ d: UserDefaults = .standard) -> Bool { flag(sessionKey, in: d) }
    static func coachingEnabled(_ d: UserDefaults = .standard) -> Bool { flag(coachingKey, in: d) }
    static func streakEnabled(_ d: UserDefaults = .standard) -> Bool { flag(streakKey, in: d) }
    static func weeklyEnabled(_ d: UserDefaults = .standard) -> Bool { flag(weeklyKey, in: d) }
    static func morningReadinessEnabled(_ d: UserDefaults = .standard) -> Bool { flag(morningKey, in: d) }

    static func set(_ key: String, to value: Bool, in d: UserDefaults = .standard) {
        d.set(value, forKey: key)
    }

    /// The athlete's explicit reminder time, when they've chosen one. nil → learned/default timing.
    static func customReminderTime(_ d: UserDefaults = .standard) -> (hour: Int, minute: Int)? {
        guard d.string(forKey: reminderModeKey) == "custom",
              d.object(forKey: customHourKey) != nil else { return nil }
        let hour = d.integer(forKey: customHourKey)
        let minute = d.integer(forKey: customMinuteKey)
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    static func setCustomReminderTime(hour: Int, minute: Int, in d: UserDefaults = .standard) {
        d.set("custom", forKey: reminderModeKey)
        d.set(hour, forKey: customHourKey)
        d.set(minute, forKey: customMinuteKey)
    }

    static func clearCustomReminderTime(in d: UserDefaults = .standard) {
        d.set("learned", forKey: reminderModeKey)
    }
}

/// At most **one** background coaching push per local day — the "keeps you updated without being
/// crazy" contract. The bell inbox keeps every decision regardless; the push is just the knock on
/// the door, and one knock a day is plenty.
enum CoachPushBudget {
    static let dayKey = "notify.coachPush.day"

    /// True exactly once per local day; subsequent calls the same day return false.
    @discardableResult
    static func tryConsume(now: Date = Date(), calendar: Calendar = .current,
                           defaults: UserDefaults = .standard) -> Bool {
        let day = calendar.startOfDay(for: now).timeIntervalSinceReferenceDate
        guard defaults.double(forKey: dayKey) != day else { return false }
        defaults.set(day, forKey: dayKey)
        return true
    }
}

/// Learned reminder timing (enterprise pass 2026-08-15): the Athlete Model already counts every
/// completed session by hour of day (`trainingHourHistogram`), so the morning reminder can ride
/// the athlete's own rhythm instead of a hardcoded 7:30 — a 6 pm runner shouldn't hear from us at
/// dawn. Pure and fixture-tested.
enum ReminderTiming {
    /// The default everyone starts on, and the floor of evidence needed to leave it.
    static let fallback = (hour: 7, minute: 30)
    static let minimumSessions = 10

    /// When and how to remind, from the athlete's training-hour histogram:
    /// - fewer than `minimumSessions` sessions → the 7:30 fallback (no guessing off thin data);
    /// - habitual hour ≥ 9 → two hours before (time to eat, dress, get out the door);
    /// - habitual hour < 9 → one hour before, never earlier than 6 am (a dawn athlete gets a
    ///   6:00 nudge, not a 4 am alarm);
    /// - always clamped to 6:00–20:00 so a night lifter's reminder stays civil.
    /// A custom time from Settings overrides all of it — the athlete's word beats the histogram.
    static func reminderTime(histogram: [Int],
                             custom: (hour: Int, minute: Int)? = nil) -> (hour: Int, minute: Int) {
        if let custom { return custom }
        guard histogram.count == 24 else { return fallback }
        let total = histogram.reduce(0, +)
        guard total >= minimumSessions,
              let peak = histogram.indices.max(by: { histogram[$0] < histogram[$1] }),
              histogram[peak] > 0 else { return fallback }
        let lead = peak >= 9 ? 2 : 1
        let hour = min(20, max(6, peak - lead))
        return (hour, 0)
    }
}
