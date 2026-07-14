import Foundation

/// The compact, display-ready state the Home Screen widget renders — written by the app into the
/// shared App Group whenever Today refreshes, read by the widget extension's timeline. Everything
/// is pre-formatted app-side (units, briefs, streaks) so the widget stays a pure renderer and the
/// two processes never need to share SwiftData.
///
/// This file is compiled into BOTH the app and `MomentumWidgets` (same pattern as the
/// ActivityAttributes files).
struct WidgetSnapshot: Codable, Equatable {

    /// One mark on the week ribbon — the widget's signature element. Iridescence is earned:
    /// only `.done` days get the gradient fill.
    struct DayMark: Codable, Equatable {
        var letter: String                 // "M" — the user's calendar order
        var state: State
        var isToday: Bool

        enum State: String, Codable {
            case done       // a workout landed (or the session completed) — the earned fill
            case planned    // a session is scheduled — hairline ring
            case rest       // deliberately quiet — tiny dot (rest days count; never shame)
        }
    }

    /// The day this snapshot describes ("yyyy-MM-dd", user calendar). A widget waking up on a
    /// later day renders the neutral "open for today" state instead of yesterday's session.
    var dayStamp: String
    var streak: Int
    /// nil = rest day.
    var sessionTitle: String?              // "LONG RUN" (the micro-label)
    var sessionHero: String?               // "6.2 mi" — the big Space Grotesk line
    var sessionDetail: String?             // "~11:56 /mi" (display units, app-side)
    var sessionDone: Bool
    var week: [DayMark]

    /// Gallery placeholder — what the widget looks like in the picker before real data exists.
    static let preview = WidgetSnapshot(
        dayStamp: dayStamp(for: Date()), streak: 3,
        sessionTitle: "Long run", sessionHero: "6.2 mi", sessionDetail: "at an easy pace",
        sessionDone: false,
        week: [.init(letter: "S", state: .rest, isToday: false),
               .init(letter: "M", state: .done, isToday: false),
               .init(letter: "T", state: .done, isToday: false),
               .init(letter: "W", state: .rest, isToday: false),
               .init(letter: "T", state: .done, isToday: false),
               .init(letter: "F", state: .planned, isToday: true),
               .init(letter: "S", state: .planned, isToday: false)])

    // MARK: App Group IO

    static let appGroup = "group.com.ephraimbel.momentum.app"
    static let storageKey = "widget.today.v1"

    static func dayStamp(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    var describesToday: Bool { dayStamp == Self.dayStamp(for: Date()) }

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.appGroup)?.set(data, forKey: Self.storageKey)
    }
}
