import Foundation

/// Turns a spoken or typed sentence — "ran 5 easy miles this morning", "45 min upper body,
/// bench 4x8 at 185" — into the structured fields of a loggable workout (ENDURANCE-FOCUS: the
/// offline-log composer on Today). Deterministic and rules-based like every engine: no model
/// call, no network, instant on every keystroke, so the receipt can render live while the
/// athlete is still talking. Dictation is input-only sugar (`VoiceTranscriber`) — by the time
/// text reaches here, spoken and typed logs are identical.
///
/// Grammar, not NLP: word-boundary keyword tables for sport/effort/when, unit-anchored number
/// patterns for duration/distance, and clause-split set patterns ("bench 4x8 at 185",
/// "3 sets of 12 curls") for strength. Anything it can't read it leaves nil — the receipt shows
/// the gap and the full manual form is one tap away. It must never guess a number the athlete
/// didn't say.
enum WorkoutLogParser {

    struct ParsedExercise: Equatable {
        var name: String
        var sets: Int
        var reps: Int
        var weightKg: Double?
    }

    enum TimeHint: Equatable { case morning, afternoon, evening }

    struct Result: Equatable {
        var type: WorkoutType?
        var indoor = false
        var durationS: Double?
        var distanceM: Double?
        var effort: Int?               // 1–10 RPE, LogWorkoutView's scale
        var dayOffset = 0              // 0 today, -1 yesterday
        var timeHint: TimeHint?
        var exercises: [ParsedExercise] = []

        /// Nothing recognized yet — the receipt stays hidden and the examples line shows instead.
        var isEmpty: Bool { type == nil && durationS == nil && distanceM == nil && exercises.isEmpty }
    }

    // MARK: Parse

    static func parse(_ raw: String, weightUnit: WeightUnit = .kg) -> Result {
        var r = Result()
        let text = raw.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return r }

        parseWhen(text, into: &r)
        parseSport(text, into: &r)
        parseDuration(text, into: &r)
        parseDistance(text, into: &r)
        parseEffort(text, into: &r)
        r.exercises = parseExercises(text, weightUnit: weightUnit)

