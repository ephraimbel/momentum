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
    var experience: ExperienceLevel = .some          // running / general
    var liftExperience: ExperienceLevel = .some      // used when hybrid (run + lift)
    var daysPerWeek: Int = 3
    var equipment: Equipment = .fullGym
    var sessionMinutes: Int = 45
    var hasRace = false
    var raceDate: Date = Calendar.current.date(byAdding: .weekOfYear, value: 8, to: Date()) ?? Date()
    var reason: String = "health"

    // Deeper tailoring (PRD §26 — goal-branched)
    var raceDistance: RaceDistance? = nil           // for "run a race"
    var muscleFocus: Set<MuscleGroup> = []          // for "build muscle" — areas to emphasize
    var preferredDays: Set<Int> = []                // Calendar weekday 1…7; empty → auto-spread
    var sex: BiologicalSex? = nil
    var heightCm: Double? = nil
    var birthYear: Int? = nil
    var bodyMassKg: Double? = nil

    // Optional calibration
    var addRecentRun = false
    var recentRunMeters: Double = 5000
    var recentRunSeconds: Double = 1500

    /// A balanced full-body activation for the anatomy animation, emphasized by the chosen focus.
    func targetMuscles() -> [MuscleGroup: Double] {
        let balanced: [MuscleGroup: Double] = [
            .chest: 0.85, .back: 0.85, .shoulders: 0.6, .biceps: 0.5, .triceps: 0.5,
            .quads: 0.9, .hamstrings: 0.7, .glutes: 0.75, .calves: 0.4, .core: 0.6]
        guard !muscleFocus.isEmpty else { return balanced }
        var m = balanced.mapValues { _ in 0.35 }
        for f in muscleFocus { m[f] = 1.0 }
        return m
    }
    /// Whether this athlete's plan includes lifting (drives the anatomy beats vs. the route beat).
    var includesStrength: Bool { disciplines.contains(.strength) }

    var step: Step = .coldOpen

    /// Goal-first, branching order — each user only sees the steps relevant to their goal/disciplines.
    enum Step: Int, CaseIterable {
        case coldOpen, goal, disciplines, race, muscleFocus, experience, days, preferredDays,
             session, equipment, metrics, why, calibration, commitment, building, reveal, primers
    }

    var lifting: Bool { disciplines.contains(.strength) }
    var running: Bool { disciplines.contains(.running) }
    var hybrid: Bool { running && lifting }

    /// The ordered steps for this user — branches on goal + disciplines.
    var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .race:        return goal == .raceDistance && running
            case .muscleFocus: return goal == .buildMuscle && lifting
            case .equipment:   return lifting
            case .calibration: return running
            default:           return true
            }
        }
    }

    /// The answerable steps (drives the progress bar + the question chrome).
    private var questionSteps: [Step] {
        steps.filter { ![.coldOpen, .commitment, .building, .reveal, .primers].contains($0) }
    }
    var isQuestionStep: Bool { questionSteps.contains(step) }

    var progress: Double {
        guard let qIdx = questionSteps.firstIndex(of: step) else {
            return step.rawValue < Step.commitment.rawValue ? 0 : 1
        }
        return Double(qIdx + 1) / Double(max(1, questionSteps.count))
    }

    var canAdvance: Bool {
        switch step {
        case .disciplines: return !disciplines.isEmpty
        case .race: return raceDistance != nil
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

    /// When the goal is chosen, pre-select sensible disciplines (only if the user hasn't picked yet),
    /// so racers default to running, lifters to strength, and general goals to a hybrid mix.
    func applyGoalDefaults() {
        guard disciplines.isEmpty else { return }
        switch goal {
        case .raceDistance, .endurance: disciplines = [.running]
        case .buildMuscle, .getStronger: disciplines = [.strength]
        case .loseFat, .generalFitness, .stayConsistent: disciplines = [.running, .strength]
        }
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
        if goal == .raceDistance, let r = raceDistance { chips.append(r.label) } else { chips.append(goalLabel) }
        if !muscleFocus.isEmpty { chips.append("Focus: \(muscleFocus.count) area\(muscleFocus.count == 1 ? "" : "s")") }
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
        // Race goals lead with the race itself — the clearest promise.
        if goal == .raceDistance, let r = raceDistance {
            if hasRace { return "\(r.label)-ready by \(raceDate.formatted(.dateTime.month().day()))" }
            return "Built for your \(r.label) — whenever you toe the line"
        }
        var bits: [String] = []
        if disciplines.contains(.strength) { bits.append(goal == .getStronger ? "Stronger" : "Leaner & stronger") }
        if disciplines.contains(.running) { bits.append(hasRace ? "race-ready" : "fitter") }
        if bits.isEmpty { bits.append("Fitter") }
        let phrase = bits.joined(separator: " + ")
        if hasRace { return "\(phrase) by \(raceDate.formatted(.dateTime.month().day()))" }
        return "\(phrase) — one week at a time"
    }

    /// Whole weeks until race day (for the reveal countdown), if a dated race was set.
    var weeksToRace: Int? {
        guard goal == .raceDistance, hasRace else { return nil }
        let w = Calendar.current.dateComponents([.weekOfYear], from: Date(), to: raceDate).weekOfYear ?? 0
        return max(0, w)
    }

    /// Create the profile + plan. Returns the persisted profile.
    @discardableResult
    func finish(in context: ModelContext) -> UserProfile {
        let profile = UserProfile()
        let chosen = disciplines.isEmpty ? [Discipline.running] : Array(disciplines)
        profile.disciplines = chosen.map(\.rawValue)
        profile.goal = goal
        // Per-discipline experience: lifting uses its own level when hybrid; everything else the general one.
        profile.experience = Dictionary(uniqueKeysWithValues: chosen.map {
            ($0.rawValue, ($0 == .strength ? liftExperience : experience).rawValue)
        })
        profile.daysPerWeek = daysPerWeek
        profile.equipment = equipment
        profile.sessionMinutes = sessionMinutes
        profile.raceDate = hasRace ? raceDate : nil
        profile.raceDistanceM = (goal == .raceDistance) ? raceDistance?.meters : nil
        profile.muscleFocus = muscleFocus.map(\.rawValue)
        profile.preferredDays = Array(preferredDays).sorted()
        // Default display units to the athlete's locale (lb + miles in the US/UK) so the whole app
        // matches the imperial figures they just entered. Distance stays `auto` (locale-resolved).
        profile.weightUnit = WeightUnit.default().rawValue
        profile.sex = sex?.rawValue
        profile.heightCm = heightCm
        profile.birthYear = birthYear
        if let bodyMassKg { profile.bodyMassKg = bodyMassKg }
        // Estimate max HR from age (Tanaka) when we have it and nothing better.
        if profile.maxHR == nil, let year = birthYear {
            let age = Calendar.current.component(.year, from: Date()) - year
            if age > 0 { profile.maxHR = Int((208 - 0.7 * Double(age)).rounded()) }
        }
        profile.reason = reason
        context.insert(profile)
        PlanService.regenerate(for: profile, calibration: calibration, in: context)
        // Seed the Athlete Model so the AI isn't starting from a blank slate (ATHLETE-MODEL.md §5).
        AthleteModelService().seedOnboarding(for: profile, in: context)
        return profile
    }
}
