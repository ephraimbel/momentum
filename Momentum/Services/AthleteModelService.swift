import Foundation
import SwiftData

/// Live Athlete Model service (Phase 2, `docs/ATHLETE-MODEL.md` §6, step [1]). Recomputes the
/// deterministic Tier A facts on each finished workout and persists them onto the profile's
/// `AthleteModel`, upserting a weekly `FitnessSnapshot`. Fully local and synchronous — the model
/// deepens even offline; nothing here touches the network.
@MainActor
final class AthleteModelService: AthleteModelServing {

    func ingest(profile: UserProfile, in context: ModelContext, now: Date) {
        let facts = AthleteModelEngine(workouts: profile.workouts, plan: profile.plan, now: now).facts

        let model = profile.athlete ?? {
            let m = AthleteModel()
            context.insert(m)
            profile.athlete = m
            return m
        }()

        apply(facts, to: model)
        upsertSnapshot(for: profile, facts: facts, now: now, into: model)
        model.updatedAt = now
        try? context.save()
    }

    /// The profile's model, created and attached on first use.
    private func model(for profile: UserProfile, in context: ModelContext) -> AthleteModel {
        if let m = profile.athlete { return m }
        let m = AthleteModel()
        context.insert(m)
        profile.athlete = m
        return m
    }

    func addCorrection(_ text: String, category: MemoryCategory, for profile: UserProfile, in context: ModelContext) {
        guard let clean = MemoryConsolidation.clean(text) else { return }
        let m = model(for: profile, in: context)
        // One active pinned correction per category — replace if it exists.
        if let existing = m.notes.first(where: {
            $0.isActive && $0.pinned && $0.source == MemorySource.user.rawValue && $0.category == category.rawValue
        }) {
            existing.text = clean
            existing.updatedAt = Date()
        } else {
            let note = MemoryNote()
            note.category = category.rawValue
            note.text = clean
            note.source = MemorySource.user.rawValue
            note.confidence = Confidence.confident.rawValue
            note.pinned = true
            note.isActive = true
            context.insert(note)
            m.notes.append(note)
        }
        try? context.save()
    }

    func forget(noteID: UUID, in context: ModelContext) {
        let notes = (try? context.fetch(FetchDescriptor<MemoryNote>())) ?? []
        guard let note = notes.first(where: { $0.id == noteID }) else { return }
        note.isActive = false
        note.updatedAt = Date()
        try? context.save()
    }

    func seedOnboarding(for profile: UserProfile, in context: ModelContext) {
        let model = self.model(for: profile, in: context)
        // Idempotent: don't re-seed if onboarding notes already exist.
        guard !model.notes.contains(where: { $0.source == MemorySource.onboarding.rawValue }) else { return }

        var seeded: [MemoryNote] = []
        let identity = MemoryNote()
        identity.category = MemoryCategory.identity.rawValue
        identity.text = Self.identitySeed(profile)
        identity.source = MemorySource.onboarding.rawValue
        identity.confidence = Confidence.emerging.rawValue
        seeded.append(identity)

        let motivation = MemoryNote()
        motivation.category = MemoryCategory.motivation.rawValue
        motivation.text = Self.motivationSeed(profile.reason)
        motivation.source = MemorySource.onboarding.rawValue
        motivation.confidence = Confidence.emerging.rawValue
        seeded.append(motivation)

        for note in seeded { context.insert(note) }
        model.notes.append(contentsOf: seeded)
        try? context.save()
    }

    // MARK: - Tier A apply

