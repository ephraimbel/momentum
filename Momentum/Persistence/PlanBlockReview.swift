import Foundation
import SwiftData

/// The block review: what the athlete actually ran over a rolling block, read from the journal and
/// the plan, handed to `BlockReport` for the words, and posted where they will read it (the coach
/// thread and the inbox) the moment a block is renewed.
///
/// Read-only over the store apart from `post`. The summary is built from the sessions and workouts
/// that fall inside the block's six-week window, the four weeks before it for comparison, and the
/// weekly `FitnessSnapshot` rows for the estimate at the start and the end. When something was
/// never logged the field is nil and the report leaves that line out.
enum PlanBlockReview {
    static func summary(plan: TrainingPlan, in context: ModelContext, today: Date = Date(),
                        calendar: Calendar = .current) -> BlockReport.Summary {
        let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        let snapshots = (try? context.fetch(FetchDescriptor<FitnessSnapshot>(
            sortBy: [SortDescriptor(\.weekStart)]))) ?? []
        return summary(plan: plan, workouts: workouts, snapshots: snapshots, today: today, calendar: calendar)
    }

    static func summary(plan: TrainingPlan, workouts: [Workout], snapshots: [FitnessSnapshot],
                        today: Date = Date(), calendar: Calendar = .current) -> BlockReport.Summary {
        let start = calendar.startOfDay(for: plan.blockStart ?? plan.sessions.map(\.date).min() ?? plan.createdAt)
        let blockEnd = calendar.date(byAdding: .day, value: 7 * PlanEngine.openBlockWeeks, to: start) ?? today
        let end = min(today, blockEnd)
        let lookback = calendar.date(byAdding: .day, value: -28, to: start) ?? start

        let runs = workouts.filter { $0.type.discipline == .running && ($0.gps?.distanceM ?? 0) > 0 }
        let inBlock = runs.filter { $0.startedAt >= start && $0.startedAt < end }
        let before = runs.filter { $0.startedAt >= lookback && $0.startedAt < start }
        let days = max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
        let weeks = max(1.0, min(Double(PlanEngine.openBlockWeeks), Double(days) / 7))
        func total(_ w: [Workout]) -> Double { w.reduce(0) { $0 + ($1.gps?.distanceM ?? 0) } }

        let due = plan.sessions.filter { $0.date >= start && $0.date < end }
        let done = due.filter { $0.status == .completed }.count
        let checkpoint = plan.sessions.first {
            ($0.intervals ?? "").contains("Time trial") && $0.status == .completed && $0.date >= start
        }
        let reading: CheckpointResult.Reading? = {
            guard let checkpoint, let run = checkpoint.completedWorkout else { return nil }
            let testM = PlanEngine.timeTrialDistanceM(intervals: checkpoint.intervals)
                ?? checkpoint.targetDistanceM ?? run.gps?.distanceM ?? 0
            return CheckpointResult.read(workout: run, testDistanceM: testM)
        }()
        let startSnapshot = snapshots.last { $0.weekStart <= start && ($0.p5kEquivSPerKm ?? 0) > 0 }
        let endSnapshot = snapshots.last { ($0.p5kEquivSPerKm ?? 0) > 0 }

        return BlockReport.Summary(
            blockNumber: plan.blockIndex + 1,
            weeklyVolumeM: inBlock.isEmpty ? nil : total(inBlock) / weeks,
            previousWeeklyVolumeM: before.isEmpty ? nil : total(before) / 4,
            longestRunM: inBlock.map { $0.gps?.distanceM ?? 0 }.max(),
            previousLongestRunM: before.map { $0.gps?.distanceM ?? 0 }.max(),
            sessionsPlanned: due.count,
            sessionsDone: done,
            checkpointDistanceM: reading?.distanceM,
            checkpointTimeS: reading?.timeS,
            p5kStartSPerKm: startSnapshot?.p5kEquivSPerKm,
            p5kEndSPerKm: endSnapshot?.p5kEquivSPerKm ?? plan.p5kSPerKm)
    }

    /// Post the review to the coach thread and the inbox, once per block.
    static func post(_ summary: BlockReport.Summary, unit: DistanceUnit, today: Date = Date(),
                     in context: ModelContext) {
        let report = BlockReport.text(summary, unit: unit)
        context.insert(ChatMessage(role: .coach, text: BlockReport.message(summary, unit: unit)))
        AppNotification.post(kind: .coaching, title: "Block \(summary.blockNumber) in review",
                             body: report.lines.first ?? report.next, on: today, in: context,
                             dedupeToken: "block-review-\(summary.blockNumber)", daily: false)
        try? context.save()
    }
}
