import Foundation
import SwiftData

/// The week in review — adherence, volume against last week, what the coach adapted and why, PRs,
/// and a look at what's next. Every line computed from the athlete's own records; no-shame framing
/// throughout (moved sessions are noted as moved, never failed).
@MainActor
enum CoachWeekRecap {

    /// Half-open interval test — `DateInterval.contains` includes its end, which would double-count
    /// anything timestamped exactly on a week boundary into both weeks.
    private static func within(_ date: Date, _ interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }

    static func sections(profile: UserProfile, workouts: [Workout], events: [CoachingEvent],
                         today: Date = Date(), calendar: Calendar = .current) -> [CoachSection] {
        guard var week = calendar.dateInterval(of: .weekOfYear, for: today) else { return [] }
        // "How was my week?" in the first days of a fresh, still-empty week means LAST week — the
        // Monday-morning ask (and the Monday proactive recap) reviews the week that just closed.
        let daysIn = calendar.dateComponents([.day], from: week.start, to: today).day ?? 0
        if daysIn < 2, !workouts.contains(where: { within($0.startedAt, week) }),
           let previous = calendar.dateInterval(of: .weekOfYear, for: week.start.addingTimeInterval(-1)) {
            week = previous
        }
        var out: [CoachSection] = []
        let unit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto

        // 1. Sessions — planned vs done so far this week (only days that have already happened).
        if let plan = profile.plan {
            let weekSessions = plan.sessions.filter { within($0.date, week) }
            let elapsed = weekSessions.filter { calendar.startOfDay(for: $0.date) <= calendar.startOfDay(for: today) }
            let done = elapsed.filter { $0.status == .completed }.count
            let moved = weekSessions.filter { $0.status == .moved }.count
            if !weekSessions.isEmpty {
                var line = "\(done) of \(elapsed.count) planned session\(elapsed.count == 1 ? "" : "s") done so far"
                let remaining = weekSessions.count - elapsed.count
                if remaining > 0 { line += ", \(remaining) still ahead" }
                if moved > 0 { line += ", \(moved) moved (never failed)" }
                line += "."
                out.append(CoachSection(icon: "checkmark.circle", title: "Sessions", detail: line))
            }
        }

        // 2. Volume — this week vs last, from what was actually recorded.
        let thisWeek = workouts.filter { within($0.startedAt, week) }
        if let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start),
           let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastWeekStart) {
            let previous = workouts.filter { within($0.startedAt, lastWeek) }
            let dist = thisWeek.compactMap { $0.gps?.distanceM }.reduce(0, +)
            let prevDist = previous.compactMap { $0.gps?.distanceM }.reduce(0, +)
            if dist > 0 {
                var line = "\(Formatters.distance(meters: dist, unit: unit)) across \(thisWeek.count) workout\(thisWeek.count == 1 ? "" : "s")"
                if prevDist > 0 {
                    let pct = Int(((dist - prevDist) / prevDist * 100).rounded())
                    line += pct >= 0 ? ", up \(pct)% on last week" : ", down \(abs(pct))% on last week"
                }
                line += "."
                out.append(CoachSection(icon: "point.topleft.down.curvedto.point.bottomright.up", title: "Volume", detail: line))
            } else if !thisWeek.isEmpty {
                out.append(CoachSection(icon: "clock", title: "Volume",
                                        detail: "\(thisWeek.count) workout\(thisWeek.count == 1 ? "" : "s"), \(Formatters.duration(s: thisWeek.map(\.durationS).reduce(0, +))) of work."))
            }
        }

        // 3. What the coach changed — the adaptation log for this week, in plain words.
        let weekEvents = events.filter { within($0.date, week) }.sorted { $0.date < $1.date }
        if let latest = weekEvents.last {
            let day = latest.date.formatted(.dateTime.weekday(.wide))
            out.append(CoachSection(icon: latest.kind.systemImage, title: "Adaptation",
                                    detail: "\(day): \(latest.headline.lowercased()). \(latest.detail)"))
        }

        // 4. Records set this week.
        let prs = (profile.prs).filter { within($0.achievedAt, week) }
        if !prs.isEmpty {
            out.append(CoachSection(icon: "trophy", title: "Records",
                                    detail: "\(prs.count) personal record\(prs.count == 1 ? "" : "s") this week. Earned, not given."))
        }

        // 5. What's next — the coming week at a glance ("ahead" stays true even when the recap
        // anchored back to last week on a Monday ask).
        if let plan = profile.plan,
           let nextStart = calendar.date(byAdding: .weekOfYear, value: 1, to: week.start),
           let nextWeek = calendar.dateInterval(of: .weekOfYear, for: nextStart) {
            let next = plan.sessions.filter { within($0.date, nextWeek) }
            if !next.isEmpty {
                var line = "\(next.count) session\(next.count == 1 ? "" : "s")"
                if let long = next.first(where: { $0.runType == .long }), let d = long.targetDistanceM {
                    line += ", headlined by a \(Formatters.distance(meters: d, unit: unit)) long run"
                }
                line += "."
                out.append(CoachSection(icon: "arrow.right", title: "The week ahead", detail: line))
            }
        }

        return out
    }
}
