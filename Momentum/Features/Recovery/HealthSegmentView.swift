import SwiftUI
import SwiftData
import HealthKit

/// The Progress → Health segment (docs/RECOVERY-HUB-PLAN.md §5, §8, §11) — the morning score's
/// home, where the invisible guardian becomes visible. Renders §5's order top to bottom:
///
///   free  — `ReadinessHeroCard` (the honest 0–100 ring) and `DriverRow` (today's pillars + the
///           live `RecoveryAdaptation` readout), plus the `ConnectRow` acquisition hook when
///           Health isn't authorized; then the glance layer §8 never paywalls — `SleepCard`
///           (last night's duration + stage bar) and `VitalsBoard` (each vital's latest value
///           in words), each gating its own depth internals on `isPro`;
///   Pro   — ONE depth cluster behind a single `.proLocked(.advancedAnalytics)` (§8, the shipped
///           one-unlock-opens-the-page convention): `BalanceCard`, `RhythmCard`, and the
///           adaptation timeline;
///   free  — `LearnCard` (education is always free).
///
/// Everything numeric is computed OFF the render path in `Model.build()` (the ProTrendsSection
/// pattern — plan risk #3): Health day-bucketed history + per-day engine runs land in one hop via
/// `.task(id:)`, keyed on day + data counts, and the body only lays out. Inputs (`workouts`,
/// `plan`, `checkins`, `events`, `profile`) arrive as parameters — the hosting view passes its
/// `@Query` results; `HealthService` arrives through the `Services` environment. Zero-data charts
/// render as designed specimens (§5 — day one already looks like the product); Reduce Motion
/// collapses the 70ms reveal cascade to a plain fade.
@MainActor
struct HealthSegmentView: View {
    let workouts: [Workout]
    var plan: TrainingPlan? = nil
    var checkins: [DailyCheckin] = []
    var events: [CoachingEvent] = []
    var profile: UserProfile? = nil
    /// The host's scroll proxy (the segment lives inside Progress's ScrollView) — DriverRow chips
    /// scroll to their card through it. Optional: without one, chips simply don't navigate.
    var scrollProxy: ScrollViewProxy? = nil

