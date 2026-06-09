import Foundation
import SwiftData
import Observation

/// Holds onboarding answers and turns them into a `UserProfile` + generated plan (PRD §4.1, §26).
@MainActor
@Observable
final class OnboardingViewModel {
    // Answers
    var disciplines: Set<Discipline> = []
    var goal: Goal = .generalFitness
    var experience: ExperienceLevel = .some
    var daysPerWeek: Int = 3
    var equipment: Equipment = .fullGym
    var sessionMinutes: Int = 45
    var hasRace = false
    var raceDate: Date = Calendar.current.date(byAdding: .weekOfYear, value: 8, to: Date()) ?? Date()
    var reason: String = "health"

    // Optional calibration
    var addRecentRun = false
    var recentRunMeters: Double = 5000
    var recentRunSeconds: Double = 1500

    var step: Step = .coldOpen

    enum Step: Int, CaseIterable { case coldOpen, disciplines, goal, experience, days, equipment, session, why, calibration, building, reveal, primers }

    var lifting: Bool { disciplines.contains(.strength) }

    /// The ordered steps for this user (equipment only if lifting).
    var steps: [Step] {
        Step.allCases.filter { $0 != .equipment || lifting }
    }

    var progress: Double {
        guard let idx = steps.firstIndex(of: step) else { return 0 }
        // Exclude cold open + the building/reveal/primers tail from the question progress bar.
        let questionSteps = steps.filter { (Step.disciplines.rawValue...Step.calibration.rawValue).contains($0.rawValue) }
        guard let qIdx = questionSteps.firstIndex(of: step) else { return idx <= Step.calibration.rawValue ? 0 : 1 }
        return Double(qIdx + 1) / Double(questionSteps.count)
    }

    var canAdvance: Bool {
        switch step {
        case .disciplines: return !disciplines.isEmpty
        default: return true
        }
    }

    func advance() {
        guard let idx = steps.firstIndex(of: step), idx + 1 < steps.count else { return }
        step = steps[idx + 1]
    }

    func back() {
        guard let idx = steps.firstIndex(of: step), idx > 0 else { return }
        step = steps[idx - 1]
    }

    var calibration: CalibrationSeed {
        var seed = CalibrationSeed()
        if addRecentRun { seed.recentRun = (recentRunMeters, recentRunSeconds) }
        return seed
    }

    /// Projected outcome copy for the reveal (PRD §4.1).
    func projectedOutcome() -> String {
        var bits: [String] = []
        if disciplines.contains(.strength) { bits.append(goal == .getStronger ? "Stronger" : "Leaner & stronger") }
        if disciplines.contains(.running) { bits.append(hasRace ? "race-ready" : "fitter") }
        if bits.isEmpty { bits.append("Fitter") }
        let phrase = bits.joined(separator: " + ")
        if hasRace {
            return "\(phrase) by \(raceDate.formatted(.dateTime.month().day()))"
        }
        return "\(phrase) — one week at a time"
    }

    /// Create the profile + plan. Returns the persisted profile.
    @discardableResult
    func finish(in context: ModelContext) -> UserProfile {
        let profile = UserProfile()
        let chosen = disciplines.isEmpty ? [Discipline.running] : Array(disciplines)
        profile.disciplines = chosen.map(\.rawValue)
        profile.goal = goal
        profile.experience = Dictionary(uniqueKeysWithValues: chosen.map { ($0.rawValue, experience.rawValue) })
        profile.daysPerWeek = daysPerWeek
        profile.equipment = equipment
        profile.sessionMinutes = sessionMinutes
        profile.raceDate = hasRace ? raceDate : nil
        profile.reason = reason
        context.insert(profile)
        PlanService.regenerate(for: profile, calibration: calibration, in: context)
        return profile
    }
}
