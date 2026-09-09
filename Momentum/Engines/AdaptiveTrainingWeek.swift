import Foundation

/// Pure weekly policy. The existing macrocycle remains the ceiling, including recovery and taper.
/// Missing measurements are unknown; attendance alone is never evidence for faster paces.
enum AdaptiveTrainingWeek {
    static let minimumRunM = 1609.344

    struct Evidence: Codable, Equatable, Sendable {
        var prescribedRuns = 0
        var completedRuns = 0
        var recordedRuns = 0
        var shortenedRuns = 0
        var movedRuns = 0
        var plannedM = 0.0
        var actualM = 0.0
        var recentWeeklyM = 0.0
        var difficultRuns = 0
        var poorRecovery = false
        var pain = false
        var illness = false
        var exceededEffort = false
        var unableToContinue = false
        var partialWeek = false
        var missedWeeks = 0
        // Optional additions keep previously saved/cloud reviews decodable.
        var actualDurationS: Double?
        var aboveEasyHeartRateRuns: Int?
        var prolongedHardRuns: Int?
    }

    struct Decision: Codable, Equatable, Sendable {
        var maximumM: Double
        var easyOnly: Bool
        var rest: Bool
        var reason: String
        var explanation: String
    }

    /// Describe only observed evidence. An absent HR/recovery answer is never reassurance.
    static func observations(_ e: Evidence) -> String {
        var lines: [String] = []
        if e.prescribedRuns > 0 && e.completedRuns == e.prescribedRuns {
            lines.append("You kept every planned running appointment.")
        } else if e.completedRuns > 0 {
            lines.append("You kept training in your week; unfinished sessions won't become catch-up mileage.")
        }
        if e.difficultRuns > 0 { lines.append("\(e.difficultRuns) \(e.difficultRuns == 1 ? "run felt" : "runs felt") very hard or harder than planned.") }
        if e.poorRecovery { lines.append("Recent recovery signals or check-ins suggest you need more recovery.") }
        if e.unableToContinue { lines.append("You reported being unable to continue after a workout.") }
        if let count = e.aboveEasyHeartRateRuns, count > 0 {
            lines.append("\(count) easy-effort \(count == 1 ? "run averaged" : "runs averaged") above the heart-rate target. Heart rate alone does not establish fitness or fatigue.")
        }
        if (e.prolongedHardRuns ?? 0) > 0 { lines.append("A hard-feeling run lasted substantially longer than prescribed.") }
        if e.exceededEffort { lines.append("Effort feedback together with pace, duration or heart rate supports keeping the next running dose controlled.") }
        if e.plannedM > 0 && e.actualM > e.plannedM * 1.2 { lines.append("Recorded mileage exceeded the planned amount; more mileage is not automatically a reason to progress.") }
        if e.missedWeeks > 0 { lines.append("After time away, rebuilding consistency takes priority over catching up.") }
        if e.partialWeek { lines.append("This was a partial starting week, so it does not justify an increase.") }
        return lines.joined(separator: " ")
    }

    static func focus(for phase: PlanPhase, decision: Decision) -> String {
        if decision.rest { return "This week's focus: recovery and a symptom check-in before returning to running." }
        if decision.easyOnly { return "This week's focus: manageable, easy sessions and useful recovery feedback. The goal date and planned taper stay in place." }
        switch phase {
        case .base: return "This week's focus: comfortable running and a repeatable routine."
        case .build: return "This week's focus: building endurance within the prescribed effort."
        case .peak: return "This week's focus: the goal-specific work your recent training supports, without adding extra mileage."
        case .recovery: return "This week's focus: absorbing training with a lighter planned week."
        case .taper: return "This week's focus: reducing accumulated load and arriving fresh for your goal."
        }
    }

    static func decide(_ e: Evidence, frameworkM: Double, alreadyAdapted: Bool) -> Decision {
        let framework = max(0, frameworkM.isFinite ? frameworkM : 0)
        if e.pain || e.illness {
            return Decision(maximumM: 0, easyOnly: true, rest: true, reason: "recovery_checkin",
                explanation: "Your recent check-in calls for rest. Running is paused until you check in again. If discomfort persists or worsens, seek advice from a qualified professional.")
        }
        let strained = e.poorRecovery || e.difficultRuns > 0 || e.exceededEffort || e.unableToContinue
        // Respect the existing one structural change per seven days. Safety rest can override it.
        if alreadyAdapted {
            return Decision(maximumM: framework, easyOnly: false, rest: false, reason: "recent_adjustment",
                explanation: "Your plan was adjusted recently. This week keeps that prescription so changes do not compound.")
        }
        if e.recordedRuns == 0 {
            // Manual check-offs establish attendance, not distance or physiological tolerance.
            let ceiling = e.completedRuns > 0 ? e.plannedM : e.plannedM * 0.5
            return Decision(maximumM: min(framework, ceiling), easyOnly: true, rest: false, reason: "limited_evidence",
                explanation: "There is no recorded running distance for the last week. The next week stays easy and adds no mileage; manual check-offs count as attendance, not measured training load.")
        }
        let completion = Double(e.completedRuns) / Double(max(1, e.prescribedRuns))
        let moreThanPlanned = e.plannedM > 0 && e.actualM > e.plannedM * 1.2
        let cautious = strained || completion < 0.75 || e.shortenedRuns > 0 || e.missedWeeks > 0 || moreThanPlanned
        let baseline = e.recentWeeklyM > 0 ? min(e.actualM, e.recentWeeklyM * 1.3) : e.actualM
        let cap = baseline * (cautious ? 0.85 : (e.partialWeek ? 1 : 1.05))
        return Decision(maximumM: min(framework, max(0, cap)), easyOnly: cautious, rest: false,
            reason: cautious ? "consolidate" : "supported_progression",
            explanation: cautious
                ? "Recent completion, effort or recovery supports an easier week. Missed mileage is not added back. The original recovery, taper and goal dates stay in place."
                : "Your recorded training supports the next step, capped at a small increase over recent running. The original training phase and taper remain the ceiling.")
    }

    static func week(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    /// Stable local calendar key: crossing timezones cannot mint a second version of the same week.
    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
    }

    /// Reduction-only normalization keeps every budget intact, including time and injury limits.
    /// Short recovery walking is intentionally allowed; it is never presented as a running session.
    static func normalize(_ session: inout GeneratedSession) {
        guard session.discipline == .running,
              (session.targetDistanceM ?? 0) < minimumRunM else { return }
        session.discipline = .walking
        session.runType = .recovery
        session.targetPaceSPerKm = nil
        session.intervals = nil
        session.isHardRun = false
        session.isMediumLong = false
        session.backToBack = false
        session.rationale = "Recovery walk. Today's safe running budget is below one mile; do not add distance to make up the difference."
    }
}