        // Fallback typing: named sets are a lift even without a sport word; a bare distance in a
        // running-first app is a run ("did 6 miles this morning").
        if r.type == nil, !r.exercises.isEmpty { r.type = .strength }
        if r.type == nil, r.distanceM != nil { r.type = .run }
        // Sets parsed out of a cardio sentence are noise ("ran 4x400s"), not a gym session.
        if let t = r.type, !t.isStrengthStyle { r.exercises = [] }
        return r
    }

    /// Does the text plainly say more than this parse captured? The composer's cue to send the
    /// whole sentence to the server rung (`workout-parse`). A heuristic, so it errs toward asking:
    /// any digit-bearing clause that produced no field, no discernible sport, or long prose with a
    /// thin receipt all count as "richer".
    static func looksRicher(_ text: String, than r: Result) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 24 else { return false }
        if r.type == nil { return true }
        let numericClauses = clauses(t.lowercased())
            .filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }.count
        var fieldsRead = r.exercises.count
        if r.durationS != nil { fieldsRead += 1 }
        if r.distanceM != nil { fieldsRead += 1 }
        if numericClauses > fieldsRead { return true }
        return t.count >= 90 && fieldsRead < 2
    }

    /// Resolve the parsed day/time words to a concrete start date — never in the future (you can
    /// only log what already happened), and "this morning" pins to 7:00 while a plain "yesterday"
    /// keeps the current clock time a day back.
    static func resolveDate(dayOffset: Int, timeHint: TimeHint?, now: Date = Date(),
                            calendar: Calendar = .current) -> Date {
        var base = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        if let hint = timeHint {
            let hour = switch hint {
            case .morning: 7
            case .afternoon: 13
            case .evening: 19
            }
            base = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }
        return min(base, now)
    }

    // MARK: When

    private static func parseWhen(_ text: String, into r: inout Result) {
        if contains(text, "yesterday") || contains(text, "last night") { r.dayOffset = -1 }
        if contains(text, "last night") || contains(text, "tonight") || contains(text, "evening") {
            r.timeHint = .evening
        } else if contains(text, "morning") {
            r.timeHint = .morning
        } else if contains(text, "afternoon") || contains(text, "lunch") {
            r.timeHint = .afternoon
        }
    }

    // MARK: Sport

    /// Earliest mention wins ("lifted, then a short bike" logs the lift); at the same position the
    /// longer phrase wins ("mountain bike" over "bike"). All matches are word-bounded so "ran"
    /// never fires inside "grand" or "run" inside "brunch".
    private static let sports: [(phrase: String, type: WorkoutType, indoor: Bool)] = [
        ("trail run", .trailRun, false), ("trail running", .trailRun, false),
        ("treadmill", .run, true),
        ("mountain bike", .mountainBikeRide, false), ("mtb", .mountainBikeRide, false),
        ("gravel ride", .gravelRide, false), ("gravel", .gravelRide, false),
        ("e-bike", .eBikeRide, false), ("ebike", .eBikeRide, false),
        ("spin class", .ride, true), ("spin", .ride, true), ("peloton", .ride, true),
        ("trainer ride", .ride, true),
        ("ran", .run, false), ("running", .run, false), ("run", .run, false),
        ("jogged", .run, false), ("jogging", .run, false), ("jog", .run, false),
        ("hiked", .hike, false), ("hiking", .hike, false), ("hike", .hike, false),
        ("rucked", .hike, false), ("ruck", .hike, false),
        ("walked", .walk, false), ("walking", .walk, false), ("walk", .walk, false),
        ("biked", .ride, false), ("bike ride", .ride, false), ("bike", .ride, false),
        ("rode", .ride, false), ("cycling", .ride, false), ("cycled", .ride, false),
        ("ride", .ride, false),
        ("crossfit", .crossfit, false), ("wod", .crossfit, false), ("metcon", .crossfit, false),
        ("hiit", .hiit, false), ("bootcamp", .hiit, false),
        ("lifted", .strength, false), ("lifting", .strength, false), ("lift", .strength, false),
        ("strength", .strength, false), ("weights", .strength, false), ("gym", .strength, false),
        ("upper body", .strength, false), ("lower body", .strength, false),
        ("full body", .strength, false), ("leg day", .strength, false),
        ("push day", .strength, false), ("pull day", .strength, false),
        ("yoga", .yoga, false), ("pilates", .pilates, false),
        ("swam", .swimming, false), ("swimming", .swimming, false), ("swim", .swimming, false),
        ("rowed", .rowing, false), ("rowing", .rowing, false), ("erg", .rowing, false),
        ("tennis", .tennis, false), ("soccer", .soccer, false),
        ("basketball", .basketball, false), ("golf", .golf, false),
    ]

    /// Lift words that imply the gym when no sport verb was said ("bench and squats for an hour").
    /// Hints only — they never override an explicit sport.
    private static let strengthHints = [
        "bench", "squat", "squats", "deadlift", "deadlifts", "curls", "press",
        "pushups", "push-ups", "pullups", "pull-ups", "rows", "lunges",
        "dumbbell", "barbell", "kettlebell",
    ]

    private static func parseSport(_ text: String, into r: inout Result) {
        var best: (pos: Int, len: Int, type: WorkoutType, indoor: Bool)?
        for s in sports {
            guard let range = boundedRange(of: s.phrase, in: text) else { continue }
            let pos = text.distance(from: text.startIndex, to: range.lowerBound)
            if best == nil || pos < best!.pos || (pos == best!.pos && s.phrase.count > best!.len) {
                best = (pos, s.phrase.count, s.type, s.indoor)
            }
        }
        if let best {
            r.type = best.type
            r.indoor = best.indoor
        } else if strengthHints.contains(where: { boundedRange(of: $0, in: text) != nil }) {
            r.type = .strength
        }
        // "on the trainer" / "indoor ride" as modifiers, wherever they appear.
        if contains(text, "indoor") || contains(text, "trainer") { r.indoor = true }
    }

    // MARK: Duration

    private static func parseDuration(_ text: String, into r: inout Result) {
        // "1:23:45" — the full clock form dictation produces for long efforts.
        if let c = captures(#"\b(\d{1,2}):([0-5]\d):([0-5]\d)\b"#, in: text),
           let h = Double(c[0] ?? ""), let m = Double(c[1] ?? ""), let s = Double(c[2] ?? "") {
            r.durationS = h * 3600 + m * 60 + s
            return
        }
        // "in 52:30" — mm:ss needs the "in" anchor so it can't eat clock times ("at 7:30").
        if let c = captures(#"\bin\s+(\d{1,2}):([0-5]\d)\b(?!:)"#, in: text),
           let m = Double(c[0] ?? ""), let s = Double(c[1] ?? "") {
            r.durationS = m * 60 + s
            return
        }
        // "1.5 hours", "2 hrs", "1 hour 20", "1h20" — the (?![a-z]) tail lets a digit follow the
        // unit (1h20) while blocking real words.
        if let c = captures(#"\b(\d{1,2}(?:\.\d+)?)\s*(?:hours?|hrs?|hr|h)(?![a-z])\s*(?:and\s+)?(\d{1,2})?\s*(?:minutes?|mins?|min)?(?![a-z])"#, in: text),
           let h = Double(c[0] ?? "") {
            let extra = Double(c[1] ?? "") ?? 0
            r.durationS = h * 3600 + extra * 60
            return
        }
        if let c = captures(#"\b(\d{1,3})\s*(?:minutes?|mins?|min)(?![a-z])"#, in: text),
           let m = Double(c[0] ?? "") {
            r.durationS = m * 60
            return
        }
        // The spoken forms with no digits at all.
        if contains(text, "hour and a half") { r.durationS = 90 * 60; return }
        if contains(text, "half an hour") || contains(text, "half hour") { r.durationS = 30 * 60; return }
        if contains(text, "an hour") { r.durationS = 60 * 60 }
    }

    // MARK: Distance

    private static func parseDistance(_ text: String, into r: inout Result) {
        // One adjective may sit between number and unit — "5 easy miles" is how people talk.
        if let c = captures(#"\b(\d+(?:\.\d+)?)\s*(?:[a-z]+\s+)?(?:miles?|mi)(?![a-z])"#, in: text),
           let v = Double(c[0] ?? "") {
            r.distanceM = v * Formatters.metersPerMile
            return
        }
        // "10k", "8 km" — meters are deliberately not parsed ("4x400m" is interval noise, not a
        // 400 m workout). The lookbehind keeps "5 x 1k" repeats from reading as a 1 km run.
        if let c = captures(#"(?<![x×])(?<![x×] )\b(\d+(?:\.\d+)?)\s*(?:[a-z]+\s+)?(?:kilometers?|kilometres?|km|k)(?![a-z0-9])"#, in: text),
           let v = Double(c[0] ?? "") {
            r.distanceM = v * 1000
            return
        }
        if contains(text, "half marathon") {
            r.distanceM = 21_097.5
            if r.type == nil { r.type = .run }
        } else if contains(text, "marathon") {
            r.distanceM = 42_195
            if r.type == nil { r.type = .run }
        }
    }

    // MARK: Effort

    /// Longest phrase first so "really hard" never reads as just "hard". Values sit on
    /// LogWorkoutView's labels: 1–2 easy, 3–4 steady, 5–6 moderate, 7–8 hard, 9–10 max.
    private static let efforts: [(phrase: String, rpe: Int)] = [
        ("all out", 10), ("all-out", 10), ("max effort", 10),
        ("race effort", 9), ("really hard", 9), ("very hard", 9), ("brutal", 9),
        ("hard", 8), ("tough", 8),
        ("moderate", 5), ("solid", 5),
        ("steady", 4), ("comfortable", 3),
        ("easy", 2), ("chill", 2), ("relaxed", 2), ("recovery", 2),
    ]

    private static func parseEffort(_ text: String, into r: inout Result) {
        for e in efforts where boundedRange(of: e.phrase, in: text) != nil {
            r.effort = e.rpe
            return
        }
    }

    // MARK: Exercises

    /// Clause-split set grammar. Each comma/"then"/"and"-separated clause is tried against the
    /// four shapes people actually say:
    ///   A  "bench 4x8 at 185"          name · sets×reps · weight
    ///   D  "4x8 bench at 185"          sets×reps · name · weight
    ///   B  "3 sets of 12 curls at 30"  sets of reps · name · weight
    ///   C  "curls 3 sets of 12"        name · sets of reps · weight
    /// Weight units: explicit lbs/kg win; a bare number uses the athlete's display unit.
    private static func parseExercises(_ text: String, weightUnit: WeightUnit) -> [ParsedExercise] {
        let clauses = clauses(text)

        let name = #"([a-z][a-z\s\-']*?)"#
        let weightTail = #"(?:\s*(?:at|@)?\s*(\d{1,4}(?:\.\d+)?)\s*(lbs?|pounds?|kg|kilos?)?)?"#
        let lead = #"^(?:i\s+)?(?:did\s+|hit\s+|some\s+)?"#
        let patterns = [
            lead + name + #"\s+(\d{1,2})\s*[x×]\s*(\d{1,3})"# + weightTail + "$",              // A
            lead + #"(\d{1,2})\s*[x×]\s*(\d{1,3})\s+"# + name + weightTail + "$",              // D
            lead + #"(\d{1,2})\s*sets?\s*(?:of\s+)?(\d{1,3})\s+"# + name + weightTail + "$",   // B
            lead + name + #"\s+(\d{1,2})\s*sets?\s*(?:of\s+)?(\d{1,3})"# + weightTail + "$",   // C
        ]
        let nameFirst = [true, false, false, true]

        var out: [ParsedExercise] = []
        for clause in clauses {
            for (i, pattern) in patterns.enumerated() {
                guard let c = captures(pattern, in: clause) else { continue }
                let rawName = (nameFirst[i] ? c[0] : c[2]) ?? ""
                let sets = Int((nameFirst[i] ? c[1] : c[0]) ?? "") ?? 0
                let reps = Int((nameFirst[i] ? c[2] : c[1]) ?? "") ?? 0
                guard let cleaned = cleanName(rawName), (1...20).contains(sets), (1...100).contains(reps) else { continue }
                var weightKg: Double?
                if let w = Double(c[3] ?? ""), w > 0 {
                    let unit = c[4] ?? ""
                    let kg = unit.hasPrefix("lb") || unit.hasPrefix("pound") ? w * Formatters.kgPerLb
                        : unit.isEmpty ? (weightUnit == .lb ? w * Formatters.kgPerLb : w)
                        : w
                    if kg <= 600 { weightKg = kg }   // nobody logs a 600 kg lift; that's a mis-parse
                }
                out.append(ParsedExercise(name: cleaned, sets: sets, reps: reps, weightKg: weightKg))
                break
            }
        }
        return out
    }

    /// Comma/"then"/"and"/sentence splitting — shared by the exercise grammar and `looksRicher`.
    /// ". " is a break but a bare "." is not ("22.5 kg" must survive).
    private static func clauses(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: " and then ", with: ",")
            .replacingOccurrences(of: " then ", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: ". ", with: ",")
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Words that mean the clause was cardio or bookkeeping, not an exercise name.
    private static let nameRejects: Set<String> = [
        "min", "mins", "minute", "minutes", "hour", "hours", "mile", "miles", "km", "k",
        "run", "ran", "ride", "rode", "walk", "hike", "gym", "workout", "sets", "reps",
        "x", "at", "for", "of",
    ]

    private static func cleanName(_ raw: String) -> String? {
        var words = raw.split(separator: " ").map(String.init)
        while let first = words.first, ["the", "a", "my", "some"].contains(first) { words.removeFirst() }
        guard !words.isEmpty, !words.contains(where: { nameRejects.contains($0) }) else { return nil }
        return words.joined(separator: " ").capitalized
    }

    // MARK: Matching helpers

    /// Word-bounded search — the reason "ran" can't fire inside "grand".
    private static func boundedRange(of phrase: String, in text: String) -> Range<String.Index>? {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b",
                   options: .regularExpression)
    }

    private static func contains(_ text: String, _ phrase: String) -> Bool {
        boundedRange(of: phrase, in: text) != nil
    }

    /// First match's capture groups (nil where a group didn't participate), or nil for no match.
    private static func captures(_ pattern: String, in text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