    private func apply(_ f: AthleteFacts, to m: AthleteModel) {
        m.trainingHourHistogram = f.trainingHourHistogram
        m.weekdayHistogram = f.weekdayHistogram
        m.medianSessionMinutes = f.medianSessionMinutes
        m.preferredSessionMinutes = f.preferredSessionMinutes
        m.planAdherence28d = f.planAdherence28d
        m.movedSessionRate28d = f.movedSessionRate28d
        m.disciplineShare = f.disciplineShare
        m.disciplineTrend = f.disciplineTrend
        m.paceAtEffortTrendPct = f.paceAtEffortTrendPct
        m.e1rmTrendByExercise = f.e1rmTrendByExercise
        m.weeklyVolumeTrendPct = f.weeklyVolumeTrendPct
        m.currentACWR = f.currentACWR
        m.overreachThresholdACWR = f.overreachThresholdACWR
        m.typicalRecoveryDays = f.typicalRecoveryDays
        m.prCountByMonth = f.prCountByMonth
        m.lastPRAt = f.lastPRAt
        m.frequencyTrend28d = f.frequencyTrend28d
        m.consecutiveMissed = f.consecutiveMissed
        m.signalSampleCounts = f.signalSampleCounts
    }

    // MARK: - Weekly snapshot

    private func upsertSnapshot(for profile: UserProfile, facts: AthleteFacts,
                                now: Date, into model: AthleteModel) {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)

        let insights = ProgressInsights(workouts: profile.workouts, now: now)
        let thisWeek = insights.weeks.last

        let snapshot = model.snapshots.first { cal.isDate($0.weekStart, equalTo: weekStart, toGranularity: .day) }
            ?? {
                let s = FitnessSnapshot()
                s.weekStart = weekStart
                model.snapshots.append(s)
                return s
            }()

        snapshot.weeklyLoad = thisWeek?.load ?? 0
        snapshot.weeklyDistanceM = thisWeek?.distanceM ?? 0
        snapshot.acwr = facts.currentACWR
        snapshot.p5kEquivSPerKm = profile.plan?.p5kSPerKm
        snapshot.topE1RMByLift = Self.topE1RMByLift(profile.workouts, now: now, calendar: cal)
    }

    /// Best e1RM per lift over the trailing 56 days — the strength markers for the snapshot.
    private static func topE1RMByLift(_ workouts: [Workout], now: Date, calendar: Calendar) -> [String: Double] {
        guard let cut = calendar.date(byAdding: .day, value: -56, to: now) else { return [:] }
        var best: [String: Double] = [:]
        for w in workouts where w.type == .strength && w.startedAt >= cut {
            guard let s = w.strength else { continue }
            for row in s.exercises {
                guard let name = row.exercise?.name else { continue }
                for set in row.sets where set.isComplete && set.type == .working {
                    guard let kg = set.weightKg, let reps = set.reps else { continue }
                    best[name] = max(best[name] ?? 0, StrengthMath.e1RM(weightKg: kg, reps: reps))
                }
            }
        }
        return best
    }

    // MARK: - Onboarding seed copy

    static func identitySeed(_ profile: UserProfile) -> String {
        let disciplines = Set(profile.disciplines)
        let lifts = disciplines.contains(Discipline.strength.rawValue)
        let runs = disciplines.contains(Discipline.running.rawValue)
        let rides = disciplines.contains(Discipline.cycling.rawValue)
        let noun: String
        switch (runs, lifts, rides) {
        case (true, true, _): noun = "hybrid athlete"
        case (true, false, _): noun = "runner"
        case (false, true, _): noun = "lifter"
        case (false, false, true): noun = "cyclist"
        default: noun = "mover"
        }
        let level = profile.experience.values.first
        let levelWord: String
        switch level {
        case ExperienceLevel.new.rawValue: levelWord = "A new"
        case ExperienceLevel.experienced.rawValue: levelWord = "A seasoned"
        default: levelWord = "A"
        }
        return "\(levelWord) \(noun) just getting started with Momentum."
    }

    static func motivationSeed(_ reason: String) -> String {
        switch reason.lowercased() {
        case let r where r.contains("clear") || r.contains("head"): return "You train to clear your head."
        case let r where r.contains("look"): return "You're training to look and feel your best."
        case let r where r.contains("compete") || r.contains("race"): return "You're chasing a finish line."
        case let r where r.contains("me") || r.contains("time"): return "This is your time, just for you."
        default: return "You're here for your health — the long game."
        }
    }
}
