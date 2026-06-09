import Foundation

/// Proactive "Momentum noticed…" nudges — the deterministic half of the conversational layer
/// (`docs/ATHLETE-MODEL.md` §9). Pure rules over the persisted Tier-A facts: the model speaks first,
/// surfacing what changed. No-shame throughout (a quiet week is a gentle nudge, never "you're
/// slipping"). The wording is templated here; an LLM may later re-voice it, but the triggers stay
/// deterministic and testable.
@MainActor
struct AthleteNudges {
    enum Kind: String, Sendable {
        case caution, milestone, encouragement, checkin

        var systemImage: String {
            switch self {
            case .caution: "exclamationmark.triangle.fill"
            case .milestone: "trophy.fill"
            case .encouragement: "flame.fill"
            case .checkin: "hand.wave.fill"
            }
        }
    }

    struct Nudge: Identifiable, Sendable, Equatable {
        let kind: Kind
        let title: String
        let text: String
        var id: String { title }
    }

    static let maxNudges = 3

    /// Generate up to `maxNudges` nudges from the (live) Tier-A facts, highest-priority first.
    static func generate(_ f: AthleteFacts, now: Date = Date(), calendar: Calendar = .current) -> [Nudge] {
        var nudges: [Nudge] = []

        // 1. Caution — past the load this athlete historically struggles with. (Safety first.)
        if f.currentACWR > 0, f.currentACWR >= f.overreachThresholdACWR {
            nudges.append(.init(kind: .caution, title: "Ease up this week",
                                text: "Your load is at \(fmt(f.currentACWR))× — right around where you tend to overreach. Keep the next one easy."))
        }

        // 2. Milestone — measurably fitter at the same effort.
        if f.paceAtEffortTrendPct <= -3 {
            nudges.append(.init(kind: .milestone, title: "You're getting faster",
                                text: "Easy pace is down \(Int(abs(f.paceAtEffortTrendPct).rounded()))% at the same effort. That's real fitness."))
        }

        // 3. Milestone — a recent PR.
        if let last = f.lastPRAt, let cut = calendar.date(byAdding: .day, value: -7, to: now), last >= cut {
            nudges.append(.init(kind: .milestone, title: "New personal record",
                                text: "You set a new best this week — momentum's building."))
        }

        // 4. Encouragement — showing up more than before.
        if f.frequencyTrend28d >= 0.5 {
            nudges.append(.init(kind: .encouragement, title: "You're showing up",
                                text: "You're training more than last month. Consistency compounds — keep it rolling."))
        }

        // 5. Check-in — a quieter stretch. Gentle, never shaming.
        if f.frequencyTrend28d <= -0.5 {
            nudges.append(.init(kind: .checkin, title: "Let's keep it rolling",
                                text: "It's been a little quieter lately — even a short session keeps your momentum alive."))
        }

        return Array(nudges.prefix(maxNudges))
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}
