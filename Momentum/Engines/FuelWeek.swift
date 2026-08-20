import Foundation

/// The trailing week's fueling consistency (2026-08-15) — the answer to "am I funding my training
/// day after day?", which no single-day readout can give. Pure and deterministic like every
/// engine; the display (the Today's-fueling sheet) draws exactly what this returns.
///
/// Judged against the STATIC per-kg floors — the easy carb floor and the protein floor — not each
/// past day's session-keyed target: reconstructing "what was tomorrow's long run worth on last
/// Tuesday" would need plan history the app deliberately doesn't keep, and the easy floor is the
/// same earned bar the History page's iridescent dot has always used, so the two surfaces can
/// never disagree about what a fueled day means.
///
/// No-shame rules: a day is "logged" or it isn't (an unlogged day is a gap in the journal, never
/// a failure), the summary line states counts without judgment, and the whole section stays
/// silent until three days of the week are logged — a brand-new journal owes no verdict.
enum FuelWeek {

    struct DayCell: Equatable, Sendable {
        let day: Date
        /// "M", "T", … for the column caption; the full weekday rides along for VoiceOver.
        let label: String
        let spokenDay: String
        let logged: Bool
        /// Carbs met the easy floor (the History dot's exact rule — earned, iridescent).
        let carbsMet: Bool
        let proteinMet: Bool
        let isToday: Bool
    }

    struct Summary: Equatable, Sendable {
        /// Oldest → today, always 7.
        let cells: [DayCell]
        let loggedCount: Int
        let carbsMetCount: Int
        let proteinMetCount: Int
        /// "Carb floor met 5 of the last 7 days · protein 6 of 7." nil until 3 logged days.
        let line: String?
    }

    /// One meal's contribution, plain values (mapped from SwiftData at the call site).
    struct MealInput: Sendable {
        let eatenAt: Date
        let carbsG: Int?
        let proteinG: Int?
    }

    static func summary(meals: [MealInput], bodyMassKg: Double?,
                        now: Date, calendar: Calendar = .current) -> Summary {
        let kg = bodyMassKg ?? FuelReadiness.fallbackMassKg
        let carbsFloor = Int((FuelReadiness.carbsPerKgEasy * kg).rounded())
        let proteinFloor = Int((FuelReadiness.proteinPerKgFloor * kg).rounded())
        let todayStart = calendar.startOfDay(for: now)

        var byDay: [Date: (carbs: Int, protein: Int, logged: Bool)] = [:]
        for m in meals {
            let day = calendar.startOfDay(for: m.eatenAt)
            guard day <= todayStart,
                  let age = calendar.dateComponents([.day], from: day, to: todayStart).day,
                  age < 7 else { continue }
            var slot = byDay[day] ?? (0, 0, false)
            slot.carbs += m.carbsG ?? 0
            slot.protein += m.proteinG ?? 0
            slot.logged = true
            byDay[day] = slot
        }

        var cells: [DayCell] = []
        for offset in stride(from: -6, through: 0, by: 1) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: todayStart) else { continue }
            let slot = byDay[day]
            cells.append(DayCell(day: day,
                                 label: day.formatted(.dateTime.weekday(.narrow)),
                                 spokenDay: day.formatted(.dateTime.weekday(.wide)),
                                 logged: slot?.logged ?? false,
                                 carbsMet: (slot?.carbs ?? 0) >= carbsFloor,
                                 proteinMet: (slot?.protein ?? 0) >= proteinFloor,
                                 isToday: offset == 0))
        }
        let logged = cells.filter(\.logged).count
        let carbsMet = cells.filter(\.carbsMet).count
        let proteinMet = cells.filter(\.proteinMet).count
        // Three logged days before any summary — silence is a feature, and a two-day-old journal
        // reading "carbs 1 of 7" would be the app judging days the athlete never asked it to see.
        let line = logged >= 3
            ? "Carb floor met \(carbsMet) of the last 7 days · protein \(proteinMet) of 7."
            : nil
        return Summary(cells: cells, loggedCount: logged,
                       carbsMetCount: carbsMet, proteinMetCount: proteinMet, line: line)
    }
}
