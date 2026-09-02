import Foundation

/// Phone-side pure adapter from planner/persistence intent values into the shared wire contract.
/// It performs no fetch and has no WatchConnectivity dependency.
enum ExecutionPrescriptionBuilder {
    static func build(planID: String,
                      sessionID: String,
                      intent: SessionIntent?,
                      legacy: LegacyExecutionFields,
                      structuredWorkout: StructuredWorkout?) -> ExecutionPrescription {
        let target = intent.map(targetContract) ?? legacyTargetContract(legacy)
        return ExecutionPrescription(
            schemaVersion: ExecutionPrescription.currentSchemaVersion,
            planID: planID,
            sessionID: sessionID,
            intentID: intent?.id,
            intentVersion: intent?.version,
            target: target,
            legacy: legacy,
            structuredWorkout: structuredWorkout,
            purpose: intent?.purpose ?? legacyPurpose(legacy)
        )
    }

    static func build(plan: TrainingPlan,
                      session: PlannedSession,
                      intentRecord: PlannedSessionIntentRecord?,
                      structuredWorkout: StructuredWorkout?) -> ExecutionPrescription {
        let legacy = LegacyExecutionFields(
            discipline: session.discipline,
            runType: session.runType,
            targetDistanceM: session.targetDistanceM,
            targetDurationS: session.targetDurationS,
            targetPaceSPerKm: session.targetPaceSPerKm,
            intervalPrescription: session.intervals
        )
        guard let record = intentRecord,
              let primary = ExecutionTargetKind(rawValue: record.primaryTargetRaw) else {
            return build(
                planID: plan.id.uuidString.lowercased(),
                sessionID: session.id.uuidString.lowercased(),
                intent: nil,
                legacy: legacy,
                structuredWorkout: structuredWorkout
            )
        }
        let hierarchy = ExecutionTargetHierarchy(
            primary: primary,
            fallbacks: record.fallbackTargetRaws.compactMap(ExecutionTargetKind.init(rawValue:))
        )
        let target = ExecutionTargetContract(
            hierarchy: hierarchy,
            distanceM: record.workDistanceM,
            durationS: record.workDurationS,
            paceSPerKm: record.workPaceSPerKm,
            effortCue: hierarchy.primary == .effort || hierarchy.fallbacks.contains(.effort)
                ? effortCue(for: session.runType) : nil,
            intervalPrescription: record.intervalPrescription,
            recoveryDistanceM: record.recoveryDistanceM,
            recoveryDurationS: record.recoveryDurationS,
            recoveryMode: record.recoveryModeRaw.flatMap(ExecutionTargetKind.init(rawValue:)),
            successRange: Self.range(record.successLower, record.successUpper)
        )
        return ExecutionPrescription(
            schemaVersion: ExecutionPrescription.currentSchemaVersion,
            planID: plan.id.uuidString.lowercased(),
            sessionID: session.id.uuidString.lowercased(),
            intentID: record.id,
            intentVersion: record.intentVersion,
            target: target,
            legacy: legacy,
            structuredWorkout: structuredWorkout,
            purpose: record.purpose.isEmpty ? legacyPurpose(legacy) : record.purpose
        )
    }
}

private extension ExecutionPrescriptionBuilder {
    static func targetContract(_ intent: SessionIntent) -> ExecutionTargetContract {
        let primary = ExecutionTargetKind(rawValue: intent.targetHierarchy.primary.rawValue) ?? .completion
        let hierarchy = ExecutionTargetHierarchy(
            primary: primary,
            fallbacks: intent.targetHierarchy.fallbacks.compactMap {
                ExecutionTargetKind(rawValue: $0.rawValue)
            }
        )
        return ExecutionTargetContract(
            hierarchy: hierarchy,
            distanceM: intent.workDose.distanceM,
            durationS: intent.workDose.durationS,
            paceSPerKm: intent.workDose.paceSPerKm,
            effortCue: hierarchy.primary == .effort || hierarchy.fallbacks.contains(.effort)
                ? effortCue(for: intent.legacyRunType) : nil,
            intervalPrescription: intent.workDose.intervalPrescription,
            recoveryDistanceM: intent.recoveryDose?.distanceM,
            recoveryDurationS: intent.recoveryDose?.durationS,
            recoveryMode: intent.recoveryDose?.mode.flatMap { ExecutionTargetKind(rawValue: $0.rawValue) },
            successRange: intent.successRange.map { ExecutionValueRange(lower: $0.lower, upper: $0.upper) }
        )
    }