    @Environment(Services.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var context   // week-guard proposal seeds (ChatMessage inserts)
    @State private var model: Model?
    @State private var connecting = false
    @State private var showCheckin = false
    @State private var showInjuryReport = false
    @State private var refresh = 0
    /// The sleep nights section's tap-through (the vitals board hosts its own).
    @State private var sleepDetail: TrendDetail?
    /// Session cache: Progress's `switch segment` destroys this view — and its `@State model` —
    /// on every segment flip, so each re-entry re-paid the skeleton + the full HealthKit + per-day
    /// engine pipeline. A same-key hit remounts instantly; HK data that syncs in late (sleep, HRV)
    /// still lands via the aged-cache background refresh below. Pure value types only.
    @MainActor private static var cache: (key: String, builtAt: Date, model: Model)?
    /// How old the cached model may grow before a re-entry quietly rebuilds behind it. Short
    /// enough that a post-sync visit feels fresh, long enough that segment flicking is free.
    private static let staleAfter: TimeInterval = 180
    /// A harness-injected model never recomputes (no Health reads, no SwiftData).
    private var isStatic = false

    init(workouts: [Workout],
         plan: TrainingPlan? = nil,
         checkins: [DailyCheckin] = [],
         events: [CoachingEvent] = [],
         profile: UserProfile? = nil,
         scrollProxy: ScrollViewProxy? = nil) {
        self.workouts = workouts
        self.plan = plan
        self.checkins = checkins
        self.events = events
        self.profile = profile
        self.scrollProxy = scrollProxy
    }

    #if DEBUG
    /// Harness entry — renders a prebuilt model with no Health/SwiftData dependency, so the full
    /// segment screenshots before ProgressView integration (the `--recovery-lab` pattern lands
    /// with integration; this is what it will host).
    init(demo model: Model, scrollProxy: ScrollViewProxy? = nil) {
        workouts = []
        self.scrollProxy = scrollProxy
        _model = State(initialValue: model)
        isStatic = true
    }
    #endif

    private var pro: Bool { services.paywall.isEntitled(to: .advancedAnalytics) }

    /// Recompute on a new local day, a workout/check-in/adaptation landing, or a manual refresh
    /// (post-connect) — the plan's "keyed on day + workout count" rule, plus the two inputs that
    /// change the morning readout (TodayView recomputes on the same events).
    private var taskKey: String {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        return "\(day)-\(workouts.count)-\(checkins.count)-\(events.count)-\(refresh)-\(pro)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let model {
                content(model)
            } else {
                skeleton
            }
        }
        .task(id: taskKey) {
            guard !isStatic else { return }
            // Cache-and-refresh (never plain skip — this rebuild is the segment's only HK
            // freshness path): a same-key hit renders instantly with no skeleton; if the cache
            // is fresh we stop there, otherwise the pipeline re-runs quietly BEHIND the
            // rendered model and swaps in when done.
            if let cached = Self.cache, cached.key == taskKey {
                if model == nil { model = cached.model }
                if Date().timeIntervalSince(cached.builtAt) < Self.staleAfter { return }
            }
            if model == nil { await Task.yield() }   // let the first frame paint the skeleton
            let intensity = PlanIntensity(rawValue: profile?.planIntensity ?? "") ?? .balanced
            var built = await Model.build(workouts: workouts, plan: plan, checkins: checkins,
                                          events: events, health: services.health,
                                          intensity: intensity, pro: pro)
            // Race-day Form projection (§11.1.2) — pure, cheap, dated-race plans only.
            built.raceProjection = RaceProjection.build(workouts: workouts, plan: plan)
            model = built
            Self.cache = (taskKey, Date(), built)
            // One number everywhere: publish today's full-blend score so the Trends strip and the
            // athlete-panel rail show exactly what the hero shows (never the light fallback again).
            if let r = built.readiness {
                ReadinessTodayCache.store(score: r.score, band: r.band.rawValue,
                                          driver: r.displayDriverLine)
            }
            // Week guard (§11.1.4): a week of poor recovery at normal load raises ONE consent-gated
            // ease proposal (deduped upstream; never auto-applies, never stacks with autoAdapt).
            _ = CoachProactive.seedOverreachingEase(state: built.balanceWeek.state,
                                                    plan: plan, in: context)
            // No automatic workout import (user call 2026-07-24): Apple Health workouts never stream
            // in on their own — the log is only what the athlete does in the app. Their back-catalog
            // (and any Watch/Garmin runs they want pulled in) is an explicit Settings → Import action.
        }
        .sheet(isPresented: $showCheckin) {
            // The check-in saves through its own model context; the host's @Query then feeds a
            // fresh `checkins` array back in and the task recomputes. "Something hurts" keeps
            // its promise here exactly like Today: the 0.35s beat lets the check-in sheet
            // finish dismissing before the injury sheet presents (a bare onPain: {} shipped a
            // haptic-then-nothing on an injury-reporting door — audit 2026-07-16).
            CheckinSheet(profile: profile, onPain: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showInjuryReport = true }
            })
        }
        .sheet(isPresented: $showInjuryReport) {
            InjuryReportSheet(profile: profile)
        }
        .sheet(item: $sleepDetail) { TrendDetailSheet(detail: $0) }
    }

    // MARK: Layout (§5 order, 70ms reveal cascade)

    @ViewBuilder
    private func content(_ model: Model) -> some View {
        let onSelect: ((MorningReadiness.PillarKind) -> Void)? =
            scrollProxy == nil ? nil : { scroll(to: $0) }

        ReadinessHeroCard(readiness: model.readiness,
                          weekScores: model.weekScores,
                          isPro: pro,
                          onCheckin: { showCheckin = true })
            .id(Anchor.hero)
            .reveal(0)

        DriverRow(pillars: model.readiness?.pillars ?? [],
                  modifiers: model.readiness?.modifiers ?? [],
                  readout: model.readout,
                  acwr: model.acwr,
                  timeline: [],                       // the history trail is Pro — it lives below
                  onSelectPillar: onSelect)
            .reveal(0.07)

        if !model.healthAuthorized {
            ConnectRow(connecting: connecting, onConnect: connect)
                .reveal(0.14)
        }

        // The glance layer stays free (§8 — you never pay to see your own body): last night's
        // sleep and each vital's latest value render for everyone; the cards gate their own
        // depth internals (night columns, debt area, sparklines, ribbons) on `isPro`.
        sleepSection(model)
            .id(Anchor.sleep)
            .reveal(model.healthAuthorized ? 0.14 : 0.21)

        VitalsBoard(tiles: model.vitals,
                    isPro: pro,
                    // The segment-level ConnectRow above owns the connect ask — one connect
                    // affordance, never two, so the board never shows its own.
                    onConnect: nil,
                    history: vitalHistory)
            .id(Anchor.vitals)
            .reveal(model.healthAuthorized ? 0.21 : 0.28)

        proCluster(model)
            .proLocked(.advancedAnalytics)
            .reveal(model.healthAuthorized ? 0.28 : 0.35)

        LearnCard()
            .reveal(model.healthAuthorized ? 0.35 : 0.42)

        // The honest source line, always last and always visible. It reads as provenance once
        // signal is actually arriving, and as the hardware requirement when it isn't — so a
        // connected athlete is never told to connect something.
        WearableFootnote(receivingData: model.sleepReport != nil
                         || model.vitals.contains { $0.hasAnyData })
            .reveal(model.healthAuthorized ? 0.42 : 0.49)
    }

    /// The depth layer (§8): one VStack, one lock — the trends and the synthesis only.
    /// Balance history, weekly rhythm, and the adaptation receipts; the sleep/vitals glance
    /// cards render free above.
    private func proCluster(_ model: Model) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            balanceSection(model).id(Anchor.balance)
            rhythmSection(model).id(Anchor.rhythm)
            AdaptationTimelineCard(entries: model.timeline)
        }
    }

    @ViewBuilder
    private func balanceSection(_ model: Model) -> some View {
        if model.hasBalanceData {
            BalanceCard(week: model.balanceWeek, month: model.balanceMonth,
                        ghostBars: model.ghostBars, chronicLoad: model.chronicLoad)
        } else {
            BalanceCard(week: Specimen.balanceWeek, month: Specimen.balanceMonth)
                .specimen("A few tracked days draw your strain and recovery as one picture — recovery holding above strain is the pattern you want.")
        }
        // The taper, verified (§11.1.2): projected race-day Form from actual + planned loads.
        if let projection = model.raceProjection {
            RaceReadinessCard(projection: projection)
        }
    }

    @ViewBuilder
    private func sleepSection(_ model: Model) -> some View {
        if let report = model.sleepReport {
            SleepCard(report: report, nights: model.sleepNights, debt: model.sleepDebt, isPro: pro,
                      onOpenNights: { sleepDetail = sleepTrendDetail })
        } else if let demo = Specimen.sleep {
            // Specimen nights are canned — no tap-through into a window that would come back empty.
            SleepCard(report: demo.report, nights: demo.nights, debt: demo.debt, isPro: pro)
                .specimen("Sleep lands here through Apple Health — a watch worn overnight adds the stage breakdown.")
        }
    }

    /// The nights section's tap-through: nightly hours over month-to-year windows, straight from
    /// the service (weekly means beyond ~5 weeks so a year never becomes 365 slivers). The axis
    /// floor mirrors the card's own rule — never below 8h, so a short stretch doesn't dramatize.
    private var sleepTrendDetail: TrendDetail {
        let health = services.health
        return TrendDetail(
            id: "sleep-duration",
            title: "Sleep duration",
            unit: "h",
            stats: [.average, .best, .latest],
            minimumYTop: 8,
            tint: Theme.Health.sleepInk,
            explainer: MetricExplainers.sleepDuration,
            format: { String(format: "%.1f", $0) },
            series: { weeks in
                guard let concrete = health as? HealthService else { return [] }
                let calendar = Calendar.current
                // Two records on one morning: keep the longer night (the card's merge rule).
                var byDay: [Date: Double] = [:]
                for night in await concrete.sleepNights(days: weeks * 7) {
                    let key = calendar.startOfDay(for: night.date)
                    byDay[key] = max(byDay[key] ?? 0, night.asleepH)
                }
                let points = byDay.map { TrendDetail.Point(date: $0.key, value: $0.value) }
                    .sorted { $0.date < $1.date }
                return weeks <= 5 ? points : TrendDetail.weeklyAverages(points, calendar: calendar)
            })
    }

    /// Day-bucketed long-window history per vital — the board's tap-through fetcher. Stubbed
    /// services (previews, tests) return nothing; the board falls back to the tile's spark.
    private func vitalHistory(_ kind: VitalTileModel.Kind, days: Int) async -> [(day: Date, value: Double)] {
        guard let concrete = services.health as? HealthService else { return [] }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        switch kind {
        case .hrv:
            return await concrete.hrvDailyHistory(days: days)
        case .restingHR:
            return await concrete.dailyHistory(.restingHeartRate, unit: bpm, days: days)
        case .respiratory:
            return await concrete.dailyHistory(.respiratoryRate, unit: bpm, days: days)
        case .wristTemp:
            return await concrete.dailyHistory(.appleSleepingWristTemperature, unit: .degreeCelsius(), days: days)
        case .walkingHR:
            return await concrete.dailyHistory(.walkingHeartRateAverage, unit: bpm, days: days)
        }
    }

    @ViewBuilder
    private func rhythmSection(_ model: Model) -> some View {
        if model.hasRhythmData {
            // lastWeekBalanced gates the §6 balanced-week shimmer; `pro` keeps a ProLock-blurred
            // appearance from burning the one-time week key invisibly.
            RhythmCard(days: model.rhythmDays, monotony: model.monotony,
                       lastWeekBalanced: pro && model.balanceWeek.state == .balanced)
        } else {
            RhythmCard(days: Specimen.rhythmDays, monotony: nil)
                .specimen("Four weeks of training paint your rhythm — hard days hard, easy days easy, rest days worn proudly.")
        }
    }

    /// Warmup skeleton while the model resolves (one hop) — mirrors ProTrendsSection's.
    private var skeleton: some View {
        VStack(spacing: Theme.Space.md) {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                .frame(height: 340)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    .frame(height: 140)
            }
        }
        .redacted(reason: .placeholder)
    }

    // MARK: Actions

    private func connect() {
        guard !connecting else { return }
        connecting = true
        Task {
            _ = await services.health.requestAuthorization()
            // Connecting grants recovery signals + live HR — it does NOT pull in the athlete's
            // workout history (user call 2026-07-24). Apple Health workouts never auto-populate the
            // log; the back-catalog is an explicit Settings → Import from Apple Health action.
            connecting = false
            refresh += 1   // new task key → rebuild off the fresh grant
        }
    }

    /// Driver chips scroll to the card that explains them (§5 row 2).
    private func scroll(to kind: MorningReadiness.PillarKind) {
        let anchor: Anchor = switch kind {
        case .sleep:            .sleep
        case .hrv, .restingHR:  .vitals
        case .load:             .balance
        case .checkin:          .hero
        }
        if reduceMotion {
            scrollProxy?.scrollTo(anchor, anchor: .top)
        } else {
            withAnimation(Motion.standard) { scrollProxy?.scrollTo(anchor, anchor: .top) }
        }
    }

    /// Stable scroll anchors for the driver chips.
    private enum Anchor: String, Hashable {
        case hero = "health.hero"
        case balance = "health.balance"
        case sleep = "health.sleep"
        case vitals = "health.vitals"
        case rhythm = "health.rhythm"
    }
}

