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

    enum Step: Int, CaseIterable { case coldOpen, disciplines, goal, experience, days, equipment, session, why, calibration, commitment, building, reveal, primers }

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

    /// Personalized status lines for the "building your plan" beat — each reflects an answer back so
    /// the analysis feels bespoke (research: the loader should mirror the user's own inputs).
    func buildingLines() -> [String] {
        var lines = ["Balancing your \(daysPerWeek)-day week"]
        if disciplines.contains(.running) && disciplines.contains(.strength) {
            lines.append("Spacing your runs and lifts")
        } else if disciplines.contains(.strength) {
            lines.append("Sequencing your strength work")
        } else if disciplines.contains(.running) {
            lines.append("Building your running base")
        } else {
            lines.append("Spacing your efforts")
        }
        switch goal {
        case .buildMuscle:   lines.append("Tuning volume for muscle")
        case .getStronger:   lines.append("Loading for strength")
        case .loseFat:       lines.append("Shaping it for fat loss")
        case .raceDistance:  lines.append("Pointing it at your distance")
        case .endurance:     lines.append("Stretching your endurance")
        default:             lines.append("Making it easy to keep")
        }
        lines.append(disciplines.contains(.strength) && !disciplines.contains(.running)
                     ? "Setting your starting loads" : "Setting your starting paces")
        lines.append("Finalizing your plan")
        return lines
    }

    /// Short "tuned to you" reflections shown on the reveal — the inputs the plan was built around.
    func reflections() -> [String] {
        var chips = ["\(daysPerWeek) days / week"]
        chips.append(goalLabel)
        if disciplines.contains(.strength) { chips.append(equipmentLabel) }
        chips.append("\(sessionMinutes) min")
        return chips
    }

    private var goalLabel: String {
        switch goal {
        case .loseFat: "Fat loss"; case .buildMuscle: "Build muscle"; case .getStronger: "Get stronger"
        case .raceDistance: "Race ready"; case .endurance: "Endurance"; default: "Consistency"
        }
    }

    private var equipmentLabel: String {
        switch equipment {
        case .fullGym: "Full gym"; case .dumbbellsOnly: "Dumbbells"; case .homeMinimal: "Home"; case .bodyweight: "Bodyweight"
        }
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
        // Seed the Athlete Model so the AI isn't starting from a blank slate (ATHLETE-MODEL.md §5).
        AthleteModelService().seedOnboarding(for: profile, in: context)
        return profile
    }
}
