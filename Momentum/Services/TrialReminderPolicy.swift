import Foundation

/// When and how the "your trial ends" reminder speaks. Pure, so the timing is unit tested.
///
/// The old rule fired at `trialDays − 2`, which on a three day trial is the morning after
/// subscribing: the first notification the app ever sent a new athlete told them how to cancel,
/// before they had run a step. A cancelled trial keeps its access until it expires, so nothing the
/// app did on day two could win that person back.
///
/// Now: a week long trial hears it two days out, a three to six day trial the day before it bills,
/// and a one or two day trial never (there is no honest moment for it). It lands at nine in the
/// morning, not at the odd minute of the purchase. And the body leads with what the athlete has
/// done with the plan, refreshed on every plan resync, so by the time it fires it can say "two
/// sessions in the book" rather than open with the renewal price.
enum TrialReminderPolicy {
    /// Days before billing the reminder fires; nil when the trial is too short to warn honestly.
    static func leadDays(trialDays: Int) -> Int? {
        if trialDays >= 7 { return 2 }
        if trialDays >= 3 { return 1 }
        return nil
    }

    /// When the trial bills.
    static func endDate(trialStart: Date, trialDays: Int) -> Date {
        trialStart.addingTimeInterval(Double(trialDays) * 86_400)
    }

    /// The local 09:00 on the day the reminder is due, or nil when the trial is too short or the
    /// moment has already passed.
    static func fireDate(trialStart: Date, trialDays: Int, now: Date = Date(),
                         calendar: Calendar = .current) -> Date? {
        guard let lead = leadDays(trialDays: trialDays) else { return nil }
        let due = endDate(trialStart: trialStart, trialDays: trialDays).addingTimeInterval(-Double(lead) * 86_400)
        var comps = calendar.dateComponents([.year, .month, .day], from: due)
        comps.hour = 9; comps.minute = 0
        guard let fire = calendar.date(from: comps), fire > now else { return nil }
        return fire
    }

    static func title(trialDays: Int) -> String {
        switch leadDays(trialDays: trialDays) {
        case 1?: return "Your free trial ends tomorrow"
        case let d?: return "Your free trial ends in \(d) days"
        case nil: return "Your free trial is ending"
        }
    }

    /// Leads with the athlete's own work when there is any, then the renewal terms, then the way
    /// out. Plain sentences, no dash marks.
    static func body(completedSessions: Int, renewText: String, endDate: Date) -> String {
        let when = endDate.formatted(date: .abbreviated, time: .omitted)
        let terms = "momentum Pro renews at \(renewText) on \(when). Cancel anytime before then."
        switch completedSessions {
        case ..<1: return terms
        case 1:    return "One session in the book with your plan. \(terms)"
        default:   return "\(CoachNotes.numberWord(completedSessions).capitalized) sessions in the book with your plan. \(terms)"
        }
    }
}