// MARK: - Model (everything computed off the render path)

extension HealthSegmentView {
    /// The whole segment's data, built once per task key. Pure card inputs — the body computes
    /// nothing but layout.
    struct Model {
        // Free glance layer
        var readiness: MorningReadiness?
        var weekScores: [Int?] = []
        var readout: DriverRow.Readout = .allClear
        var acwr: Double = 0
        var healthAuthorized = false

        // Pro depth layer
        var balanceWeek: StrainRecoveryBalance
        var balanceMonth: StrainRecoveryBalance
        var ghostBars: [(date: Date, estLoad: Double)] = []
        var chronicLoad: Double = 30
        var hasBalanceData = false
        var sleepReport: SleepReport?
        var sleepNights: [SleepReport.Night] = []
        var sleepDebt: [SleepCard.DebtPoint] = []
        var vitals: [VitalTileModel] = []
        var rhythmDays: [RhythmCard.Day] = []
        var hasRhythmData = false
        var monotony: Double?
        /// Race-day Form projection (§11.1.2) — non-nil only with a dated race ≥3 days out.
        var raceProjection: RaceProjection.Projection? = nil
        var timeline: [DriverRow.TimelineEntry] = []

        /// Builds the segment. The heavy work — Health history queries and the per-day engine
        /// runs behind the 30-day readiness/strain series — happens here, awaited off the first
        /// frame. When the depth layer is locked (`pro == false`) the per-day history pipeline is
        /// skipped entirely (the ProTrendsSection rule: never compute what a blurred section
        /// can't show); the free glance layer — hero/driver read, last night's sleep report, and
        /// each vital's latest — still builds in full (§8: never paywalled).
        @MainActor
        static func build(workouts: [Workout],
                          plan: TrainingPlan?,
                          checkins: [DailyCheckin],
                          events: [CoachingEvent],
                          health: any HealthServing,
                          intensity: PlanIntensity,
                          pro: Bool,
                          now: Date = Date(),
                          calendar: Calendar = .current) async -> Model {
            let today = calendar.startOfDay(for: now)
            let bpm = HKUnit.count().unitDivided(by: .minute())
            func day(_ ago: Int) -> Date? { calendar.date(byAdding: .day, value: -ago, to: today) }

            // ── Health reads: the live morning signals + the day-bucketed histories (P1 APIs).
            // The history queries live on the concrete service; a stubbed HealthServing (previews,
            // tests) degrades to signals-only, exactly like an unauthorized device.
            let signals = await health.recoverySignals()
            let concrete = health as? HealthService

            var hrvHist: [(day: Date, value: Double)] = []
            var rhrHist: [(day: Date, value: Double)] = []
            var respHist: [(day: Date, value: Double)] = []
            var tempHist: [(day: Date, value: Double)] = []
            var walkHist: [(day: Date, value: Double)] = []
            var rawNights: [SleepNight] = []
            if let concrete {
                hrvHist = await concrete.hrvDailyHistory(days: HealthBaselines.Window.hrv)
                rhrHist = await concrete.dailyHistory(.restingHeartRate, unit: bpm,
                                                      days: HealthBaselines.Window.restingHR)
                respHist = await concrete.dailyHistory(.respiratoryRate, unit: bpm,
                                                       days: HealthBaselines.Window.respiratoryRate)
                tempHist = await concrete.dailyHistory(.appleSleepingWristTemperature, unit: .degreeCelsius(),
                                                       days: HealthBaselines.Window.wristTemperature)
                walkHist = await concrete.dailyHistory(.walkingHeartRateAverage, unit: bpm,
                                                       days: HealthBaselines.Window.walkingHR)
                rawNights = await concrete.sleepNights(days: 60)
            }

            // ── Baselines (learned norms — every "vs your normal" reads through these).
            let hrvBase = HealthBaselines.build(from: hrvHist, windowDays: HealthBaselines.Window.hrv,
                                                now: now, calendar: calendar)
            let rhrBase = HealthBaselines.build(from: rhrHist, windowDays: HealthBaselines.Window.restingHR,
                                                now: now, calendar: calendar)
            let respBase = HealthBaselines.build(from: respHist, windowDays: HealthBaselines.Window.respiratoryRate,
                                                 now: now, calendar: calendar)
            let tempBase = HealthBaselines.build(from: tempHist, windowDays: HealthBaselines.Window.wristTemperature,
                                                 now: now, calendar: calendar)
            let walkBase = HealthBaselines.build(from: walkHist, windowDays: HealthBaselines.Window.walkingHR,
                                                 now: now, calendar: calendar)

            // ── Sleep: the service nights become engine nights (the outer sleep window isn't in
            // the service's night shape yet, so midpoint drift stays honestly nil — "learning
            // your rhythm" — until that read lands).
            let nights = rawNights.map {
                SleepReport.Night(date: $0.date, asleepH: $0.asleepH, coreS: $0.coreS,
                                  deepS: $0.deepS, remS: $0.remS, awakeS: $0.awakeS, inBedS: $0.inBedS)
            }
            let sleepReport = SleepReport.build(from: nights, now: now, calendar: calendar)
            /// Learned need + running 14-day debt as of a given morning (defaults when no nights).
            func sleepContext(asOf date: Date) -> (need: Double, debt: Double) {
                guard let r = SleepReport.build(from: nights, now: date, calendar: calendar) else {
                    return (8.0, 0)
                }
                return (r.needH, r.debt14H)
            }

            // ── Per-day lookups.
            var hrvByDay: [Date: Double] = [:]
            for entry in hrvHist { hrvByDay[calendar.startOfDay(for: entry.day)] = entry.value }
            var rhrByDay: [Date: Double] = [:]
            for entry in rhrHist { rhrByDay[calendar.startOfDay(for: entry.day)] = entry.value }
            var walkByDay: [Date: Double] = [:]
            for entry in walkHist { walkByDay[calendar.startOfDay(for: entry.day)] = entry.value }
            var nightByDay: [Date: SleepReport.Night] = [:]
            for night in nights {
                let key = calendar.startOfDay(for: night.date)
                if let existing = nightByDay[key], existing.asleepH >= night.asleepH { continue }
                nightByDay[key] = night
            }
            var workoutsByDay: [Date: [Workout]] = [:]
            for w in workouts { workoutsByDay[calendar.startOfDay(for: w.startedAt), default: []].append(w) }

            // ── Fitness curve: CTL per day scales strain; its 7-day change guards the taper.
            let ff = TrendAnalytics.fitnessFreshness(workouts: workouts, now: now, calendar: calendar)
            var ctlByDay: [Date: Double] = [:]
            for point in ff { ctlByDay[calendar.startOfDay(for: point.date)] = point.ctl }
            let ctlToday = ff.last?.ctl ?? 0
            let ctlDelta7 = ctlToday - (day(7).flatMap { ctlByDay[$0] } ?? 0)

            // ── Today's headline score — through `ReadinessToday.build`, the ONE recipe every
            // surface shares (the Today deck computes this same call), so the hub and the deck
            // can never disagree on the number.
            let loadToday = RecoveryModel(workouts: workouts, now: now, calendar: calendar)
            let readiness = ReadinessToday.build(workouts: workouts, checkins: checkins,
                                                 signals: signals, hrvHist: hrvHist, rhrHist: rhrHist,
                                                 nights: nights, now: now, calendar: calendar)

            // ── Plan risk #3 (RECOVERY-HUB-PLAN §10): the per-day pipeline below — 30 mornings
            // of readiness recomputes + ambient reads + strain runs — is the historical-recompute
            // cost. It must stay off the render path (it does: `Model.build()` + `.task(id:)`);
            // budget and profile before shipping P3. If it can't hit budget, fall back to
            // persisting a small daily snapshot — decided then, not now.
            // ── Historical readiness (Pro): recomputed from source per morning — no derived
            // persistence, late-syncing data self-heals on the next build. Past mornings read
            // only what existed BEFORE that day's training (a morning score never includes the
            // day's own session); baselines rebuild per day so early history stays honestly
            // unbanded rather than borrowing today's learned norm.
            var readinessByDay: [Date: Int] = [:]
            if let readiness { readinessByDay[today] = readiness.score }
            if pro {
                for ago in 1..<30 {
                    guard let d = day(ago) else { continue }
                    // The loop is main-actor (SwiftData models aren't Sendable) — yield every few
                    // mornings so it runs in frame-sized slices instead of one long blocking chunk.
                    if ago % 4 == 0 { await Task.yield() }
                    var sig = RecoverySignals()
                    sig.hrvMs = hrvByDay[d]
                    sig.restingHR = rhrByDay[d].map { Int($0.rounded()) }
                    sig.sleepHours = nightByDay[d]?.asleepH
                    let past = workouts.filter { $0.startedAt < d }
                    let ctx = sleepContext(asOf: d)
                    let score = MorningReadiness(
                        load: RecoveryModel(workouts: past, now: d, calendar: calendar),
                        signals: sig,
                        hrvBaseline: HealthBaselines.build(from: hrvHist, windowDays: HealthBaselines.Window.hrv,
                                                           now: d, calendar: calendar),
                        restingHRBaseline: HealthBaselines.build(from: rhrHist, windowDays: HealthBaselines.Window.restingHR,
                                                                 now: d, calendar: calendar),
                        sleepNeedH: ctx.need,
                        sleepDebt14H: ctx.debt,
                        checkin: checkins.first { calendar.isDate($0.date, inSameDayAs: d) })?.score
                    if let score { readinessByDay[d] = score }
                }
            }

            // ── Daily strain (Pro): workouts through the canonical load + ambient movement with
            // workout windows netted out by the service. A day with no signal at all stays a
            // hole — never a fake zero.
            var ambientByDay: [Date: (steps: Double?, kcal: Double?)] = [:]
            if pro, let concrete {
                // Fan the 30 day-reads out concurrently — serially this was 30 round-trips of
                // ~3 HK queries each, and it alone held the skeleton up for seconds.
                let days = (0..<30).compactMap { day($0) }
                ambientByDay = await withTaskGroup(of: (Date, steps: Double?, kcal: Double?)?.self) { group in
                    for d in days {
                        group.addTask {
                            let ambient = await concrete.ambientActivity(day: d)
                            guard ambient.steps != nil || ambient.activeKcal != nil else { return nil }
                            return (d, ambient.steps, ambient.activeKcal)
                        }
                    }
                    var out: [Date: (steps: Double?, kcal: Double?)] = [:]
                    for await entry in group {
                        if let entry { out[entry.0] = (entry.steps, entry.kcal) }
                    }
                    return out
                }
            }
            var strainByDay: [Date: DayStrain] = [:]
            if pro {
                for ago in 0..<30 {
                    guard let d = day(ago) else { continue }
                    let dayWorkouts = workoutsByDay[d] ?? []
                    let ambient = ambientByDay[d]
                    guard !dayWorkouts.isEmpty || ambient != nil else { continue }
                    strainByDay[d] = DayStrain(workoutsToday: dayWorkouts,
                                               ambientSteps: ambient?.steps,
                                               ambientActiveKcal: ambient?.kcal,
                                               walkingHRAvg: walkByDay[d],
                                               walkingHRBaseline: walkBase,
                                               chronicLoad: ctlByDay[d] ?? ctlToday,
                                               now: d, calendar: calendar)
                }
            }

            // ── The balance spines (7 + 30) and the hero's 7-day strip.
            let pairs: [(day: Date, strain: Double?, readiness: Double?)] = (0..<30).reversed().compactMap { ago in
                guard let d = day(ago) else { return nil }
                return (d, strainByDay[d].map { Double($0.score) }, readinessByDay[d].map(Double.init))
            }
            let balanceWeek = StrainRecoveryBalance(dailyPairs: pairs, spineDays: 7,
                                                    ctlDelta7: ctlDelta7, now: now, calendar: calendar)
            let balanceMonth = StrainRecoveryBalance(dailyPairs: pairs, spineDays: 30,
                                                     ctlDelta7: ctlDelta7, now: now, calendar: calendar)
            let hasBalanceData = pairs.filter { $0.strain != nil }.count >= 2
                || pairs.filter { $0.readiness != nil }.count >= 2
            let weekScores: [Int?] = (0..<7).reversed().map { ago in day(ago).flatMap { readinessByDay[$0] } }

            // ── Ghost bars (§11.1.1): the plan's remaining sessions over the NEXT 7 days as
            // estimated loads (`PlannedLoad.estimate`) — the chart no competitor can draw. A
            // rolling horizon, not the calendar week, so a Sunday still sees the week ahead;
            // past/today stays real data only (BalanceCard drops anything ≤ the spine's end).
            var ghostLoadByDay: [Date: Double] = [:]
            if pro, let plan, let horizon = calendar.date(byAdding: .day, value: 7, to: now) {
                for session in plan.sessions
                where session.status == .planned && session.completedWorkout == nil
                    && session.date > now && session.date <= horizon {
                    let estimate = PlannedLoad.estimate(session)
                    if estimate > 0 {
                        ghostLoadByDay[calendar.startOfDay(for: session.date), default: 0] += estimate
                    }
                }
            }
            let ghostBars = ghostLoadByDay.map { (date: $0.key, estLoad: $0.value) }
                .sorted { $0.date < $1.date }

            // ── Sleep context series (Pro): the running 14-day debt line.
            var sleepDebt: [SleepCard.DebtPoint] = []
            if pro, !nights.isEmpty {
                for ago in (0..<14).reversed() {
                    guard let d = day(ago) else { continue }
                    sleepDebt.append(SleepCard.DebtPoint(day: d, debtH: sleepContext(asOf: d).debt))
                }
            }

            // ── Weekly rhythm (Pro): 28 days of strain dots + kept rest days. A planned rest day
            // is a day inside the plan's span that prescribes nothing — part of the program.
            let planDays = Set((plan?.sessions ?? []).map { calendar.startOfDay(for: $0.date) })
            let planSpan: ClosedRange<Date>? = {
                guard let first = planDays.min(), let last = planDays.max() else { return nil }
                return first...last
            }()
            let rhythmDays: [RhythmCard.Day] = (0..<28).reversed().compactMap { ago in
                guard let d = day(ago) else { return nil }
                let isRest = (planSpan?.contains(d) ?? false) && !planDays.contains(d)
                return RhythmCard.Day(date: d,
                                      strain: strainByDay[d],
                                      isRestDayPlanned: isRest,
                                      workoutName: headlineName(workoutsByDay[d] ?? [], plan: plan,
                                                                on: d, calendar: calendar),
                                      ambientSteps: ambientByDay[d]?.steps)
            }

            // ── Vitals tiles: latest + delta-in-words + 30-day spark riding the personal band.
            let vitals = [
                vitalTile(.hrv, history: hrvHist, baseline: hrvBase, unit: "ms"),
                vitalTile(.restingHR, history: rhrHist, baseline: rhrBase, unit: "bpm"),
                vitalTile(.respiratory, history: respHist, baseline: respBase, unit: "br/min"),
                vitalTile(.wristTemp, history: tempHist, baseline: tempBase, unit: "°C"),
                vitalTile(.walkingHR, history: walkHist, baseline: walkBase, unit: "bpm"),
            ]

            // ── The live readout — the score's consequence, exactly the inputs TodayView's
            // bootstrap uses (signals, ACWR from ProgressInsights, plan tier, today's check-in).
            // A receipt recorded today outranks the live re-derivation: the plan already acted.
            let acwr = ProgressInsights(workouts: workouts, now: now, calendar: calendar).acwr
            let adaptationEvents = events
                .filter { $0.kind == .ease || $0.kind == .recover }
                .sorted { $0.date > $1.date }
            let readout: DriverRow.Readout
            if let todayEvent = adaptationEvents.first(where: { calendar.isDate($0.date, inSameDayAs: now) }) {
                readout = .adjusted(todayEvent.detail)
            } else {
                var lines: [String] = []
                if let trip = RecoveryAdaptation.tripwire(acwr: acwr, signals: signals) {
                    lines.append(trip.reason)
                }
                if let ease = RecoveryAdaptation.decide(signals: signals, intensity: intensity,
                                                        checkin: DailyCheckin.today(in: checkins,
                                                                                    calendar: calendar,
                                                                                    now: now)) {
                    lines.append(ease.reason)
                }
                readout = lines.isEmpty ? .allClear : .warnings(lines)
            }
            let timeline = adaptationEvents.prefix(6).map {
                DriverRow.TimelineEntry(date: $0.date, headline: $0.headline, reason: $0.detail)
            }

            return Model(readiness: readiness,
                         weekScores: weekScores,
                         readout: readout,
                         acwr: acwr,
                         healthAuthorized: health.isAuthorized,
                         balanceWeek: balanceWeek,
                         balanceMonth: balanceMonth,
                         ghostBars: ghostBars,
                         chronicLoad: ctlToday,
                         hasBalanceData: hasBalanceData,
                         sleepReport: sleepReport,
                         sleepNights: nights,
                         sleepDebt: sleepDebt,
                         vitals: vitals,
                         rhythmDays: rhythmDays,
                         hasRhythmData: !strainByDay.isEmpty,
                         monotony: loadToday.hasData ? loadToday.monotony : nil,
                         timeline: timeline)
        }

