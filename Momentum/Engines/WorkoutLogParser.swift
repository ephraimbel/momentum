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

    static func parse(_ raw: String, weightUnit: WeightUnit = .kg,
                      distanceUnit: DistanceUnit = .metric) -> Result {
        var r = Result()
        let text = preprocess(raw, weightUnit: weightUnit)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return r }

        parseWhen(text, into: &r)
        parseSport(text, into: &r)
        parseDuration(text, into: &r)
        parseDistance(text, into: &r)
        parsePace(text, into: &r, distanceUnit: distanceUnit)
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

    /// One utterance can hold several workouts — "45 min upper body, bench 4x8 at 185, then ran
    /// 4 miles at 9:23 pace" is a lift AND a run. Split at each sport mention that changes
    /// discipline and parse each segment on its own; a trailing mention with no numbers of its own
    /// ("then a short bike") stays a footnote, not a card. When-words carry forward ("yesterday I
    /// lifted, then ran" — both were yesterday). Capped at 3 — nobody logs four in a breath.
    static func parseMulti(_ raw: String, weightUnit: WeightUnit = .kg,
                           distanceUnit: DistanceUnit = .metric) -> [Result] {
        let text = preprocess(raw, weightUnit: weightUnit)
        // Every sport-keyword hit, position-sorted, longest-wins, non-overlapping — so
        // "mountain bike ride" is one cycling mention, not three.
        var hits: [(pos: Int, len: Int, type: WorkoutType)] = []
        let nsRange = NSRange(text.startIndex..., in: text)
        // Named lifts split too — "walked the dog, then bench 3x10" is a walk AND a gym session;
        // without the hint entries the whole lift silently drowned in the walk card.
        let scanEntries: [(phrase: String, type: WorkoutType)] =
            sports.map { ($0.phrase, $0.type) } + strengthHints.map { ($0, .strength) }
        for s in scanEntries {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: s.phrase) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: nsRange) {
                guard let r = Range(m.range, in: text) else { continue }
                hits.append((text.distance(from: text.startIndex, to: r.lowerBound), s.phrase.count, s.type))
            }
        }
        hits.sort { $0.pos != $1.pos ? $0.pos < $1.pos : $0.len > $1.len }
        var kept: [(pos: Int, len: Int, type: WorkoutType)] = []
        for h in hits where kept.last.map({ h.pos >= $0.pos + $0.len }) ?? true { kept.append(h) }

        var boundaries: [Int] = []
        var discipline: Discipline?
        for h in kept {
            let d = h.type.discipline
            if let current = discipline, d != current { boundaries.append(h.pos) }
            discipline = d
        }
        guard !boundaries.isEmpty else {
            return [parse(text, weightUnit: weightUnit, distanceUnit: distanceUnit)]
        }

        let cuts = [0] + Array(boundaries.prefix(2))   // ≤3 segments
        var results: [Result] = []
        for (i, start) in cuts.enumerated() {
            let end = i + 1 < cuts.count ? cuts[i + 1] : text.count
            let seg = String(text[text.index(text.startIndex, offsetBy: start)
                                  ..< text.index(text.startIndex, offsetBy: end)])
            let r = parse(seg, weightUnit: weightUnit, distanceUnit: distanceUnit)
            // The primary always stands; later segments must bring their own numbers.
            if i == 0 || r.durationS != nil || r.distanceM != nil || !r.exercises.isEmpty {
                results.append(r)
            }
        }
        for i in 1..<results.count {
            if results[i].dayOffset == 0 { results[i].dayOffset = results[0].dayOffset }
            if results[i].timeHint == nil { results[i].timeHint = results[0].timeHint }
        }
        return results
    }

    /// Does the text plainly say more than this parse captured? The composer's cue to send the
    /// whole sentence to the server rung (`workout-parse`). A heuristic, so it errs toward asking:
    /// any digit-bearing clause that produced no field, no discernible sport, or long prose with a
    /// thin receipt all count as "richer".
    static func looksRicher(_ text: String, than r: Result) -> Bool {
        looksRicher(text, than: [r])
    }

    /// Multi-workout form: fields read are summed across every card before comparing against the
    /// digit-bearing clauses — two fully-read cards need no server help.
    static func looksRicher(_ text: String, than results: [Result]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 24 else { return false }
        if results.contains(where: { $0.type == nil }) { return true }
        let numericClauses = clauses(normalizeSpokenNumbers(t.lowercased()))
            .filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }.count
        var fieldsRead = 0
        for r in results {
            fieldsRead += r.exercises.count
            if r.durationS != nil { fieldsRead += 1 }
            if r.distanceM != nil { fieldsRead += 1 }
        }
        if numericClauses > fieldsRead { return true }
        return t.count >= 90 && fieldsRead < 2
    }

    /// Start dates for a multi-card save. When every card resolved to the same instant (one time
    /// context for the whole chain — "lifted, then ran"), the cards stagger so history reads in
    /// the order it happened: anchored times ("this morning" → 7:00) stack FORWARD from the
    /// anchor (lift 7:00, run 7:50); now-anchored logs stack BACKWARD so the last thing they did
    /// is the most recent. Distinct explicit times are kept as said. 5 min between workouts.
    static func stackedDates(for results: [Result], now: Date = Date(),
                             calendar: Calendar = .current) -> [Date] {
        var dates = results.map {
            resolveDate(dayOffset: $0.dayOffset, timeHint: $0.timeHint, now: now, calendar: calendar)
        }
        guard dates.count > 1,
              Set(dates.map(\.timeIntervalSinceReferenceDate)).count == 1 else { return dates }
        let gapS = 300.0
        let durations = results.map { $0.durationS ?? 0 }
        if results[0].timeHint != nil {
            for i in 1..<dates.count {
                dates[i] = min(dates[i - 1].addingTimeInterval(durations[i - 1] + gapS), now)
            }
        } else {
            for i in stride(from: dates.count - 2, through: 0, by: -1) {
                dates[i] = dates[i + 1].addingTimeInterval(-(durations[i] + gapS))
            }
        }
        return dates
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

    // MARK: Preprocess

    /// The full text-rewrite pipeline every parse runs through: spoken numbers → digits, the
    /// corrected-away halves of "instead of" phrases dropped, and gym plate lingo resolved to
    /// explicit weights. Idempotent — `parseMulti` segments re-run it safely.
    static func preprocess(_ raw: String, weightUnit: WeightUnit) -> String {
        normalizePlateMath(stripCorrections(normalizeSpokenNumbers(raw.lowercased())),
                           weightUnit: weightUnit)
    }

    /// "five hard miles instead of five easy miles" MEANS the hard five — drop the corrected-away
    /// half (to the end of its clause) so no grammar downstream reads facts the athlete replaced.
    static func stripCorrections(_ text: String) -> String {
        text.replacingOccurrences(of: #"\b(?:instead of|rather than)\s[^,.;\n]*"#,
                                  with: "", options: .regularExpression)
    }

    // MARK: Spoken numbers

    /// Dictation doesn't always render digits — gym lingo comes out as words: "one eighty five
    /// for ten reps with five sets", "a nine twenty three pace". Deterministic word→digit rewrite
    /// before any grammar runs, including the compound idioms lifters actually use:
    /// unit+tens(+unit) = digit concat ("one eighty five" → 185, "two twenty five" → 225),
    /// unit+teen ("three fifteen" → 315), and plain "X hundred (and) Y".
    static func normalizeSpokenNumbers(_ raw: String) -> String {
        let units = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                     "six": 6, "seven": 7, "eight": 8, "nine": 9]
        let teens = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
                     "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
                    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        func isNumberWord(_ w: String) -> Bool {
            units[w] != nil || teens[w] != nil || tens[w] != nil
        }

        // Rep-count idioms first — "for a triple" is lifter for "for 3".
        let raw = raw
            .replacingOccurrences(of: "for a single", with: "for 1")
            .replacingOccurrences(of: "for a double", with: "for 2")
            .replacingOccurrences(of: "for a triple", with: "for 3")

        // Line-by-line so newline clause boundaries survive; hyphens split only between number
        // words ("twenty-five" → 25) so "e-bike" stays whole.
        let normalized = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var tokens: [String] = []
            for rawTok in line.split(separator: " ", omittingEmptySubsequences: true) {
                let tok = String(rawTok)
                if tok.contains("-") {
                    let parts = tok.split(separator: "-").map(String.init)
                    if parts.count > 1, parts.allSatisfy(isNumberWord) {
                        tokens.append(contentsOf: parts)
                        continue
                    }
                }
                tokens.append(tok)
            }

            var out: [String] = []
            var i = 0
            while i < tokens.count {
                let t = tokens[i]
                func peek(_ n: Int) -> String? { i + n < tokens.count ? tokens[i + n] : nil }
                // "two forty five pound plates" is a COUNT and a plate denomination, not 245 —
                // the concat idiom stands down when a plate word follows (an optional unit word
                // may sit between); `normalizePlateMath` does the arithmetic afterwards.
                func plateFollows(_ n: Int) -> Bool {
                    var k = i + n
                    if k < tokens.count,
                       ["pound", "pounds", "lb", "lbs", "kilo", "kilos", "kg"].contains(tokens[k]) {
                        k += 1
                    }
                    guard k < tokens.count else { return false }
                    let w = tokens[k].trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
                    return w == "plate" || w == "plates"
                }
                if let u = units[t], peek(1) == "hundred" {
                    var value = u * 100, consumed = 2
                    var j = i + 2
                    if peek(2) == "and" { consumed += 1; j += 1 }
                    if j < tokens.count {
                        let next = tokens[j]
                        if let tv = tens[next] {
                            value += tv; consumed += 1
                            if j + 1 < tokens.count, let uv = units[tokens[j + 1]] { value += uv; consumed += 1 }
                        } else if let te = teens[next] {
                            value += te; consumed += 1
                        } else if let uv = units[next] {
                            value += uv; consumed += 1
                        }
                    }
                    out.append(String(value)); i += consumed; continue
                }
                if let u = units[t], let next = peek(1), let tv = tens[next] {
                    // "one eighty five" — the gym idiom: digit concatenation, not addition.
                    var value = u * 100 + tv, consumed = 2
                    if let last = peek(2), let uv = units[last] { value += uv; consumed += 1 }
                    if plateFollows(consumed) {
                        out.append(String(u)); i += 1; continue   // count stays; "forty five" next
                    }
                    out.append(String(value)); i += consumed; continue
                }
                if let u = units[t], let next = peek(1), let te = teens[next] {
                    if plateFollows(2) { out.append(String(u)); i += 1; continue }
                    out.append(String(u * 100 + te)); i += 2; continue   // "three fifteen" → 315
                }
                if let tv = tens[t] {
                    if let next = peek(1), let uv = units[next] { out.append(String(tv + uv)); i += 2 }
                    else { out.append(String(tv)); i += 1 }
                    continue
                }
                if let te = teens[t] { out.append(String(te)); i += 1; continue }
                if let u = units[t] { out.append(String(u)); i += 1; continue }
                out.append(t); i += 1
            }
            return out.joined(separator: " ")
        }.joined(separator: "\n")

        // "four and a half miles" (now "4 and a half miles") → "4.5 miles" — spoken or typed.
        return normalized.replacingOccurrences(of: #"\b(\d+)\s+and\s+a\s+half\b"#,
                                               with: "$1.5", options: .regularExpression)
    }

    // MARK: Plate lingo

    /// Gym plate talk → an explicit total weight, so every set pattern downstream just reads a
    /// number. Arithmetic on stated facts only (2026-07-23 user report — "two forty five pound
    /// plates on each side" was mis-read as a 245 lb lift):
    ///   "2 45 pound plates on each side" → 45 × 2 per side × 2 = "180 lbs" (leg press etc.)
    ///   …in a barbell clause (bench/squat/deadlift/rows/overhead) the 45 lb bar rides along
    ///   "three plates" (bare, barbell)   → the universal idiom: 3 per side of 45s + bar = 315
    ///   "2 45s a side"                   → denominated shorthand; the side phrase disambiguates
    /// Kilo gyms get the same treatment (20 kg plates, 20 kg bar). A number with no plate word
    /// ("benched 245") is never touched.
    static func normalizePlateMath(_ text: String, weightUnit: WeightUnit) -> String {
        var text = text
        // Typed/concatenated shorthand first: "245 pound plates" is 2 × 45-lb plates (245-lb
        // plates don't exist) — split the digits so the denominated rule below reads it.
        text = text.replacingOccurrences(
            of: #"\b([1-9])(45|35|25|15)(?=\s*(?:pounds?|lbs?|kilos?|kg)?\s*plates?\b)"#,
            with: "$1 $2", options: .regularExpression)

        let sideCore = #"(?:on\s+)?(?:each|both|per|a)\s+sides?|each\b"#
        let sideOpt = "(\\s+(?:" + sideCore + "))?"
        let sideReq = "(\\s+(?:" + sideCore + "))"

        // Denominated: "2 45 pound plates (on each side)".
        text = rewrite(#"\b(\d{1,2})\s+(\d{1,3}(?:\.\d+)?)\s*(pounds?|lbs?|kilos?|kg)?\s*plates?\b(?!\s*of\b)"# + sideOpt,
                       in: text) { g, clause in
            guard let count = Int(g[0] ?? ""), (1...10).contains(count),
                  let denom = Double(g[1] ?? "") else { return nil }
            let lb = isPounds(unitWord: g[2], denom: denom, weightUnit: weightUnit)
            guard (lb ? lbPlates : kgPlates).contains(denom) else { return nil }
            return plateTotal(count: count, denom: denom, perSide: g[3] != nil, lb: lb, clause: clause)
        }
        // Denominated 's shorthand: "2 45s a side" — the side phrase is required (a bare
        // "2 45s" could be anything).
        text = rewrite(#"\b(\d{1,2})\s+(\d{2,3})s\b"# + sideReq, in: text) { g, clause in
            guard let count = Int(g[0] ?? ""), (1...10).contains(count),
                  let denom = Double(g[1] ?? "") else { return nil }
            let lb = isPounds(unitWord: nil, denom: denom, weightUnit: weightUnit)
            guard (lb ? lbPlates : kgPlates).contains(denom) else { return nil }
            return plateTotal(count: count, denom: denom, perSide: true, lb: lb, clause: clause)
        }
        // Bare count: "three plates" — the idiom already means per side ("two plates" = 225 on
        // a bar); metric gyms count 20 kg plates the same way.
        text = rewrite(#"\b(\d{1,2})\s*plates?\b(?!\s*of\b)"# + sideOpt, in: text) { g, clause in
            guard let count = Int(g[0] ?? ""), (1...10).contains(count) else { return nil }
            let lb = weightUnit == .lb
            return plateTotal(count: count, denom: lb ? 45 : 20, perSide: true, lb: lb, clause: clause)
        }
        return text
    }

    private static let lbPlates: Set<Double> = [2.5, 5, 10, 15, 25, 35, 45, 55]
    private static let kgPlates: Set<Double> = [1.25, 2.5, 5, 10, 15, 20, 25]

    /// Which unit a plate denomination is in: an explicit unit word wins; 45/35/55 only exist in
    /// pounds and 20/1.25 only in kilos; the ambiguous sizes follow the athlete's display unit.
    private static func isPounds(unitWord: String?, denom: Double, weightUnit: WeightUnit) -> Bool {
        if let u = unitWord, !u.isEmpty { return u.hasPrefix("lb") || u.hasPrefix("pound") }
        if lbPlates.contains(denom), !kgPlates.contains(denom) { return true }
        if kgPlates.contains(denom), !lbPlates.contains(denom) { return false }
        return weightUnit == .lb
    }

    /// The rewritten weight text for one plate clause, or nil to leave the words untouched.
    /// The bar joins only in a barbell clause — machines (leg press, hack squat…) have none.
    private static func plateTotal(count: Int, denom: Double, perSide: Bool, lb: Bool,
                                   clause: String) -> String? {
        let barbell = clause.range(
            of: #"\b(bench|squats?|squatted|deadlifts?|deadlifted|barbell|rows?|rowed|overhead|ohp|military)\b"#,
            options: .regularExpression) != nil
        let machine = clause.range(
            of: #"\b(leg press|hack|machine|sled|smith)\b"#, options: .regularExpression) != nil
        var value = Double(count) * denom * (perSide ? 2 : 1)
        if barbell && !machine { value += lb ? 45 : 20 }
        guard value > 0, value <= (lb ? 1500 : 700) else { return nil }
        let unit = lb ? "lbs" : "kg"
        return value == value.rounded() ? "\(Int(value)) \(unit)" : "\(value) \(unit)"
    }

    /// Regex-rewrite with a computed replacement, matches processed back-to-front so earlier
    /// ranges stay valid. The callback receives the capture groups and the clause text BEFORE
    /// the match (the bar-context window); returning nil leaves that match as written.
    private static func rewrite(_ pattern: String, in text: String,
                                _ replacement: ([String?], String) -> String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let full = Range(m.range, in: text) else { continue }
            let groups = (1..<m.numberOfRanges).map {
                Range(m.range(at: $0), in: text).map { String(text[$0]) }
            }
            let clause = String(text[..<full.lowerBound])
                .components(separatedBy: CharacterSet(charactersIn: ",.;\n")).last ?? ""
            guard let rep = replacement(groups, clause),
                  let outRange = Range(m.range, in: out) else { continue }
            out.replaceSubrange(outRange, with: rep)
        }
        return out
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

    /// Lift words that imply the gym when no sport verb was said ("bench and squats for an hour",
    /// "squatted 225 for 5"). Hints only — they never override an explicit sport.
    private static let strengthHints = [
        "bench", "squat", "squats", "deadlift", "deadlifts", "curls", "press",
        "pushups", "push-ups", "pullups", "pull-ups", "rows", "lunges",
        "dumbbell", "barbell", "kettlebell",
        "benched", "squatted", "deadlifted", "curled", "pressed",
        "core", "abs",
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
        // The lookahead skips pace-speak: in "8 minute miles for 40 minutes", the first
        // "minute" is a pace's unit, not a duration — without it the run logged as 8 minutes.
        // The `(?<!:)` keeps the seconds of an mm:ss out of it: "8:25 min/mile" is an 8:25 pace,
        // and without it the "25 min" logged a phantom 25-minute run.
        if let c = captures(#"(?<!:)\b(\d{1,3})\s*(?:minutes?|mins?|min)(?![a-z])(?!\s+(?:miles?|mi|kilometers?|kilometres?|km|ks?)\b)"#, in: text),
           let m = Double(c[0] ?? "") {
            r.durationS = m * 60
            return
        }
        // The spoken forms with no digits at all.
        if contains(text, "hour and a half") { r.durationS = 90 * 60; return }
        if contains(text, "half an hour") || contains(text, "half hour") { r.durationS = 30 * 60; return }
        // "an hour and 15" — dictation drops the "minutes"; the bare an-hour fallback was
        // swallowing the trailing minutes and under-logging to exactly 60.
        if let c = captures(#"\ban hour\s+(?:and\s+)?(\d{1,2})(?![a-z0-9:])"#, in: text),
           let extra = Double(c[0] ?? "") {
            r.durationS = 3600 + extra * 60
            return
        }
        if contains(text, "an hour") { r.durationS = 60 * 60 }
    }

    // MARK: Distance

    private static func parseDistance(_ text: String, into r: inout Result) {
        // One adjective may sit between number and unit — "5 easy miles" is how people talk.
        // The adjective must NOT be a time word: "8 minute miles" is pace-speak, and reading it
        // as an 8-mile run logged a phantom distance the athlete never stated.
        if let c = captures(#"\b(\d+(?:\.\d+)?)\s*(?:(?!min|sec|hour)[a-z]+\s+)?(?:miles?|mi)(?![a-z])"#, in: text),
           let v = Double(c[0] ?? "") {
            r.distanceM = v * Formatters.metersPerMile
            return
        }
        // "10k", "8 km" — meters are deliberately not parsed ("4x400m" is interval noise, not a
        // 400 m workout). The lookbehind keeps "5 x 1k" repeats from reading as a 1 km run.
        if let c = captures(#"(?<![x×])(?<![x×] )\b(\d+(?:\.\d+)?)\s*(?:(?!min|sec|hour)[a-z]+\s+)?(?:kilometers?|kilometres?|km|k)(?![a-z0-9])"#, in: text),
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

    // MARK: Pace

    /// "4 miles at 9:23 pace" (or, spoken, "at a nine twenty three pace" → "923 pace") states the
    /// run's time as pace × distance — arithmetic on stated facts, not invention. Runs only when
    /// no explicit duration was said; the pace's unit defaults to the athlete's display unit and
    /// an explicit "/km" or "per mile" wins.
    private static func parsePace(_ text: String, into r: inout Result, distanceUnit: DistanceUnit) {
        guard r.durationS == nil, let dist = r.distanceM else { return }

        // The pace's implicit unit follows the unit the athlete just SAID for the distance —
        // "4 miles at 8:00" is 8:00/mi even on a metric display (defaulting to the display unit
        // computed a duration off by the km/mi ratio). An explicit "/km" or "per mile" on the
        // pace itself still wins, below.
        var perMile = distanceUnit == .imperial
        if captures(#"\b\d+(?:\.\d+)?\s*(?:(?!min|sec|hour)[a-z]+\s+)?(?:miles?|mi)(?![a-z])"#, in: text) != nil {
            perMile = true
        } else if captures(#"(?<![x×])(?<![x×] )\b\d+(?:\.\d+)?\s*(?:(?!min|sec|hour)[a-z]+\s+)?(?:kilometers?|kilometres?|km|k)(?![a-z0-9])"#, in: text) != nil {
            perMile = false
        }

        // A pace is an mm:ss (or a spoken 3–4 digit "825"), marked as a pace — not a duration — by
        // ANY of: the word "pace", a per-unit tag (/mi, per mile, min/mile), or simply a leading
        // "at". Each colon pattern captures (minutes)(seconds)(unit?); first hit wins.
        let unit = #"(mi(?:le)?s?|km|kilometres?|kilometers?)"#
        var perS: Double?
        var paceUnit: String?
        let colonPatterns = [
            #"\b(\d{1,2}):([0-5]\d)\s*(?:min(?:ute)?s?\s*)?(?:/|per\s+)?"# + unit + #"?\s*pace"#,   // "8:25 pace", "8:25 /mi pace"
            #"\b(\d{1,2}):([0-5]\d)\s*(?:min(?:ute)?s?\s*)?(?:/|per\s+)\s*"# + unit + #"\b"#,        // "8:25/mi", "8:25 per mile", "8:25 min/mile"
            #"\b(?:at|@)\s+(?:an?\s+)?(\d{1,2}):([0-5]\d)\b(?!:)(?!\s*[ap]\.?m\b)(?:\s*(?:/|per\s+)\s*"# + unit + #")?"#,  // bare "at 8:25"
        ]
        for pattern in colonPatterns {
            if let c = captures(pattern, in: text), let m = Double(c[0] ?? ""), let s = Double(c[1] ?? "") {
                perS = m * 60 + s
                if c.count > 2 { paceUnit = c[2] }
                break
            }
        }
        // Spoken 3–4 digit forms ("825 pace", "825 per mile"). No bare-"at" here — a lone "825" is
        // too ambiguous without the colon, so it needs "pace" or a per-unit tag to read as a pace.
        if perS == nil {
            let digitPatterns = [
                #"\b(\d{3,4})\s*(?:min(?:ute)?s?\s*)?(?:/|per\s+)?"# + unit + #"?\s*pace"#,
                #"\b(\d{3,4})\s*(?:min(?:ute)?s?\s*)?(?:/|per\s+)\s*"# + unit + #"\b"#,
            ]
            for pattern in digitPatterns {
                if let c = captures(pattern, in: text), let v = Double(c[0] ?? "") {
                    let m = (v / 100).rounded(.down), s = v.truncatingRemainder(dividingBy: 100)
                    if s < 60 {
                        perS = m * 60 + s
                        if c.count > 1 { paceUnit = c[1] }
                    }
                    break
                }
            }
        }
        if let paceUnit { perMile = paceUnit.hasPrefix("mi") }

        // 2:30–20:00 per unit — outside that it's a mis-read, not a pace.
        guard let perS, perS >= 150, perS <= 1200 else { return }
        let unitCount = perMile ? dist / Formatters.metersPerMile : dist / 1000
        r.durationS = (perS * unitCount).rounded()
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
        // ALL mentions, position-scanned — the athlete's LAST word on it wins ("5 easy miles…
        // actually a hard effort" is hard, and "…actually felt pretty easy" flips back), with
        // the longer phrase beating its own substring ("really hard" is 9, never the inner 8).
        var hits: [(pos: Int, len: Int, rpe: Int)] = []
        let nsRange = NSRange(text.startIndex..., in: text)
        for e in efforts {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: e.phrase) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: nsRange) {
                guard let range = Range(m.range, in: text) else { continue }
                hits.append((text.distance(from: text.startIndex, to: range.lowerBound),
                             e.phrase.count, e.rpe))
            }
        }
        hits.sort { $0.pos != $1.pos ? $0.pos < $1.pos : $0.len > $1.len }
        var kept: [(pos: Int, len: Int, rpe: Int)] = []
        for h in hits where kept.last.map({ h.pos >= $0.pos + $0.len }) ?? true { kept.append(h) }
        r.effort = kept.last?.rpe
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

        // Weight-first gym lingo — how lifters actually talk: "bench pressed 185 for 10 reps with
        // 5 sets", "squatted 225 for 5" (the top-set idiom → 1×5), "bench 185 for 5 sets of 10".
        let weightHead = #"\s+(\d{1,4}(?:\.\d+)?)\s*(lbs?|pounds?|kg|kilos?)?\s+for\s+"#
        let patternE2 = lead + name + weightHead + #"(\d{1,2})\s*sets?(?:\s*(?:of)?\s*(\d{1,3})\s*(?:reps?)?)?$"#
        let patternE1 = lead + name + weightHead + #"(\d{1,3})\s*(?:reps?)?(?:\s*(?:with|for|,)?\s*(\d{1,2})\s*sets?)?$"#

        func toKg(_ w: Double, unit: String) -> Double? {
            let kg = unit.hasPrefix("lb") || unit.hasPrefix("pound") ? w * Formatters.kgPerLb
                : unit.isEmpty ? (weightUnit == .lb ? w * Formatters.kgPerLb : w)
                : w
            return kg <= 600 ? kg : nil   // nobody logs a 600 kg lift; that's a mis-parse
        }

        var out: [ParsedExercise] = []
        for clause in clauses {
            var matched = false
            for (i, pattern) in patterns.enumerated() {
                guard let c = captures(pattern, in: clause) else { continue }
                let rawName = (nameFirst[i] ? c[0] : c[2]) ?? ""
                let sets = Int((nameFirst[i] ? c[1] : c[0]) ?? "") ?? 0
                let reps = Int((nameFirst[i] ? c[2] : c[1]) ?? "") ?? 0
                guard let cleaned = cleanName(rawName), (1...20).contains(sets), (1...100).contains(reps) else { continue }
                var weightKg: Double?
                if let w = Double(c[3] ?? ""), w > 0 { weightKg = toKg(w, unit: c[4] ?? "") }
                out.append(ParsedExercise(name: cleaned, sets: sets, reps: reps, weightKg: weightKg))
                matched = true
                break
            }
            guard !matched else { continue }
            // E2: "… 185 for 5 sets (of 10)" — reps required for a set line (no invented numbers).
            if let c = captures(patternE2, in: clause) {
                guard let cleaned = cleanName(c[0] ?? ""),
                      let w = Double(c[1] ?? ""), let kg = toKg(w, unit: c[2] ?? ""),
                      let sets = Int(c[3] ?? ""), (1...20).contains(sets),
                      let reps = Int(c[4] ?? ""), (1...100).contains(reps) else { continue }
                out.append(ParsedExercise(name: cleaned, sets: sets, reps: reps, weightKg: kg))
                continue
            }
            // E1: "… 185 for 10 (reps) (with 5 sets)" — no sets said means ONE set of 10 (the
            // "worked up to X for N" top-set idiom).
            if let c = captures(patternE1, in: clause) {
                guard let cleaned = cleanName(c[0] ?? ""),
                      let w = Double(c[1] ?? ""), let kg = toKg(w, unit: c[2] ?? ""),
                      let reps = Int(c[3] ?? ""), (1...100).contains(reps) else { continue }
                let sets = Int(c[4] ?? "") ?? 1
                guard (1...20).contains(sets) else { continue }
                out.append(ParsedExercise(name: cleaned, sets: sets, reps: reps, weightKg: kg))
            }
        }
        return out
    }

    /// Comma/"then"/"and"/sentence splitting — shared by the exercise grammar and `looksRicher`.
    /// ". " is a break but a bare "." is not ("22.5 kg" must survive).
    private static func clauses(_ text: String) -> [String] {
        text
            // "10 reps and 5 sets" is ONE set line — join before the and-split strands the
            // sets in their own clause (which silently logged 1×10).
            .replacingOccurrences(of: #"(\d+)\s*(reps?)\s+and\s+(\d+)\s*(sets?)"#,
                                  with: "$1 $2 with $3 $4", options: .regularExpression)
            .replacingOccurrences(of: #"(\d+)\s*(sets?)\s+and\s+(\d+)\s*(reps?)"#,
                                  with: "$1 $2 of $3 $4", options: .regularExpression)
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

    /// Spoken past-tense → the exercise's canonical name ("bench pressed 185" is a Bench Press).
    private static let verbCanonical: [String: String] = [
        "benched": "bench", "pressed": "press", "squatted": "squat", "deadlifted": "deadlift",
        "curled": "curl", "rowed": "row", "lunged": "lunge", "shrugged": "shrug", "dipped": "dip",
    ]

    private static func cleanName(_ raw: String) -> String? {
        var words = raw.split(separator: " ").map(String.init)
        while let first = words.first, ["the", "a", "my", "some"].contains(first) { words.removeFirst() }
        // Trailing connectives are grammar residue, not name — "leg press with 180 lbs" must
        // read as a Leg Press, not a "Leg Press With".
        while let last = words.last, ["with", "at", "on", "using", "the", "a"].contains(last) {
            words.removeLast()
        }
        words = words.map { verbCanonical[$0] ?? $0 }
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
