import Foundation

/// The month of eating, computed — the pure engine behind the Nutrition page's trend sections
/// (2026-08-20). One pass over a window of meals produces everything the page draws: score-by-day,
/// energy-by-day, floor consistency, the processed share by week, the foods that actually recur,
/// and the monthly mineral picture (the sanctioned surface for micros — daily gauges were
/// deliberately retired 2026-07-16; a month is the scale they move on).
///
/// Doctrine carried over from the rest of Fuel: floors never ceilings (consistency counts DAYS MET,
/// never grams over), no-shame words only, the score judges food not athletes, and every number is
/// deterministic engine math — nothing here bills a call. Judged against the same static floors
/// `FuelWeek` uses (plan history isn't kept, so day-N's true session-keyed floor is unknowable in
/// hindsight — the everyday floor is the honest constant yardstick).
enum FuelTrends {

    // MARK: Inputs

    /// One meal, flattened for the engine (the view builds these from `Meal` — the engine never
    /// touches SwiftData).
    struct MealInput {
        let eatenAt: Date
        var kcal: Int?
        var carbsG: Int?
        var proteinG: Int?
        /// Per-item nutrition facts (already the `HealthScore` bridge's output) — item-level so
        /// scores weight by energy and foods can be ranked by name.
        var facts: [HealthScore.Facts] = []
        var potassiumMg: Int?
        var magnesiumMg: Int?
        var ironMg: Double?
        var calciumMg: Int?
    }

    // MARK: Outputs

    /// One calendar day in the window. Days with nothing logged still appear (`logged == false`)
    /// so charts keep honest gaps instead of silently compressing time.
    struct Day: Identifiable {
        let day: Date
        let logged: Bool
        let kcal: Int
        let carbsG: Int
        let proteinG: Int
        let score: Int?
        let band: HealthScore.Band?
        var id: Date { day }
    }

    /// One week's food-quality composition, kcal-weighted (a lettuce leaf can't launder a
    /// processed week). `share` values sum to 1 across the bands present.
    struct WeekMix: Identifiable {
        let weekStart: Date
        let share: [HealthScore.Band: Double]
        let kcal: Int
        var processedShare: Double { share[.processed] ?? 0 }
        var id: Date { weekStart }
    }

    /// A food that keeps showing up, ranked by how often.
    struct TopFood: Identifiable {
        let name: String        // display-cased from the most recent spelling
        let count: Int
        let kcal: Int           // total energy it contributed over the window
        let verdict: HealthScore.Verdict?
        var id: String { name.lowercased() }
    }

    /// The month's mineral picture: daily averages over LOGGED days vs the sex-aware floors.
    struct MicroMonth {
        struct Line {
            let label: String
            let avg: Double
            let floor: Double
            let unit: String    // "mg"
            /// False when NO meal in the window carried this micro at all — unknown, not zero.
            /// An unsampled line never drives the insight and never claims a 0-mg average
            /// (the "nil renders —, never zero" rule, at month scale).
            let sampled: Bool
            var coverage: Double { floor > 0 ? min(1, avg / floor) : 1 }
        }
        let potassium: Line
        let magnesium: Line
        let iron: Line
        let calcium: Line
        /// One quiet, deterministic sentence about the biggest gap — nil when nothing needs
        /// saying (all floors ≥ 80% covered) or the sample is too thin to judge.
        let insight: String?
        var lines: [Line] { [potassium, magnesium, iron, calcium] }
    }

    struct Report {
        let days: [Day]                  // oldest → newest, every day in the window
        let loggedDays: Int
        /// Any item in the window carried a NOVA class. Without NOVA the processed band almost
        /// never fires (sugar alone reads "mixed"), so a totals-only history would show a false
        /// 0% processed share — surfaces gate composition claims on this.
        let novaSampled: Bool
        let avgScore: Int?               // across logged days that scored
        let avgKcal: Int?                // across logged days
        let kcalFloor: Int               // the everyday baseline (30 kcal/kg), the charts' quiet rule
        let carbsFloorG: Int             // easy-day floor (3 g/kg) — FuelWeek's yardstick
        let proteinFloorG: Int           // 1.4 g/kg
        let carbsDaysMet: Int
        let proteinDaysMet: Int
        let weeks: [WeekMix]             // oldest → newest, only weeks with logged food
        let topFoods: [TopFood]
        let micros: MicroMonth?          // nil until the sample can carry a monthly claim
    }

    /// Minimum logged days before the monthly mineral averages mean anything.
    static let microMinimumDays = 5
    /// Top-foods list length.
    static let topFoodCount = 8

    // MARK: The one pass

    /// `isMale`: true/false when the athlete set a sex in their profile, nil otherwise — picks the
    /// same micro floors the daily readout uses.
    static func report(meals: [MealInput], bodyMassKg: Double?, isMale: Bool?,
                       windowDays: Int = 30, now: Date = Date(),
                       calendar: Calendar = .current) -> Report? {
        guard windowDays > 0 else { return nil }
        let todayStart = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: todayStart)
        else { return nil }

