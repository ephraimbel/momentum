import Foundation

struct LegacyAdversarialPlanCase: Sendable {
    var index: Int
    var seed: UInt64
    var inputs: PlanInputs
    var calibration: CalibrationSeed
}

/// Deterministic request fuzzer for the supported legacy road-running surface. A failing case can be
/// reproduced from `(seed, index)` without retaining athlete data.
enum LegacyAdversarialPlanRequestGenerator {
    static func make(seed: UInt64,
                     index: Int,
                     startDate: Date,
                     calendar: Calendar) -> LegacyAdversarialPlanCase {
        var random = SplitMix64(state: seed &+ UInt64(index) &* 0x9E3779B97F4A7C15)
        let experience: ExperienceLevel = random.pick(ExperienceLevel.allCases)
        let days = random.int(1...7)
        let usesStrength = days >= 3 && random.chance(0.34)
        let disciplines: [Discipline] = usesStrength ? [.running, .strength] : [.running]
        let raceGoal = random.chance(0.68)
        let goal: Goal = raceGoal
            ? .raceDistance
            : random.pick([.endurance, .stayConsistent, .generalFitness, .loseFat, .buildMuscle, .getStronger])

        var inputs = PlanInputs(
            disciplines: disciplines,
            goal: goal,
            daysPerWeek: days,
            equipment: random.pick(Equipment.allCases),
            sessionMinutes: random.pick([20, 30, 40, 45, 60, 75, 90, 120]),
            raceDate: nil,
            runningExperience: experience,
            liftingExperience: random.pick(ExperienceLevel.allCases)
        )

        let volumeRange: ClosedRange<Int> = switch experience {
        case .new: 5_000...25_000
        case .some: 14_000...70_000
        case .experienced: 28_000...140_000
        }
        let currentVolume = Double(random.int(volumeRange) / 500 * 500)
        inputs.currentWeeklyVolumeM = currentVolume
        inputs.longestRunM = min(currentVolume * random.double(0.20...0.48), 38_000).rounded()
        if random.chance(0.42) {
            inputs.targetWeeklyVolumeM = (currentVolume * random.double(1.05...2.25) / 500).rounded() * 500
        }

        if raceGoal {
            let raceDistance = random.pick([5_000.0, 10_000, 21_097.5, 42_195])
            inputs.raceDistanceM = raceDistance
            if random.chance(0.88) {
                let weeks = random.int(1...60)
                let raceDay = random.int(0...6)
                inputs.raceDate = calendar.date(
                    byAdding: .day,
                    value: (weeks - 1) * 7 + raceDay,
                    to: startDate
                )
            }
            if random.chance(0.57) {
                let pace = random.double(185...510)
                inputs.goalFinishTimeS = (pace * raceDistance / 1_000).rounded()
            }
        }

        var injuries: [InjuryArea] = []
        if random.chance(0.28) {
            injuries.append(random.pick(InjuryArea.allCases))
            if random.chance(0.20) {
                injuries.append(random.pick(InjuryArea.allCases))
            }
        }
        inputs.injuryHistory = Array(Set(injuries)).sorted { $0.rawValue < $1.rawValue }
        inputs.age = random.chance(0.08) ? nil : random.int(18...74)

        var intensity = random.pick(PlanIntensity.allCases)
        // Keep the qualification corpus inside the supported input domain. Separate fixtures pin
        // the legacy exception for a Podium request below its five-day contract.
        if intensity == .podium,
           days < PlanIntensity.podium.floorDays || experience == .new || !inputs.injuryHistory.isEmpty {
            intensity = .aggressive
        }
        inputs.intensity = intensity
        inputs.distanceUnit = random.pick([.metric, .imperial])
        inputs.strengthSplit = random.pick(StrengthSplitStyle.allCases)
        inputs.hybridPriority = usesStrength ? random.pick(HybridPriority.allCases) : nil
        if usesStrength, random.chance(0.45) {
            inputs.muscleFocus = Array(Set([
                random.pick(MuscleGroup.allCases),
                random.pick(MuscleGroup.allCases),
            ])).sorted { $0.rawValue < $1.rawValue }
        }
        if !raceGoal, random.chance(0.12) {
            inputs.postRaceRecoveryWeeks = random.int(1...3)
        }

        if random.chance(0.34) {
            inputs.preferredDayOffsets = random.distinctDays(count: days)
        } else if days < 7, random.chance(0.36) {
            let maximumAvoid = 7 - days
            inputs.avoidDayOffsets = random.distinctDays(count: random.int(1...maximumAvoid))
        }

        let calibration: CalibrationSeed
        switch random.int(0...3) {
        case 0:
            let distance = random.pick([3_000.0, 5_000, 10_000])
            let pace = random.double(190...620)
            calibration = CalibrationSeed(
                recentRun: (distanceM: distance, timeS: (distance / 1_000 * pace).rounded()),
                estimatedP5kSPerKm: nil,
                lifts: usesStrength && random.chance(0.5) ? ["Squat": random.double(40...180)] : [:]
            )
        case 1:
            calibration = CalibrationSeed(
                recentRun: nil,
                estimatedP5kSPerKm: random.double(210...620),
                lifts: [:]
            )
        default:
            calibration = .none
        }

        return LegacyAdversarialPlanCase(
            index: index,
            seed: seed,
            inputs: inputs,
            calibration: calibration
        )
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func chance(_ probability: Double) -> Bool {
        unitInterval() < probability
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        precondition(!range.isEmpty)
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % width)
    }

    mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unitInterval()
    }

    mutating func pick<T>(_ values: [T]) -> T {
        precondition(!values.isEmpty)
        return values[Int(next() % UInt64(values.count))]
    }

    mutating func distinctDays(count: Int) -> [Int] {
        var pool = Array(0...6)
        var result: [Int] = []
        for _ in 0..<min(7, max(0, count)) {
            result.append(pool.remove(at: Int(next() % UInt64(pool.count))))
        }
        return result.sorted()
    }

    private mutating func unitInterval() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
