import Foundation

enum LegacyPlanReplayError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case unsupportedPlanner(String)
    case invalidEnum(field: String, value: String)
    case invalidTimeZone(String)
    case invalidCalendarIdentifier(String)
    case invalidCalendarValue(field: String, value: Int)
    case duplicateLift(String)

    var description: String {
        switch self {
        case .unsupportedSchema(let version): "Unsupported replay schema \(version)."
        case .unsupportedPlanner(let version): "Unsupported planner version \(version)."
        case .invalidEnum(let field, let value): "Invalid \(field) value \(value)."
        case .invalidTimeZone(let value): "Invalid replay time zone \(value)."
        case .invalidCalendarIdentifier(let value): "Invalid replay calendar identifier \(value)."
        case .invalidCalendarValue(let field, let value): "Invalid replay \(field) value \(value)."
        case .duplicateLift(let value): "Duplicate lift calibration for \(value)."
        }
    }
}

/// Compact, local replay envelope for the exact aggregates consumed by the legacy planner. It
/// contains no athlete identity, route, raw Health sample, free-form medical note or workout history.
struct LegacyPlanReplay: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentPlannerVersion = "legacy-plan-engine-v1"

    var schemaVersion: Int
    var plannerVersion: String
    var startReferenceSeconds: Double
    var calendar: CalendarConfiguration
    var request: Request
    var calibration: Calibration
    var catalog: [CatalogItem]
    var expectedDigest: PlanSemanticDigest?

    init(inputs: PlanInputs,
         catalog: [ExerciseCatalogItem],
         calibration: CalibrationSeed = .none,
         startDate: Date,
         calendar: Calendar,
         expectedDigest: PlanSemanticDigest? = nil) {
        schemaVersion = Self.currentSchemaVersion
        plannerVersion = Self.currentPlannerVersion
        startReferenceSeconds = startDate.timeIntervalSinceReferenceDate
        self.calendar = CalendarConfiguration(calendar)
        request = Request(inputs)
        self.calibration = Calibration(calibration)
        // Catalog order is semantic input: the legacy selector uses stable first-match tie breaks.
        self.catalog = catalog.map(CatalogItem.init)
        self.expectedDigest = expectedDigest
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func replayInputs() throws -> PlanInputs {
        try validateHeader()
        return try request.inputs()
    }

    func replayCalendar() throws -> Calendar {
        try validateHeader()
        return try calendar.value()
    }

    func replayCalibration() throws -> CalibrationSeed {
        try validateHeader()
        return try calibration.value()
    }

    func replayCatalog() throws -> [ExerciseCatalogItem] {
        try validateHeader()
        return try catalog.map { try $0.value() }
    }

    func generate() throws -> GeneratedPlan {
        let replayCalendar = try replayCalendar()
        return PlanEngine.generate(
            profile: try replayInputs(),
            catalog: try replayCatalog(),
            calibration: try replayCalibration(),
            startDate: Date(timeIntervalSinceReferenceDate: startReferenceSeconds),
            calendar: replayCalendar
        )
    }

    private func validateHeader() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LegacyPlanReplayError.unsupportedSchema(schemaVersion)
        }
        guard plannerVersion == Self.currentPlannerVersion else {
            throw LegacyPlanReplayError.unsupportedPlanner(plannerVersion)
        }
    }

    struct CalendarConfiguration: Codable, Equatable, Sendable {
        var identifier: String
        var localeIdentifier: String?
        var timeZoneIdentifier: String
        var firstWeekday: Int
        var minimumDaysInFirstWeek: Int

        init(_ calendar: Calendar) {
            identifier = Self.name(calendar.identifier)
            localeIdentifier = calendar.locale?.identifier
            timeZoneIdentifier = calendar.timeZone.identifier
            firstWeekday = calendar.firstWeekday
            minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        }

        func value() throws -> Calendar {
            guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
                throw LegacyPlanReplayError.invalidTimeZone(timeZoneIdentifier)
            }
            guard (1...7).contains(firstWeekday) else {
                throw LegacyPlanReplayError.invalidCalendarValue(
                    field: "firstWeekday",
                    value: firstWeekday
                )
            }
            guard (1...7).contains(minimumDaysInFirstWeek) else {
                throw LegacyPlanReplayError.invalidCalendarValue(
                    field: "minimumDaysInFirstWeek",
                    value: minimumDaysInFirstWeek
                )
            }
            var value = Calendar(identifier: try Self.calendarIdentifier(identifier))
            value.locale = localeIdentifier.map(Locale.init(identifier:))
            value.timeZone = timeZone
            value.firstWeekday = firstWeekday
            value.minimumDaysInFirstWeek = minimumDaysInFirstWeek
            return value
        }

        private static func name(_ identifier: Calendar.Identifier) -> String {
            String(describing: identifier)
        }

        private static func calendarIdentifier(_ value: String) throws -> Calendar.Identifier {
            switch value {
            case "gregorian": .gregorian
            case "buddhist": .buddhist
            case "chinese": .chinese
            case "coptic": .coptic
            case "ethiopic": .ethiopicAmeteMihret
            case "ethioaa": .ethiopicAmeteAlem
            case "hebrew": .hebrew
            case "iso8601": .iso8601
            case "indian": .indian
            case "islamic": .islamic
            case "islamic-civil": .islamicCivil
            case "japanese": .japanese
            case "persian": .persian
            case "roc": .republicOfChina
            case "islamic-tbla": .islamicTabular
            case "islamic-umalqura": .islamicUmmAlQura
            default: throw LegacyPlanReplayError.invalidCalendarIdentifier(value)
            }
        }
    }

    struct Request: Codable, Equatable, Sendable {
        var disciplines: [String]
        var goal: String
        var daysPerWeek: Int
        var equipment: String
        var sessionMinutes: Int
        var raceReferenceSeconds: Double?
        var runningExperience: String
        var liftingExperience: String
        var raceDistanceM: Double?
        var currentWeeklyVolumeM: Double?
        var longestRunM: Double?
        var goalFinishTimeS: Double?
        var targetWeeklyVolumeM: Double?
        var hybridPriority: String?
        var strengthSplit: String
        var muscleFocus: [String]
        var preferredDayOffsets: [Int]
        var avoidDayOffsets: [Int]
        var intensity: String
        var injuryHistory: [String]
        var age: Int?
        var postRaceRecoveryWeeks: Int
        var distanceUnit: String

        init(_ inputs: PlanInputs) {
            disciplines = Set(inputs.disciplines.map(\.rawValue)).sorted()
            goal = inputs.goal.rawValue
            daysPerWeek = inputs.daysPerWeek
            equipment = inputs.equipment.rawValue
            sessionMinutes = inputs.sessionMinutes
            raceReferenceSeconds = inputs.raceDate?.timeIntervalSinceReferenceDate
            runningExperience = inputs.runningExperience.rawValue
            liftingExperience = inputs.liftingExperience.rawValue
            raceDistanceM = inputs.raceDistanceM
            currentWeeklyVolumeM = inputs.currentWeeklyVolumeM
            longestRunM = inputs.longestRunM
            goalFinishTimeS = inputs.goalFinishTimeS
            targetWeeklyVolumeM = inputs.targetWeeklyVolumeM
            hybridPriority = inputs.hybridPriority?.rawValue
            strengthSplit = inputs.strengthSplit.rawValue
            muscleFocus = Set(inputs.muscleFocus.map(\.rawValue)).sorted()
            preferredDayOffsets = Array(Set(inputs.preferredDayOffsets)).sorted()
            avoidDayOffsets = Array(Set(inputs.avoidDayOffsets)).sorted()
            intensity = inputs.intensity.rawValue
            injuryHistory = Set(inputs.injuryHistory.map(\.rawValue)).sorted()
            age = inputs.age
            postRaceRecoveryWeeks = inputs.postRaceRecoveryWeeks
            distanceUnit = inputs.distanceUnit.rawValue
        }

        func inputs() throws -> PlanInputs {
            let disciplines: [Discipline] = try disciplines.map {
                try decodeEnum($0, field: "discipline")
            }
            var result = PlanInputs(
                disciplines: disciplines,
                goal: try decodeEnum(goal, field: "goal"),
                daysPerWeek: daysPerWeek,
                equipment: try decodeEnum(equipment, field: "equipment"),
                sessionMinutes: sessionMinutes,
                raceDate: raceReferenceSeconds.map { Date(timeIntervalSinceReferenceDate: $0) },
                runningExperience: try decodeEnum(runningExperience, field: "runningExperience"),
                liftingExperience: try decodeEnum(liftingExperience, field: "liftingExperience")
            )
            result.raceDistanceM = raceDistanceM
            result.currentWeeklyVolumeM = currentWeeklyVolumeM
            result.longestRunM = longestRunM
            result.goalFinishTimeS = goalFinishTimeS
            result.targetWeeklyVolumeM = targetWeeklyVolumeM
            if let hybridPriority {
                result.hybridPriority = try decodeEnum(hybridPriority, field: "hybridPriority")
            }
            result.strengthSplit = try decodeEnum(strengthSplit, field: "strengthSplit")
            result.muscleFocus = try muscleFocus.map {
                try decodeEnum($0, field: "muscleFocus")
            }
            result.preferredDayOffsets = preferredDayOffsets
            result.avoidDayOffsets = avoidDayOffsets
            result.intensity = try decodeEnum(intensity, field: "intensity")
            result.injuryHistory = try injuryHistory.map {
                try decodeEnum($0, field: "injuryHistory")
            }
            result.age = age
            result.postRaceRecoveryWeeks = postRaceRecoveryWeeks
            result.distanceUnit = try decodeEnum(distanceUnit, field: "distanceUnit")
            return result
        }
    }

    struct Calibration: Codable, Equatable, Sendable {
        struct RecentRun: Codable, Equatable, Sendable {
            var distanceM: Double
            var timeS: Double
        }

        struct Lift: Codable, Equatable, Sendable {
            var name: String
            var e1RMKg: Double
        }

        var recentRun: RecentRun?
        var estimatedP5kSPerKm: Double?
        var lifts: [Lift]

        init(_ seed: CalibrationSeed) {
            recentRun = seed.recentRun.map { RecentRun(distanceM: $0.distanceM, timeS: $0.timeS) }
            estimatedP5kSPerKm = seed.estimatedP5kSPerKm
            lifts = seed.lifts.map { Lift(name: $0.key, e1RMKg: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        func value() throws -> CalibrationSeed {
            var liftMap: [String: Double] = [:]
            for lift in lifts {
                guard liftMap[lift.name] == nil else {
                    throw LegacyPlanReplayError.duplicateLift(lift.name)
                }
                liftMap[lift.name] = lift.e1RMKg
            }
            return CalibrationSeed(
                recentRun: recentRun.map { (distanceM: $0.distanceM, timeS: $0.timeS) },
                estimatedP5kSPerKm: estimatedP5kSPerKm,
                lifts: liftMap
            )
        }
    }

    struct CatalogItem: Codable, Equatable, Sendable {
        var name: String
        var primaryMuscles: [String]
        var secondaryMuscles: [String]
        var equipment: String
        var category: String
        var defaultRestS: Double
        var trackingMode: String

        init(_ item: ExerciseCatalogItem) {
            name = item.name
            primaryMuscles = item.primaryMuscles.map(\.rawValue).sorted()
            secondaryMuscles = item.secondaryMuscles.map(\.rawValue).sorted()
            equipment = item.equipment.rawValue
            category = item.category.rawValue
            defaultRestS = item.defaultRestS
            trackingMode = item.trackingMode.rawValue
        }

        func value() throws -> ExerciseCatalogItem {
            ExerciseCatalogItem(
                name: name,
                primaryMuscles: try primaryMuscles.map {
                    try decodeEnum($0, field: "catalog.primaryMuscles")
                },
                secondaryMuscles: try secondaryMuscles.map {
                    try decodeEnum($0, field: "catalog.secondaryMuscles")
                },
                equipment: try decodeEnum(equipment, field: "catalog.equipment"),
                category: try decodeEnum(category, field: "catalog.category"),
                defaultRestS: defaultRestS,
                trackingMode: try decodeEnum(trackingMode, field: "catalog.trackingMode")
            )
        }
    }
}

private func decodeEnum<T>(_ rawValue: String, field: String) throws -> T
where T: RawRepresentable, T.RawValue == String {
    guard let value = T(rawValue: rawValue) else {
        throw LegacyPlanReplayError.invalidEnum(field: field, value: rawValue)
    }
    return value
}
