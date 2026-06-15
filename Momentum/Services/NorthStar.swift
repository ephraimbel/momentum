import Foundation

/// The north-star funnel for a single device/athlete (PRD §13.5, EXECUTION-PLAN cross-cutting):
/// *did this new user complete their first workout **and** view the AI read within 24h of first
/// launch.* Pure value type so the rule is unit-testable; the live tracker persists the three dates.
struct NorthStarFunnel: Equatable {
    var firstLaunch: Date?
    var firstWorkout: Date?
    var firstAIRead: Date?

    enum Status: Equatable {
        case pending          // not enough has happened yet (still inside or before the window)
        case achieved         // both milestones hit within 24h of first launch
        case missed           // the 24h window closed without both milestones
    }

    private static let window: TimeInterval = 24 * 60 * 60

    /// Evaluate the funnel as of `now`. Achieved only when BOTH the first workout and the first AI
    /// read landed within 24h of first launch; missed once the window closes incomplete.
    func status(now: Date) -> Status {
        guard let firstLaunch else { return .pending }
        let deadline = firstLaunch.addingTimeInterval(Self.window)
        if let w = firstWorkout, let r = firstAIRead, w <= deadline, r <= deadline {
            return .achieved
        }
        return now >= deadline ? .missed : .pending
    }
}

/// Persists the funnel dates (UserDefaults, no PII) and exposes `status`. The analytics service marks
/// launch on init and stamps the first workout / first AI read exactly once.
@MainActor
final class NorthStarTracker {
    private let defaults: UserDefaults
    private enum Key {
        static let launch = "com.momentum.northstar.firstLaunch"
        static let workout = "com.momentum.northstar.firstWorkout"
        static let aiRead = "com.momentum.northstar.firstAIRead"
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Record first launch once — the clock the 24h window is measured from.
    func markLaunch(now: Date = Date()) { setOnce(Key.launch, now) }
    /// Stamp the first completed workout (idempotent).
    func markFirstWorkout(now: Date = Date()) { setOnce(Key.workout, now) }
    /// Stamp the first AI read view (idempotent).
    func markFirstAIRead(now: Date = Date()) { setOnce(Key.aiRead, now) }

    var funnel: NorthStarFunnel {
        NorthStarFunnel(
            firstLaunch: defaults.object(forKey: Key.launch) as? Date,
            firstWorkout: defaults.object(forKey: Key.workout) as? Date,
            firstAIRead: defaults.object(forKey: Key.aiRead) as? Date)
    }

    func status(now: Date = Date()) -> NorthStarFunnel.Status { funnel.status(now: now) }

    private func setOnce(_ key: String, _ date: Date) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(date, forKey: key)
    }
}
