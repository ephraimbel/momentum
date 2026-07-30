import Foundation

/// The chat's small info-card engines — race predictor, today's briefing, and training zones.
/// Each produces `CoachSection`s computed entirely from the athlete's own data via the existing
/// deterministic engines (Daniels/VDOT, StructuredWorkoutBuilder, HRZones, FuelingGuide). The AI
/// never invents a number; these cards ARE the numbers.

// MARK: - "What could I race right now?"

@MainActor
enum CoachRacePredictor {

    static func sections(profile: UserProfile) -> [CoachSection] {
        guard let plan = profile.plan, plan.p5kSPerKm > 0 else { return [] }
        let unit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto
        // ONE prediction model everywhere: `RacePredictor` (Riegel + a single endurance tax) is
        // what Progress and the plan's race cards show — the coach must quote the same numbers.
        // This card used to derive finish times from the Daniels VDOT pace curve and then tax
        // them: the curve already decays with duration, so the long day was penalized twice and
        // the coach's 50K ran ~13 min slower than the identical athlete's Progress prediction
        // (owner caught the mismatch 2026-07-30).
        var out: [CoachSection] = RaceDistance.allCases.compactMap { race in
            guard let finish = RacePredictor.finishTimeS(raceDistanceM: race.meters,
                                                         p5kSPerKm: plan.p5kSPerKm),
                  let pace = RacePredictor.projectedPaceSPerKm(raceDistanceM: race.meters,
                                                               p5kSPerKm: plan.p5kSPerKm)
            else { return nil }
            return CoachSection(icon: "flag.checkered", title: race.label,
                                detail: "\(PlanFeasibility.hms(finish)) at \(Formatters.pace(secPerKm: pace, unit: unit))")
        }
        // The ultra number deserves its own honesty: the prediction already carries the endurance
        // tax for the long day, but real ultras add what no equation sees.
        if RaceDistance.allCases.contains(where: { $0.meters > 42_195 }) {
            out.append(CoachSection(icon: "mountain.2", title: "About the ultra number",
                                    detail: "The 50K already includes the endurance tax for hours on your feet — and real ultras add terrain, aid stops, and fueling on top. Treat it as a flat-road ceiling, not a target."))
        }
        out.append(CoachSection(icon: "sparkles", title: "How to read this",
                                detail: "Equivalent race times from your calibrated fitness today, not a promise. Run a strong workout and these sharpen on their own."))
        return out
    }
}

// MARK: - "Brief me on today"

@MainActor
enum CoachTodayBriefing {

    static func sections(profile: UserProfile, today: Date = Date(),
                         calendar: Calendar = .current) -> [CoachSection] {
        let unit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto
        guard let session = PlanCoaching.todaySessions(profile.plan, on: today, calendar: calendar)
            .first(where: { $0.status != .completed }) else {
            // A rest day is a coached day too — say what it's for and what's next.
            var out = [CoachSection(icon: "moon.zzz", title: "Rest day",
                                    detail: "Nothing on the plan today. Rest is where the training lands, so take it seriously.")]
            if let next = profile.plan?.sessions
                .filter({ $0.status == .planned && $0.date > calendar.startOfDay(for: today) })
                .min(by: { $0.date < $1.date }) {
                out.append(CoachSection(icon: "arrow.right", title: "Up next",
                                        detail: "\(PlanCoaching.brief(for: next, distanceUnit: unit)) on \(next.date.formatted(.dateTime.weekday(.wide)))."))
            }
            return out
        }

        var out: [CoachSection] = [
            CoachSection(icon: PlanCoaching.icon(for: session), title: "The session",
                         detail: PlanCoaching.brief(for: session, distanceUnit: unit)
                            + (session.rationale.map { " \($0)" } ?? "")),
        ]

        // The guided structure, step by step (quality sessions only — easy runs need no script).
        if let structured = StructuredWorkoutBuilder.build(from: session, p5kSPerKm: profile.plan?.p5kSPerKm,
                                                           raceDistanceM: profile.raceDistanceM) {
            out.append(CoachSection(icon: "list.number", title: "How it runs",
                                    detail: stepSummary(structured, unit: unit)))
        }

        // Where the heart should sit.
        if let runType = session.runType,
           let target = HRZones.target(for: runType, maxHR: profile.maxHR, restingHR: profile.restingHR) {
            out.append(CoachSection(icon: "heart", title: "Effort", detail: target))
        }

        // Fueling, when the session is long enough to need it.
        if let duration = FuelingGuide.estimatedDurationS(distanceM: session.targetDistanceM,
                                                          paceSPerKm: session.targetPaceSPerKm,
                                                          durationS: session.targetDurationS),
           duration >= 3600 {
            let fueling = FuelingGuide.guidance(durationS: duration)
            out.append(CoachSection(icon: "takeoutbag.and.cup.and.straw", title: "Fueling",
                                    detail: fueling.before))
        }

        return out
    }

    /// "1 km warm up → 6× 400 m @ 4:10 /km with recoveries → 1 km cool down" — the script in one line.
    private static func stepSummary(_ workout: StructuredWorkout, unit: DistanceUnit) -> String {
        var parts: [String] = []
        var repsDescribed = false
        for step in workout.steps {
            switch step.kind {
            case .warmup, .cooldown:
                parts.append("\(target(step, unit: unit)) \(step.kindLabel.lowercased())")
            case .work:
                if let total = step.repTotal {
                    guard !repsDescribed else { continue }   // describe the rep group once
                    repsDescribed = true
                    var line = "\(total)× \(target(step, unit: unit))"
                    if let pace = step.paceSPerKm { line += " @ \(Formatters.pace(secPerKm: pace, unit: unit))" }
                    line += " with recoveries"
                    parts.append(line)
                } else {
                    var line = target(step, unit: unit)
                    if let pace = step.paceSPerKm { line += " @ \(Formatters.pace(secPerKm: pace, unit: unit))" }
                    parts.append(line)
                }
            case .recovery:
                continue   // folded into "with recoveries"
            }
        }
        return parts.joined(separator: " → ")
    }

    private static func target(_ step: WorkoutStep, unit: DistanceUnit) -> String {
        switch step.target {
        case .distance(let m): Formatters.distance(meters: m, unit: unit)
        case .duration(let s): Formatters.duration(s: s)
        }
    }
}

// MARK: - "What are my zones?"

@MainActor
enum CoachZones {

    static func sections(profile: UserProfile) -> [CoachSection] {
        var out: [CoachSection] = []

        if let maxHR = profile.maxHR, let zones = HRZones.zones(maxHR: maxHR, restingHR: profile.restingHR) {
            for zone in zones {
                out.append(CoachSection(icon: "heart", title: "\(zone.label) · \(zone.name)",
                                        detail: "\(zone.bpm.lowerBound)–\(zone.bpm.upperBound) bpm. \(zone.purpose)."))
            }
        } else {
            out.append(CoachSection(icon: "heart", title: "Heart rate zones",
                                    detail: "Add your max heart rate in your profile and I'll compute your five zones."))
        }

        if let plan = profile.plan, plan.p5kSPerKm > 0 {
            let unit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto
            func pace(_ type: RunType) -> String {
                Formatters.pace(secPerKm: DanielsPaces.trainingPace(type, p5kSPerKm: plan.p5kSPerKm), unit: unit)
            }
            out.append(CoachSection(icon: "speedometer", title: "Training paces",
                                    detail: "Easy \(pace(.easy)) · Long \(pace(.long)) · Tempo \(pace(.tempo)) · Intervals \(pace(.intervals)). All from your calibrated fitness."))
        }

        return out
    }
}