        // MARK: Builders

        /// One vital, shaped for the board: value + factual delta words + in/out-of-band stated
        /// in words (§6 — never a color judgment) + the spark over the personal-band ribbon.
        private static func vitalTile(_ kind: VitalTileModel.Kind,
                                      history: [(day: Date, value: Double)],
                                      baseline: HealthBaselines.Baseline?,
                                      unit: String) -> VitalTileModel {
            let latest = history.last?.value
            let decimals = kind == .respiratory || kind == .wristTemp
            var delta = ""
            var inBand = ""
            var bandRange: (lower: Double, upper: Double)?
            if let baseline, baseline.isBanded {
                bandRange = (lower: baseline.lower, upper: baseline.upper)
            }
            if let latest, let baseline, baseline.isBanded {
                let diff = latest - baseline.mean
                let threshold = max(baseline.sd * 0.5, decimals ? 0.1 : 1)
                if abs(diff) < threshold {
                    delta = "steady"
                } else {
                    let magnitude = decimals ? String(format: "%.1f", abs(diff)) : "\(Int(abs(diff).rounded()))"
                    delta = (diff >= 0 ? "+" : "−") + magnitude + " vs normal"
                }
                inBand = latest > baseline.upper ? "Above your normal range"
                    : latest < baseline.lower ? "Below your normal range"
                    : "In your normal range"
            }
            return VitalTileModel(kind: kind,
                                  latest: latest,
                                  unit: unit,
                                  delta: delta,
                                  inBand: inBand,
                                  spark: history.suffix(30).map(\.value),
                                  band: bandRange,
                                  baselineDayCount: baseline?.dayCount ?? 0,
                                  targetDays: 14)
        }

