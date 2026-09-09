import SwiftUI
import SwiftData

/// High-level preview and durable review use the same week and framework as the live board.
struct AdaptiveWeekView: View {
    @Query(filter: #Predicate<AppNotification> { $0.kindRaw == "coaching" }, sort: \AppNotification.date, order: .reverse) private var updates: [AppNotification]
    let plan: TrainingPlan
    let weekStart: Date
    let unit: DistanceUnit
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Environment(AppRouter.self) private var router
    @State private var error = false
    @State private var appeared = false
    @State private var viewedEvents = Set<String>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { plan.adaptiveState?.calendar ?? .current }
    private var current: DateInterval { AdaptiveTrainingWeek.week(containing: Date(), calendar: calendar) }
    private var future: Bool { weekStart >= current.end }
    private var weekNumber: Int {
        let anchor = AdaptiveTrainingWeek.week(containing: plan.blockStart ?? plan.createdAt, calendar: calendar).start
        return max(1, (calendar.dateComponents([.day], from: anchor, to: weekStart).day ?? 0) / 7 + 1)
    }
    private var sessions: [PlannedSession] {
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        return plan.sessions.filter { $0.date >= weekStart && $0.date < end }
    }
    private var phase: PlanPhase {
        plan.weekPhases.indices.contains(weekNumber - 1)
            ? PlanPhase(rawValue: plan.weekPhases[weekNumber - 1]) ?? .build : .build
    }
    private var review: AdaptivePlanRecord.Review? {
        plan.adaptiveState?.reviews.last { calendar.isDate($0.weekStart, inSameDayAs: weekStart) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(future ? "Week \(weekNumber)" : "Your plan adapts every week")
                    .font(.display(22, weight: .bold)).foregroundStyle(Theme.ink)
                if future {
                    Spacer()
                    Text("PREVIEW").font(.rounded(11, weight: .semibold)).tracking(1)
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.background, in: Capsule())
                }
            }
            if future {
                Text("\(phase.label) · \(dateRange)")
                    .font(.rounded(14, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                Text(phase.intent).font(.rounded(14)).foregroundStyle(Theme.inkSecondary)
                let runs = sessions.filter { $0.discipline == .running }
                let meters = runs.reduce(0) { $0 + ($1.targetDistanceM ?? 0) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Around \(Formatters.distance(meters: meters, unit: unit))")
                        .font(.display(30, weight: .bold)).monospacedDigit()
                    Text("Estimated weekly distance").font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                }.padding(.vertical, 4)
                HStack(alignment: .top, spacing: 24) {
                    previewMetric("Running days", value: String(runs.count))
                    if let long = runs.filter({ $0.runType == .long }).compactMap(\.targetDistanceM).max() {
                        previewMetric("Long-run estimate", value: Formatters.distance(meters: long, unit: unit))
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
                learningPath
                Text("Your workouts take shape as this week approaches, using your training and recovery. These estimates may change.")
                    .font(.rounded(14)).foregroundStyle(Theme.inkSecondary)
            } else if let review {
                Text("Your weekly review").font(.rounded(16, weight: .bold))
                Text(review.summary).font(.rounded(15))
                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                        if visible { logOnce("weekly_review_viewed") }
                    }
                Text(review.explanation).font(.rounded(15)).foregroundStyle(Theme.inkSecondary)
                if let focus = review.focus { Text(focus).font(.rounded(15, weight: .medium)) }
                if let outlook = review.goalOutlook {
                    DisclosureGroup("Your goal outlook") {
                        Text(outlook).font(.rounded(14)).foregroundStyle(Theme.inkSecondary).padding(.top, 8)
                    }
                }
                if !review.changes.isEmpty {
                    DisclosureGroup("What changed") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(review.changes.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.rounded(14)).monospacedDigit()
                            }
                        }.padding(.top, 8)
                        .onScrollVisibilityChange(threshold: 0.5) { visible in if visible { log("plan_adjustment_viewed") } }
                    }
                }
                if review.viewedAt == nil {
                    Button("Explore this week") { markReviewed(review.id) }
                        .buttonStyle(.borderedProminent).tint(Theme.ink).foregroundStyle(Theme.background)
                }
            } else if sessions.isEmpty, weekStart >= current.start {
                Text(plan.raceDate == nil
                     ? "This training block is complete. Review your progress and build your next block from Manage plan."
                     : "There are no sessions scheduled this week. Review your goal and choose what comes next in Manage plan.")
                    .font(.rounded(15)).foregroundStyle(Theme.inkSecondary)
            } else if let state = plan.adaptiveState, state.lastWeekStart < current.start {
                Text("Your last valid plan is saved. Finalize this week using your recent training and check-ins.")
                    .font(.rounded(15)).foregroundStyle(Theme.inkSecondary)
                Button("Finalize this week") {
                    guard let p = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first(where: { $0.plan?.id == plan.id }) else { return }
                    Task {
                        await AdaptivePlanService.prepare(profile: p, services: services, in: context)
                        error = AdaptivePlanService.isDue(plan)
                    }
                }.buttonStyle(.borderedProminent).tint(Theme.ink).foregroundStyle(Theme.background)
            } else {
                Text("Your goal stays the same. Your completed training and recovery shape what comes next. Explore future weeks for a preview of the journey.")
                    .font(.rounded(15)).foregroundStyle(Theme.inkSecondary)
            }
            if let record = plan.adaptiveState, record.requiresRecoveryCheckin {
                Text("Recovery check-in needed. Rest from running while pain, illness or unusual discomfort is present.")
                    .font(.rounded(15, weight: .semibold))
                Button("Symptoms have resolved") {
                    do {
                        try PlanMutation.perform(in: context) { record.requiresRecoveryCheckin = false }
                    } catch { self.error = true }
                }.buttonStyle(.bordered)
                Text("Only check in when symptoms have resolved. This week's prescribed rest remains; use the injury or illness check-in in Manage plan if you need more support.")
                    .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
            }
            DisclosureGroup("Roadmap to your goal") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(plan.weekPhases.enumerated()), id: \.offset) { index, raw in
                        let phase = PlanPhase(rawValue: raw) ?? .build
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(Theme.inkSecondary)
                            Text(phase.label).fontWeight(index == weekNumber - 1 ? .bold : .regular)
                            Spacer()
                            if index == weekNumber - 1 { Text("Viewing").foregroundStyle(Theme.purple) }
                        }.font(.rounded(14))
                    }
                    if let date = plan.raceDate {
                        Text("Goal date · \(date.formatted(.dateTime.month().day().year()))")
                            .font(.rounded(14, weight: .semibold)).monospacedDigit()
                    }
                    Text("The framework includes build, recovery and taper where appropriate. Your goal outlook updates as you log training; a preview is not a guarantee of readiness.")
                        .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                }.padding(.top, 8)
                .onScrollVisibilityChange(threshold: 0.5) { visible in if visible { log("plan_roadmap_viewed") } }
            }
            if !future {
                DisclosureGroup("Coach Updates") {
                    ForEach(Array(updates.prefix(12))) { item in
                        Button {
                            CoachMessageLifecycle.record(item.id, action: .opened, in: context, source: "coach_updates")
                            if let receipt = CoachMessageReceipt.fetch(item.id, in: context) {
                                router.pendingNotificationRoute = CoachMessageLifecycle.route(receipt)
                            } else { router.pendingNotificationRoute = NotificationRouteStore.route(for: item.id) ?? .coach }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.title).font(.rounded(14, weight: .bold))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11))
                                }
                                Text(item.body).font(.rounded(14)).foregroundStyle(Theme.inkSecondary)
                            }.multilineTextAlignment(.leading).padding(.vertical, 8)
                        }.buttonStyle(.plain)
                        .onScrollVisibilityChange(threshold: 0.5) { visible in
                            if visible { CoachMessageLifecycle.record(item.id, action: .displayed, in: context, source: "coach_updates") }
                        }
                    }
                    ForEach((plan.adaptiveState?.reviews ?? []).reversed()) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.weekStart.formatted(.dateTime.month().day())).font(.rounded(14, weight: .bold))
                            Text(item.summary).font(.rounded(14))
                            Text(item.explanation).font(.rounded(14)).foregroundStyle(Theme.inkSecondary)
                        }.padding(.vertical, 8)
                    }
                }
            }
            if error { Text("Couldn't save. Please try again. Rest or gentle mobility is an option while we retry.").font(.rounded(14)) }
        }
        .foregroundStyle(Theme.ink)
        .padding(Theme.Space.md)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { appeared = true }
        }
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            if visible, future { logOnce("future_week_preview_viewed") }
        }
    }
    private var dateRange: String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return weekStart.formatted(.dateTime.month(.abbreviated).day()) + " – " + end.formatted(.dateTime.month(.abbreviated).day())
    }
    private func previewMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.rounded(18, weight: .semibold)).monospacedDigit()
            Text(label).font(.rounded(12)).foregroundStyle(Theme.inkSecondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var learningPath: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                ForEach(Array(["Train", "Check in", "Adapt"].enumerated()), id: \.offset) { index, label in
                    VStack(spacing: 8) {
                        Circle().fill(index == 0 ? Theme.purple : Theme.hairline)
                            .frame(width: 10, height: 10)
                            .scaleEffect(appeared ? 1 : 0.8)
                        Text(label).font(.rounded(12, weight: .semibold))
                    }.frame(maxWidth: .infinity)
                }
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            let thisWeek = plan.sessions.filter { $0.date >= current.start && $0.date < current.end && $0.discipline == .running }
            let done = thisWeek.filter { $0.status == .completed || $0.completedWorkout != nil }.count
            Text("\(done) of \(thisWeek.count) runs completed this week")
                .font(.rounded(14, weight: .medium)).monospacedDigit()
        }.padding(.vertical, 8)
    }

    private func log(_ action: String) {
        services.analytics.log(.adaptive(action: action, week: String(weekNumber), reason: review?.reason ?? "framework", goal: plan.goal))
    }
    private func logOnce(_ action: String) {
        guard viewedEvents.insert("\(weekNumber).\(action)").inserted else { return }
        log(action)
    }
    private func markReviewed(_ id: String) {
        guard let record = plan.adaptiveState else { return }
        do {
            try PlanMutation.perform(in: context) {
                var reviews = record.reviews
                if let i = reviews.firstIndex(where: { $0.id == id }) { reviews[i].viewedAt = Date() }
                record.reviews = reviews
            }
            log("next_week_revealed")
        } catch { self.error = true }
    }
}
