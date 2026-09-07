import Foundation

/// Everything the wrist shows about the athlete's health — readiness, last night's sleep, HRV,
/// resting heart rate, today's strain and the week's training — built ONCE on the phone from the
/// same engines every phone surface reads (`ReadinessToday` · `SleepReport` · `HealthBaselines` ·
/// `DayStrain` · `PlanWeekLedger`) and carried to the watch as one Codable value (2026-09-06).
///
/// One recipe, one number: the watch never recomputes a score the phone already computed, so the
/// ring on the wrist and the ring in Progress → Health can never disagree (the 91-vs-75 lesson of
/// 2026-07-22). The struct is pure Swift + Foundation so the watch app AND the complications
/// extension compile it without any other shared file. Fields are plain strings and numbers, never
/// app enums, so an older watch build decodes a newer phone's payload (unknown keys are ignored)
/// and a version bump is the only breaking change.
struct WristHealthSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = WristHealthSnapshot.currentVersion
    /// Local `yyyy-MM-dd` of the morning this snapshot describes.
    var dayKey: String
    var generatedAt: Date
    /// False until Apple Health is connected on the phone — the wrist then says how, instead of
    /// showing empty rings.
    var healthConnected: Bool

    var readiness: Readiness?
    var sleep: Sleep?
    var hrv: Vital?
    var restingHR: Vital?
    /// Overnight respiratory rate as a z-score against the athlete's own norm; nil until a norm exists.
    var respiratoryZ: Double?
    /// Overnight wrist temperature, °C above the athlete's own norm; nil until a norm exists.
    var wristTempDeltaC: Double?
    var strain: Strain?
    var training: Training?

    struct Readiness: Codable, Equatable, Sendable {
        var score: Int
        /// `primed` · `ready` · `moderate` · `strained` · `depleted` — the stable key, never the word.
        var band: String
        /// The word under the ring ("Primed" …).
        var word: String
        /// One line: the biggest mover and, when it matters, how much data stands behind the number.
        var driver: String
        /// The coach's sentence for the band.
        var guidance: String
        /// `high` · `medium` · `low` · `minimal`.
        var confidence: String
        var pillars: [Pillar]
        var modifiers: [Modifier]
    }

    /// One input to the readiness blend, with the points it moved the score by.
    struct Pillar: Codable, Equatable, Sendable, Identifiable {
        var id: String { kind }
        /// `load` · `hrv` · `sleep` · `restingHR` · `checkin`.
        var kind: String
        var title: String
        /// The value in the athlete's words: "48 ms · norm 52", "7h 12m of 7h 30m".
        var detail: String
        var points: Double
    }

    /// An overnight signal that only ever subtracts (respiratory rate, wrist temperature).
    struct Modifier: Codable, Equatable, Sendable, Identifiable {
        var id: String { kind }
        var kind: String
        var title: String
        var detail: String
        var points: Double
    }

    struct Sleep: Codable, Equatable, Sendable {
        var asleepH: Double
        var needH: Double
        var debt14H: Double
        var efficiencyPct: Double?
        var deepPct: Double?
        var remPct: Double?
        /// `Good` · `Fair` · `Low` — last night against the athlete's own need.
        var band: String
        /// The wake-up morning this night belongs to; the wrist labels an older night honestly.
        var nightDayKey: String
        var note: String?
        /// Seven nights, oldest first, hours asleep; nil where no night was recorded.
        var week: [Double?]
    }

    /// A single overnight vital against the athlete's own norm.
    struct Vital: Codable, Equatable, Sendable {
        var value: Double
        var baseline: Double?
        /// `up` · `steady` · `down` relative to the norm; nil until a norm exists.
        var trend: String?
        var note: String?
        /// Seven days, oldest first, today last; nil where nothing was recorded.
        var week: [Double?]
    }

    struct Strain: Codable, Equatable, Sendable {
        /// 0–100 so far today.
        var score: Int
        /// `Light` · `Moderate` · `Hard` · `Peak`.
        var band: String
        var workoutLoad: Double
        var ambientLoad: Double
        /// Seven days, oldest first, today last.
        var week: [Int?]
    }

    struct Training: Codable, Equatable, Sendable {
        var weekDoneM: Double
        var weekPlannedM: Double
        var doneSessions: Int
        var totalSessions: Int
        var streakDays: Int
        /// The acute:chronic load word ("Steady", "Building" …) and its one-line reading.
        var loadWord: String?
        var loadLine: String?
    }

    // MARK: Wire format

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(self)
    }

    /// Decodes a payload, refusing one from a future major version rather than showing it wrong.
    static func decode(_ data: Data) -> WristHealthSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WristHealthSnapshot.self, from: data),
              snapshot.version <= currentVersion else { return nil }
        return snapshot
    }

    // MARK: Reading

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// True when the snapshot describes today.
    func isForToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        dayKey == Self.dayKey(now, calendar: calendar)
    }

    /// True when it is worth asking the phone for a fresher one: not today's, or older than
    /// `maxAge` — the phone re-reads Health throughout the day, so a morning number can move.
    func isStale(now: Date = Date(), maxAge: TimeInterval = 3 * 3600, calendar: Calendar = .current) -> Bool {
        !isForToday(now: now, calendar: calendar) || now.timeIntervalSince(generatedAt) > maxAge
    }

    var hasVitals: Bool { sleep != nil || hrv != nil || restingHR != nil }

    /// The empty-state copy for a wrist with nothing to show — one sentence, honest about why.
    var emptyLine: String? {
        if !healthConnected { return "Connect Apple Health in momentum on iPhone to see readiness, sleep and HRV here." }
        if readiness == nil && !hasVitals { return "Your first night with Apple Health connected builds the picture." }
        return nil
    }
}