        /// The day's headline session in plain words ("the tempo") for the rhythm tap summary —
        /// names only what it knows, never invents specifics.
        private static func headlineName(_ dayWorkouts: [Workout], plan: TrainingPlan?,
                                         on day: Date, calendar: Calendar) -> String? {
            if let biggest = dayWorkouts.max(by: { TrainingLoad.session($0) < TrainingLoad.session($1) }) {
                if let named = runName(biggest.plannedSession?.runType) { return named }
                switch biggest.type {
                case .run, .trailRun: return "the run"
                case .ride, .gravelRide, .mountainBikeRide, .eBikeRide: return "the ride"
                case .strength: return "the strength work"
                case .walk: return "a walk"
                case .hike: return "the hike"
                default: return nil
                }
            }
            let session = plan?.sessions.first { calendar.isDate($0.date, inSameDayAs: day) }
            return runName(session?.runType)
        }

        private static func runName(_ type: RunType?) -> String? {
            switch type {
            case .tempo:        "the tempo"
            case .long:         "the long run"
            case .intervals:    "the intervals"
            case .easy:         "the easy run"
            case .recovery:     "the recovery run"
            case .race:         "the race"
            case .fartlek:      "the fartlek"
            case .hills:        "the hill reps"
            case .strides:      "strides"
            case .progression:  "the progression run"
            case .freeRun:      "the run"
            case nil:           nil
            }
        }
    }
}