        let kg = bodyMassKg ?? FuelReadiness.fallbackMassKg
        let carbsFloor = Int((FuelReadiness.carbsPerKgEasy * kg).rounded())
        let proteinFloor = Int((FuelReadiness.proteinPerKgFloor * kg).rounded())
        let kcalFloor = Int((FuelReadiness.baselineKcalPerKg * kg).rounded())

        // Bucket the window's meals by day. Inputs may arrive in any order.
        struct DayBucket {
            var kcal = 0, carbs = 0, protein = 0
            var facts: [HealthScore.Facts] = []
            var potassium = 0, magnesium = 0, calcium = 0
            var iron = 0.0
            var potassiumSampled = false, magnesiumSampled = false
            var ironSampled = false, calciumSampled = false
        }
        var byDay: [Date: DayBucket] = [:]
        var foodCounts: [String: (count: Int, kcal: Int, display: String, latest: Date,
                                  facts: HealthScore.Facts?)] = [:]

        // No upper time bound: a meal stamped later TODAY (a pre-logged dinner, a seeded demo
        // day walked past midnight) belongs to today's bucket — the dashboard counts it, so the
        // month must too. Days beyond today can't occur (eatenAt is bounded at entry).
        for meal in meals {
            guard meal.eatenAt >= windowStart else { continue }
            let day = calendar.startOfDay(for: meal.eatenAt)
            var bucket = byDay[day] ?? DayBucket()
            bucket.kcal += meal.kcal ?? 0
            bucket.carbs += meal.carbsG ?? 0
            bucket.protein += meal.proteinG ?? 0
            bucket.facts.append(contentsOf: meal.facts)
            bucket.potassium += meal.potassiumMg ?? 0
            bucket.magnesium += meal.magnesiumMg ?? 0
            bucket.iron += meal.ironMg ?? 0
            bucket.calcium += meal.calciumMg ?? 0
            if meal.potassiumMg != nil { bucket.potassiumSampled = true }
            if meal.magnesiumMg != nil { bucket.magnesiumSampled = true }
            if meal.ironMg != nil { bucket.ironSampled = true }
            if meal.calciumMg != nil { bucket.calciumSampled = true }
            byDay[day] = bucket

            // Foods recur by fact names: the AI's clean item names, a barcode label — or, for a
            // totals-only meal, the athlete's own sentence (its pseudo-fact carries `meal.text`,
            // the same precedent the usuals chips set: a repeated phrase IS a repeatable food).
            // Meals with no numbers at all carry no facts and never rank.
            for fact in meal.facts where !fact.name.isEmpty {
                let key = fact.name.lowercased()
                var entry = foodCounts[key] ?? (0, 0, fact.name, .distantPast, nil)
                entry.count += 1
                entry.kcal += fact.kcal
                if meal.eatenAt > entry.latest { entry.latest = meal.eatenAt; entry.display = fact.name }
                entry.facts = fact
                foodCounts[key] = entry
            }
        }

        guard !byDay.isEmpty else { return nil }

