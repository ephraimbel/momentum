import Foundation

/// The one place a structured session is compressed into human rows — "6 × 400 m @ 7:05 /mi",
/// "Recovery · 90 s", "Warm-up · 0.6 mi" — shared by the Plan detail sheet and Today's
/// confirm-and-start sheet so the prescription reads identically everywhere it appears.
extension StructuredWorkout {
    /// Grouped display lines: rep blocks collapse to one line (recovery shown once beneath),
    /// warm-up / cool-down / tempo blocks stand alone.
    func summaryLines(distanceUnit: DistanceUnit) -> [(label: String, detail: String)] {
        // Repeating run/walk sessions collapse to a single summary line.
        if workStepCount > 0, steps.allSatisfy({ $0.repTotal == nil }),
           title.lowercased().contains("run/walk") {
            return [("\(workStepCount) × run / walk", "alternating")]
        }
        var lines: [(String, String)] = []
        var i = 0
        while i < steps.count {
            let s = steps[i]
            if s.kind == .work, let total = s.repTotal {
                // A rep group (intervals / hills / strides / fartlek surges) → one collapsed line,
                // named by the step's noun, then the recovery once.
                let noun = s.title.map { " \($0.lowercased())s" } ?? ""   // "8 × 45 s hills"
                let pace = s.paceSPerKm.map { "@ \(Formatters.pace(secPerKm: $0, unit: distanceUnit))" } ?? "by feel"
                lines.append(("\(total) × \(Self.targetLabel(s.target, distanceUnit: distanceUnit))\(noun)", pace))
                if i + 1 < steps.count, steps[i + 1].kind == .recovery {
                    let r = steps[i + 1]
                    lines.append((r.title ?? "Recovery", Self.targetLabel(r.target, distanceUnit: distanceUnit)))
                }
                // Skip the whole rep block (this group's work + recovery steps).
                while i < steps.count, steps[i].kind == .work, steps[i].repTotal != nil { i += 1
                    if i < steps.count, steps[i].kind == .recovery { i += 1 }
                }
            } else {
                // A standalone block (warm-up, cool-down, tempo, progression thirds).
                lines.append((s.displayNoun, Self.stepDetail(s, distanceUnit: distanceUnit)))
                i += 1
            }
        }
        return lines
    }

    static func targetLabel(_ t: WorkoutStep.Target, distanceUnit: DistanceUnit) -> String {
        switch t {
        case let .distance(d): return d < 1000 ? "\(Int(d)) m" : Formatters.distance(meters: d, unit: distanceUnit)
        case let .duration(s):
            // Never round a prescription: a 90 s jog must not read "2 min" (the athlete would
            // stand around for 30 phantom seconds). Whole minutes say "min"; short odd durations
            // speak in seconds like a coach ("90 s"); longer ones read as m:ss.
            if s.truncatingRemainder(dividingBy: 60) == 0, s >= 60 { return "\(Int(s / 60)) min" }
            if s < 120 { return "\(Int(s)) s" }
            return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
        }
    }

    static func stepDetail(_ s: WorkoutStep, distanceUnit: DistanceUnit) -> String {
        let base = targetLabel(s.target, distanceUnit: distanceUnit)
        if s.kind == .work, let p = s.paceSPerKm {
            return "\(base) @ \(Formatters.pace(secPerKm: p, unit: distanceUnit))"
        }
        return base
    }
}