// MARK: - Adaptation timeline (the Pro receipts trail)

/// "When the plan eased" — the persisted `CoachingEvent` trail rendered as its own card in the
/// depth cluster (§2: headline + `Decision.reason` verbatim; the hub only reads). Empty state is
/// calm: no easings is a plan holding steady, not a hole.
private struct AdaptationTimelineCard: View {
    let entries: [DriverRow.TimelineEntry]

    var body: some View {
        AdaptationTimelineList(entries: entries,
                               emptyText: "No easings yet — when your recovery asks for one, the receipt lands here.")
            .healthCard()
    }
}

/// The ease/recover trail — header + leaf-marked receipt rows. Extracted from DriverRow's
/// private `timelineList` so the hub's `AdaptationTimelineCard` reuses one implementation;
/// DriverRow's copy should adopt this once that file is free to edit (it's mid-flight in a
/// parallel palette pass — do not touch it from here).
struct AdaptationTimelineList: View {
    let entries: [DriverRow.TimelineEntry]
    /// Shown under the header when there are no receipts yet; nil callers (DriverRow gates on
    /// a non-empty timeline) simply never render empty.
    var emptyText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("WHEN THE PLAN EASED")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            if entries.isEmpty {
                if let emptyText {
                    Text(emptyText)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, isLast: index == entries.count - 1)
                    }
                }
            }
        }
    }

    private func row(_ entry: DriverRow.TimelineEntry, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            VStack(spacing: 0) {
                Image(systemName: "leaf")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 30, height: 30)
                    .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                if !isLast {
                    Rectangle().fill(Theme.hairline)
                        .frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.headline)
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: Theme.Space.sm)
                    Text(relativeDay(entry.date))
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
                Text(entry.reason)
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : Theme.Space.md)
        }
        .accessibilityElement(children: .combine)
    }

    private func relativeDay(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Specimen data (designed zero-data states, §5)

/// Canned, obviously-example series behind the `.specimen` ghosting — day one already looks like
/// the product. Deterministic (no randomness), so the empty state never shimmers between builds.
@MainActor
private enum Specimen {
    private static var pairs: [(day: Date, strain: Double?, readiness: Double?)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<30).compactMap { ago in
            guard let day = calendar.date(byAdding: .day, value: -ago, to: today) else { return nil }
            let t = Double(29 - ago)
            let strain = min(92, max(8, 45 + 30 * sin(t * 0.55) + Double((ago * 7) % 11) - 5))
            let readiness = min(94, max(28, 64 + 15 * sin(t * 0.32 + 1.9)))
            return (day, strain, readiness)
        }
    }

    static var balanceWeek: StrainRecoveryBalance {
        StrainRecoveryBalance(dailyPairs: pairs, spineDays: 7, ctlDelta7: 1.2)
    }
    static var balanceMonth: StrainRecoveryBalance {
        StrainRecoveryBalance(dailyPairs: pairs, spineDays: 30, ctlDelta7: 1.2)
    }

    static var sleep: (report: SleepReport, nights: [SleepReport.Night], debt: [SleepCard.DebtPoint])? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let hours = [7.7, 6.9, 8.1, 7.4, 7.2, 6.4, 7.9]
        let nights: [SleepReport.Night] = (0..<7).compactMap { ago in
            guard let day = calendar.date(byAdding: .day, value: -ago, to: today) else { return nil }
            let asleep = hours[ago]
            return SleepReport.Night(date: day, asleepH: asleep,
                                     coreS: asleep * 3_600 * 0.55, deepS: asleep * 3_600 * 0.18,
                                     remS: asleep * 3_600 * 0.22, awakeS: asleep * 3_600 * 0.05,
                                     inBedS: asleep * 3_600 * 1.06)
        }
        guard let report = SleepReport.build(from: nights) else { return nil }
        let debt: [SleepCard.DebtPoint] = (0..<14).reversed().compactMap { ago in
            guard let day = calendar.date(byAdding: .day, value: -ago, to: today) else { return nil }
            return SleepCard.DebtPoint(day: day, debtH: max(0, 3.8 - Double(14 - ago) * 0.22))
        }
        return (report, nights, debt)
    }

    static var rhythmDays: [RhythmCard.Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<28).reversed().compactMap { ago in
            guard let day = calendar.date(byAdding: .day, value: -ago, to: today) else { return nil }
            if ago % 7 == 2 { return RhythmCard.Day(date: day, isRestDayPlanned: true) }
            let steps = Double(3_000 + (ago * 3_137) % 22_000)
            let strain = DayStrain(workoutsToday: [], ambientSteps: steps, chronicLoad: 40,
                                   now: day, calendar: calendar)
            return RhythmCard.Day(date: day, strain: strain, ambientSteps: steps)
        }
    }
}