        // Day series — every day present, logged or not.
        var days: [Day] = []
        var scoreSum = 0, scoreN = 0, kcalSum = 0, loggedN = 0
        var carbsMet = 0, proteinMet = 0
        for offset in 0..<windowDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart) else { continue }
            if let bucket = byDay[day] {
                let verdict = HealthScore.aggregate(bucket.facts)
                days.append(Day(day: day, logged: true, kcal: bucket.kcal,
                                carbsG: bucket.carbs, proteinG: bucket.protein,
                                score: verdict?.score, band: verdict?.band))
                loggedN += 1
                kcalSum += bucket.kcal
                if let s = verdict?.score { scoreSum += s; scoreN += 1 }
                if bucket.carbs >= carbsFloor { carbsMet += 1 }
                if bucket.protein >= proteinFloor { proteinMet += 1 }
            } else {
                days.append(Day(day: day, logged: false, kcal: 0, carbsG: 0, proteinG: 0,
                                score: nil, band: nil))
            }
        }

        // Weekly quality mix — kcal-weighted band shares, weeks keyed to the athlete's calendar.
        var weekFacts: [Date: [HealthScore.Facts]] = [:]
        for (day, bucket) in byDay {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { continue }
            weekFacts[week, default: []].append(contentsOf: bucket.facts)
        }
        let weeks: [WeekMix] = weekFacts.keys.sorted().compactMap { week in
            let facts = weekFacts[week] ?? []
            guard !facts.isEmpty else { return nil }
            var kcalByBand: [HealthScore.Band: Double] = [:]
            var total = 0.0
            for f in facts {
                // The aggregate floor (20 kcal) keeps a zero-calorie item from vanishing — the
                // same anti-laundering weight `HealthScore.aggregate` uses.
                let weight = max(Double(f.kcal), 20)
                kcalByBand[HealthScore.score(f).band, default: 0] += weight
                total += weight
            }
            guard total > 0 else { return nil }
            let share = kcalByBand.mapValues { $0 / total }
            return WeekMix(weekStart: week, share: share, kcal: facts.reduce(0) { $0 + $1.kcal })
        }

        // Top foods — by how often they recur; energy breaks ties.
        let topFoods: [TopFood] = foodCounts.values
            .sorted { $0.count == $1.count ? $0.kcal > $1.kcal : $0.count > $1.count }
            .prefix(topFoodCount)
            .map { TopFood(name: $0.display, count: $0.count, kcal: $0.kcal,
                           verdict: $0.facts.map(HealthScore.score)) }

        // Minerals — daily averages over logged days vs the same sex-aware floors the readout uses.
        var micros: MicroMonth?
        if loggedN >= microMinimumDays {
            let n = Double(loggedN)
            let pFloor = isMale == true ? FuelReadiness.potassiumFloorMg.male
                : (isMale == false ? FuelReadiness.potassiumFloorMg.female : FuelReadiness.potassiumFloorMg.neutral)
            let mFloor = isMale == true ? FuelReadiness.magnesiumFloorMg.male
                : (isMale == false ? FuelReadiness.magnesiumFloorMg.female : FuelReadiness.magnesiumFloorMg.neutral)
            let iFloor = isMale == true ? FuelReadiness.ironFloorMg.male
                : (isMale == false ? FuelReadiness.ironFloorMg.female : FuelReadiness.ironFloorMg.neutral)
            let buckets = byDay.values
            let potassium = MicroMonth.Line(label: "Potassium",
                                            avg: Double(buckets.reduce(0) { $0 + $1.potassium }) / n,
                                            floor: Double(pFloor), unit: "mg",
                                            sampled: buckets.contains(where: \.potassiumSampled))
            let magnesium = MicroMonth.Line(label: "Magnesium",
                                            avg: Double(buckets.reduce(0) { $0 + $1.magnesium }) / n,
                                            floor: Double(mFloor), unit: "mg",
                                            sampled: buckets.contains(where: \.magnesiumSampled))
            let iron = MicroMonth.Line(label: "Iron",
                                       avg: buckets.reduce(0) { $0 + $1.iron } / n,
                                       floor: iFloor, unit: "mg",
                                       sampled: buckets.contains(where: \.ironSampled))
            let calcium = MicroMonth.Line(label: "Calcium",
                                          avg: Double(buckets.reduce(0) { $0 + $1.calcium }) / n,
                                          floor: Double(FuelReadiness.calciumFloorMg), unit: "mg",
                                          sampled: buckets.contains(where: \.calciumSampled))
            micros = MicroMonth(potassium: potassium, magnesium: magnesium, iron: iron,
                                calcium: calcium,
                                insight: microInsight([potassium, magnesium, iron, calcium]))
        }

        let novaSampled = byDay.values.contains { $0.facts.contains { $0.nova != nil } }
        return Report(days: days,
                      loggedDays: loggedN,
                      novaSampled: novaSampled,
                      avgScore: scoreN > 0 ? Int((Double(scoreSum) / Double(scoreN)).rounded()) : nil,
                      avgKcal: loggedN > 0 ? kcalSum / loggedN : nil,
                      kcalFloor: kcalFloor,
                      carbsFloorG: carbsFloor, proteinFloorG: proteinFloor,
                      carbsDaysMet: carbsMet, proteinDaysMet: proteinMet,
                      weeks: weeks, topFoods: topFoods, micros: micros)
    }

    /// The single mineral sentence: name the widest gap under 80% coverage with the classic food
    /// sources; stay silent when the month looks after itself. No-shame: gaps are "worth a look",
    /// never a failing. (These are food-first lines — never a supplement instruction, never
    /// medical advice.)
    static func microInsight(_ lines: [MicroMonth.Line]) -> String? {
        let gaps = lines.filter { $0.sampled && $0.coverage < 0.8 }.sorted { $0.coverage < $1.coverage }
        guard let worst = gaps.first else { return nil }
        let sources: String
        switch worst.label {
        case "Potassium": sources = "potatoes, bananas, beans and yogurt carry it"
        case "Magnesium": sources = "nuts, whole grains and leafy greens carry it"
        case "Iron": sources = "red meat, lentils and fortified cereal carry it"
        default: sources = "dairy, tofu and leafy greens carry it"
        }
        let avgText = worst.avg >= 100 ? "\(Int(worst.avg.rounded()))" : String(format: "%.0f", worst.avg)
        let floorText = worst.floor >= 100 ? "\(Int(worst.floor.rounded()))" : String(format: "%.0f", worst.floor)
        return "\(worst.label) has averaged \(avgText) of \(floorText) \(worst.unit) a day this month — worth a look: \(sources)."
    }
}
