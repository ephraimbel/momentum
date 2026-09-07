import Foundation

/// Where a notification lands when it is tapped (notification pass 2026-09-06).
///
/// Every notification the app produces carries one of these, whether it is a local push, the
/// in-app toast, or a row in the bell inbox, and every one of them resolves through the SAME
/// mailbox: `AppRouter.pendingNotificationRoute`, consumed once by `RootView`. A reminder about a
/// session opens that session; a plan change opens the session that changed; readiness opens the
/// Health hub; the trial reminder opens Settings. A notification that merely opened the app and
/// left the athlete on Today was the shape every family had before this existed.
///
/// String-coded on purpose: the value rides in `UNNotificationContent.userInfo` (a plist, so a
/// string) and in the inbox's route map (UserDefaults), and both must survive a version that no
/// longer knows a case, so decoding an unknown string yields nil rather than a crash.
enum NotificationRoute: Equatable, Hashable, Sendable {
    /// The Today page (map, deck, Start).
    case today
    /// The Plan board on the current week.
    case plan
    /// The Plan board on the week holding `date`.
    case planWeek(Date)
    /// The Plan board on that session's week, with its detail sheet open.
    case planSession(UUID)
    /// Progress, landed on a segment (`ProgressScreen.Segment` raw value: "Trends" / "Health" / "History").
    case progress(String)
    /// The coach chat.
    case coach
    /// The Fuel page.
    case fuel
    /// Profile → Settings (the subscription and notification rows live there).
    case settings

    /// `userInfo` keys. The family rides alongside the route so an open can be counted per family.
    static let userInfoKey = "momentum.route"
    static let familyKey = "momentum.family"

    var rawValue: String {
        switch self {
        case .today: "today"
        case .plan: "plan"
        case .planWeek(let date): "plan.week:\(Int(date.timeIntervalSince1970))"
        case .planSession(let id): "plan.session:\(id.uuidString)"
        case .progress(let segment): "progress:\(segment)"
        case .coach: "coach"
        case .fuel: "fuel"
        case .settings: "settings"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard let head = parts.first else { return nil }
        let tail = parts.count > 1 ? parts[1] : nil
        switch head {
        case "today": self = .today
        case "plan": self = .plan
        case "coach": self = .coach
        case "fuel": self = .fuel
        case "settings": self = .settings
        case "plan.week":
            guard let tail, let seconds = TimeInterval(tail) else { return nil }
            self = .planWeek(Date(timeIntervalSince1970: seconds))
        case "plan.session":
            guard let tail, let id = UUID(uuidString: tail) else { return nil }
            self = .planSession(id)
        case "progress":
            guard let tail, !tail.isEmpty else { return nil }
            self = .progress(tail)
        default:
            return nil
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.userInfoKey] as? String else { return nil }
        self.init(rawValue: raw)
    }

    /// The tab the route lives on. `.coach` is a cover over whatever tab is showing.
    var tab: AppTab? {
        switch self {
        case .today: .today
        case .plan, .planWeek, .planSession: .plan
        case .progress: .progress
        case .fuel: .fuel
        case .settings: .profile
        case .coach: nil
        }
    }

    /// The tap destination for a coaching decision. Easings and recovery days open the Health hub,
    /// where the readiness "why" lives; pace recalibrations open the Plan board, where the new
    /// paces sit on the sessions; a move opens the moved session itself when the decision knows
    /// which one it was, else the board.
    static func forCoaching(_ kind: CoachingEvent.Kind, focusSessionID: UUID? = nil) -> NotificationRoute {
        switch kind {
        case .ease, .recover: .progress("Health")
        case .recalibrate: .plan
        case .moved: focusSessionID.map(NotificationRoute.planSession) ?? .plan
        }
    }
}

/// The notification families, for lock-screen grouping (`threadIdentifier`) and the open-rate
/// analytics dimension. A family is how a notification is COUNTED, never how it is worded.
enum NotificationFamily: String, CaseIterable, Sendable {
    case session, catchUp, winback, weekly, streak, firstRun, race, coaching, readiness, trial, rest, meal
    /// The post-workout refuel cue (fuel integration 2026-09-06).
    case refuel

    /// Lock-screen grouping: the plan's reminders stack together, coaching decisions together,
    /// and so on, so a quiet week never reads as a pile of unrelated alerts.
    var thread: String {
        switch self {
        case .session, .catchUp, .winback, .weekly, .race, .streak, .firstRun: "momentum.plan"
        case .coaching, .readiness: "momentum.coach"
        case .trial: "momentum.account"
        case .rest: "momentum.rest"
        case .meal, .refuel: "momentum.fuel"
        }
    }
}

/// The bell inbox's route map. `AppNotification` is a released `@Model` (frozen in `SchemaV1`),
/// so a route cannot become a stored property without orphaning every shipped store. The inbox is
/// device-local and never synced, so a small UserDefaults map keyed by the row's id carries it
/// instead: newest last, capped, and a row with no entry falls back to its kind's default door.
enum NotificationRouteStore {
    static let key = "notify.inboxRoutes"
    /// More than the inbox is ever scrolled; pruned oldest-first past this.
    static let cap = 300

    static func set(_ route: NotificationRoute, for id: UUID, in defaults: UserDefaults = .standard) {
        var entries = (defaults.array(forKey: key) as? [[String]]) ?? []
        entries.removeAll { $0.first == id.uuidString }
        entries.append([id.uuidString, route.rawValue])
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        defaults.set(entries, forKey: key)
    }

    static func route(for id: UUID, in defaults: UserDefaults = .standard) -> NotificationRoute? {
        let entries = (defaults.array(forKey: key) as? [[String]]) ?? []
        guard let entry = entries.last(where: { $0.first == id.uuidString }), entry.count == 2 else { return nil }
        return NotificationRoute(rawValue: entry[1])
    }
}

/// Notification copy is plain sentences (owner call 2026-09-06: no dash marks of any kind). The
/// bodies are assembled from coach text that still uses the em-dash idiom in places (a strength
/// brief reads "Push day — 4 exercises"), so every string is scrubbed at the door: an em or en
/// dash becomes a sentence break, a hyphen between words becomes a space.
enum NotificationCopy {
    static func clean(_ s: String) -> String {
        var out = s
        if out.contains("—") || out.contains("–") {
            let pieces = out.replacingOccurrences(of: "–", with: "—")
                .components(separatedBy: "—")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            out = pieces.enumerated().reduce(into: "") { acc, e in
                let (idx, piece) = e
                let capped = idx == 0 ? piece : piece.prefix(1).uppercased() + piece.dropFirst()
                if idx == 0 { acc = capped } else { acc += ". " + capped }
            }
        }
        if out.contains("-") {
            out = out.replacingOccurrences(of: "-", with: " ")
            while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// True when the string carries no dash mark at all. The copy tests pin every producer to it.
    static func isClean(_ s: String) -> Bool {
        !s.contains("—") && !s.contains("–") && !s.contains("-")
    }
}