// MARK: - DEBUG harness (screenshots before ProgressView integration)

#if DEBUG
/// Standalone harness for the Health segment — a canned full-data model (or the cold-start one),
/// no HealthKit, no seeded store. The `--recovery-lab` deep link hosts this at integration;
/// previews and manual pushes can use it today. One `PaywallController` feeds BOTH the `Services`
/// container and the environment (the app's live wiring), so `.proLocked` and the segment's own
/// `isPro` reads can never disagree.
@MainActor
struct HealthSegmentHarness: View {
    /// `false` renders the cold-start story: learning-you hero, ConnectRow, specimen charts.
    let fullData: Bool
    @State private var paywall: PaywallController
    @State private var services: Services

    init(fullData: Bool = true, isPro: Bool = true) {
        self.fullData = fullData
        let controller = PaywallController(isPro: isPro)
        _paywall = State(initialValue: controller)
        _services = State(initialValue: Services(
            location: LocationService(), motion: MotionService(), health: HealthService(),
            ai: AIService(), sync: SyncService(), paywall: controller,
            notifications: NotificationService(), athleteModel: AthleteModelService()))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HealthSegmentView(demo: fullData ? .demo : .demoEmpty, scrollProxy: proxy)
                    .padding(Theme.Space.md)
            }
        }
        .background(Theme.background)
        .environment(services)
        .environment(paywall)
        .modelContainer(for: DailyCheckin.self, inMemory: true)
    }
}