    static func legacyTargetContract(_ legacy: LegacyExecutionFields) -> ExecutionTargetContract {
        let hierarchy: ExecutionTargetHierarchy
        if legacy.discipline == .strength {
            hierarchy = ExecutionTargetHierarchy(primary: .strengthPrescription)
        } else if legacy.intervalPrescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            hierarchy = ExecutionTargetHierarchy(primary: .intervalStructure, fallbacks: [.effort])
        } else if legacy.targetDistanceM != nil {
            var fallbacks: [ExecutionTargetKind] = []
            if legacy.targetDurationS != nil { fallbacks.append(.duration) }
            if legacy.targetPaceSPerKm != nil { fallbacks.append(.pace) }
            fallbacks.append(.effort)
            hierarchy = ExecutionTargetHierarchy(primary: .distance, fallbacks: fallbacks)
        } else if legacy.targetDurationS != nil {
            hierarchy = ExecutionTargetHierarchy(primary: .duration, fallbacks: [.effort])
        } else {
            hierarchy = ExecutionTargetHierarchy(primary: .completion, fallbacks: [.effort])
        }
        return ExecutionTargetContract(
            hierarchy: hierarchy,
            distanceM: legacy.targetDistanceM,
            durationS: legacy.targetDurationS,
            paceSPerKm: legacy.targetPaceSPerKm,
            effortCue: hierarchy.primary == .effort || hierarchy.fallbacks.contains(.effort)
                ? effortCue(for: legacy.runType) : nil,
            intervalPrescription: legacy.intervalPrescription,
            recoveryDistanceM: nil,
            recoveryDurationS: nil,
            recoveryMode: nil,
            successRange: nil
        )
    }

    static func range(_ lower: Double?, _ upper: Double?) -> ExecutionValueRange? {
        guard let lower, let upper else { return nil }
        return ExecutionValueRange(lower: lower, upper: upper)
    }

    static func effortCue(for runType: RunType?) -> String {
        switch runType {
        case .recovery: "Very easy; finish feeling better than you started."
        case .easy, .long, .freeRun, .strides, nil: "Conversational effort; slow down whenever the talk test says to."
        case .tempo: "Controlled and comfortably hard; never an all-out test."
        case .intervals, .fartlek: "Finish the repetitions with form and control intact."
        case .hills: "Run by effort and grade, not flat-ground pace."
        case .progression: "Begin conversational and finish controlled."
        case .race: "Use the race-day plan and current conditions."
        }
    }

    static func legacyPurpose(_ legacy: LegacyExecutionFields) -> String {
        guard legacy.discipline == .running else {
            return legacy.discipline == .strength
                ? "Support running with a recovery-spaced strength session."
                : "Complete the planned endurance session."
        }
        return switch legacy.runType {
        case .recovery: "Recover through gentle movement."
        case .long: "Build durable aerobic endurance."
        case .tempo: "Accumulate controlled threshold-oriented work."
        case .intervals: "Accumulate bounded faster running with recovery."
        case .hills: "Build running-specific force by effort."
        case .strides: "Practice short, relaxed speed."
        case .progression: "Practice finishing with control."
        case .race: "Execute the named event."
        case .fartlek: "Add controlled speed play to an easy run."
        case .easy, .freeRun, nil: "Build repeatable aerobic running."
        }
    }
}