extension HealthSegmentView.Model {
    /// A believable full-data morning: three device pillars + a check-in, a month of balance,
    /// staged sleep, banked baselines, and two receipts in the trail.
    @MainActor
    static var demo: HealthSegmentView.Model {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func day(_ ago: Int) -> Date { calendar.date(byAdding: .day, value: -ago, to: today) ?? today }

        let readiness = MorningReadiness(signals: .demo,
                                         checkin: DailyCheckin(energy: .full, legs: .ok))

        let pairs: [(day: Date, strain: Double?, readiness: Double?)] = (0..<30).map { ago in
            let t = Double(29 - ago)
            let strain: Double? = (ago == 11 || ago == 12) ? nil
                : min(95, max(6, 46 + 30 * sin(t * 0.55) + Double((ago * 7) % 11) - 5))
            let readiness: Double? = ago == 21 ? nil : min(96, max(24, 63 + 16 * sin(t * 0.32 + 1.9)))
            return (day(ago), strain, readiness)
        }

        let hours = [7.7, 6.9, 8.1, 6.2, 7.2, 6.4, 7.9, 7.5, 7.1, 6.8, 7.6, 7.3, 6.9, 7.8]
        let nights: [SleepReport.Night] = (0..<14).compactMap { ago in
            guard ago != 3 else { return nil }   // one missing morning → hollow column
            let asleep = hours[ago]
            return SleepReport.Night(date: day(ago), asleepH: asleep,
                                     coreS: asleep * 3_600 * 0.55, deepS: asleep * 3_600 * 0.18,
                                     remS: asleep * 3_600 * 0.22, awakeS: asleep * 3_600 * 0.05,
                                     inBedS: asleep * 3_600 * 1.06)
        }

        let hrvSpark: [Double] = (0..<30).map { 62 + 8 * sin(Double($0) / 4) + Double($0 % 5) }
        let rhrSpark: [Double] = (0..<30).map { 49 + 2 * sin(Double($0) / 6) }
        let respSpark: [Double] = (0..<30).map { 14.2 + 0.4 * sin(Double($0) / 5) }

        return HealthSegmentView.Model(
            readiness: readiness,
            weekScores: [61, 66, nil, 70, 74, 68, readiness?.score],
            readout: .allClear,
            acwr: 1.36,
            healthAuthorized: true,
            balanceWeek: StrainRecoveryBalance(dailyPairs: pairs, spineDays: 7, ctlDelta7: 1.4),
            balanceMonth: StrainRecoveryBalance(dailyPairs: pairs, spineDays: 30, ctlDelta7: 1.4),
            ghostBars: [(date: calendar.date(byAdding: .day, value: 1, to: today) ?? today, estLoad: 55),
                        (date: calendar.date(byAdding: .day, value: 3, to: today) ?? today, estLoad: 120)],
            chronicLoad: 42,
            hasBalanceData: true,
            sleepReport: SleepReport.build(from: nights),
            sleepNights: nights,
            sleepDebt: (0..<14).reversed().map { ago in
                SleepCard.DebtPoint(day: day(ago), debtH: max(0, 4.2 - Double(14 - ago) * 0.24))
            },
            vitals: [
                VitalTileModel(kind: .hrv, latest: 64, unit: "ms", delta: "+4 vs normal",
                               inBand: "In your normal range", spark: hrvSpark,
                               band: (lower: 56, upper: 74), baselineDayCount: 30, targetDays: 14),
                VitalTileModel(kind: .restingHR, latest: 49, unit: "bpm", delta: "−1 vs normal",
                               inBand: "In your normal range", spark: rhrSpark,
                               band: (lower: 47, upper: 52), baselineDayCount: 30, targetDays: 14),
                VitalTileModel(kind: .respiratory, latest: 14.4, unit: "br/min", delta: "steady",
                               inBand: "In your normal range", spark: respSpark,
                               band: (lower: 13.8, upper: 15.0), baselineDayCount: 9, targetDays: 14),
                VitalTileModel(kind: .wristTemp, latest: nil, unit: "°C", delta: "",
                               inBand: "", spark: [], band: nil, baselineDayCount: 0, targetDays: 14),
                VitalTileModel(kind: .walkingHR, latest: 68, unit: "bpm", delta: "steady",
                               inBand: "In your normal range", spark: rhrSpark.map { $0 + 19 },
                               band: (lower: 64, upper: 72), baselineDayCount: 21, targetDays: 14),
            ],
            rhythmDays: (0..<28).reversed().map { ago in
                if ago % 7 == 2 { return RhythmCard.Day(date: day(ago), isRestDayPlanned: true) }
                if ago == 9 { return RhythmCard.Day(date: day(ago)) }
                let steps = Double(2_000 + (ago * 3_137) % 26_000)
                return RhythmCard.Day(date: day(ago),
                                      strain: DayStrain(workoutsToday: [], ambientSteps: steps,
                                                        chronicLoad: 40, now: day(ago), calendar: calendar),
                                      workoutName: ago % 5 == 0 ? "the tempo" : nil,
                                      ambientSteps: steps)
            },
            hasRhythmData: true,
            monotony: 1.2,
            timeline: [
                DriverRow.TimelineEntry(date: day(1), headline: "Easy day instead",
                                        reason: "HRV below your norm and a short night (5.4h)."),
                DriverRow.TimelineEntry(date: day(5), headline: "Cutback week",
                                        reason: "Training load spiked to 1.6× your recent norm and HRV is suppressed."),
            ])
    }

    /// Day one: nothing measured yet — the learning-you hero, the connect hook, and every chart
    /// as its designed specimen.
    @MainActor
    static var demoEmpty: HealthSegmentView.Model {
        HealthSegmentView.Model(
            readiness: nil,
            readout: .allClear,
            healthAuthorized: false,
            balanceWeek: StrainRecoveryBalance(dailyPairs: [], spineDays: 7, ctlDelta7: 0),
            balanceMonth: StrainRecoveryBalance(dailyPairs: [], spineDays: 30, ctlDelta7: 0),
            vitals: VitalTileModel.Kind.allCases.map {
                VitalTileModel(kind: $0, latest: nil, unit: "", delta: "", inBand: "",
                               spark: [], band: nil, baselineDayCount: 0, targetDays: 14)
            })
    }
}

#Preview("Health — full data") {
    HealthSegmentHarness()
}

#Preview("Health — full data, dark") {
    HealthSegmentHarness().preferredColorScheme(.dark)
}

#Preview("Health — cold start") {
    HealthSegmentHarness(fullData: false)
}

#Preview("Health — locked (free)") {
    HealthSegmentHarness(isPro: false)
}
#endif
