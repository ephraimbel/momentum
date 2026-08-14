import SwiftUI
import SwiftData
import Charts
import UIKit

/// Progress — the coaching brain (PRD §4.7, §4.8). A training-status hero (ACWR), an AI coach card
/// that says how you're trending and how to tweak the plan, beautifully animated trend charts, a
/// consistency heatmap, PR shelves, and lifetime totals.
struct ProgressScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Environment(PaywallController.self) private var paywallController
    @Query private var workouts: [Workout]
    @Query private var profiles: [UserProfile]
    @Query(sort: \CoachingEvent.date, order: .reverse) private var coachingEvents: [CoachingEvent]
    @Query(sort: \DailyCheckin.date, order: .reverse) private var checkins: [DailyCheckin]   // Health segment pillars
    @Environment(AppRouter.self) private var router   // consumes pendingProgressSegment (one-shot)
    @State private var animateCharts = false
    @State private var adjustedPlan = false
    // Tap-to-inspect lives INSIDE each chart's ScrubChartHost (ChartScrub.swift) — screen-level
    // scrub @State made every drag tick rebuild this whole tree. These two only feed the
    // --scrub-demo harness a deterministic pin.
    @State private var demoScrubDistance: Date?
    @State private var demoScrubPace: Date?
    /// The Oura tap-through (2026-07-23): whichever card was tapped, presented as the one shared
    /// `TrendDetailSheet` — bigger chart, year-long ranges, window stats, the ⓘ's prose beneath.
    @State private var trendDetail: TrendDetail?
    @State private var segment: Segment = {
        #if DEBUG   // deterministic segment deep-links for sim verification (tab taps are flaky)
        let a = ProcessInfo.processInfo.arguments
        if a.contains("--progress-history") { return .history }
        if a.contains("--progress-health") { return .health }
        #endif
        return .trends
    }()
    @State private var correcting: LearnedItem?
    @State private var showVO2Info = false
    @State private var showLogWorkout = false
    /// "Log it manually" inside the composer swaps this sheet for the full form (same beat Today uses).
    @State private var manualPrefill: LogWorkoutPrefill?
    @State private var signals: RecoverySignals = .empty   // HRV / resting HR / sleep from Apple Health
    /// The strip's cold-path full-blend result (same `ReadinessToday` recipe as deck + hub) —
    /// only consulted when today's cache is empty.
    /// Day-stamped: an app resident past midnight must not present yesterday's score as today's
    /// (the day-keyed ReadinessTodayCache correctly nils out at midnight; this fallback has to too).
    @State private var stripReadiness: (day: Date, score: Int, band: String, driver: String)?
    @State private var measuredVO2: Double?                 // device-measured VO₂max (Watch/Garmin), if any
    @State private var didUpkeep = false                     // athlete-model upkeep runs once per screen
    @State private var aggregatedForKey = ""                 // .task(id:) re-fires on every tab visit; only re-walk when data (or the day) moved
    @State private var showAllAdaptations = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    enum Segment: String, CaseIterable, Identifiable {
        case trends = "Trends", health = "Health", history = "History"
        var id: Self { self }
    }

    /// One-shot mailbox from `AppRouter` (raw-value string keeps the router file decoupled):
    /// nil it FIRST, then switch — a stale request must never re-fire on a later appearance.
    private func consumePendingSegment() {
        guard let raw = router.pendingProgressSegment else { return }
        router.pendingProgressSegment = nil
        guard let seg = Segment(rawValue: raw) else { return }   // unknown strings: consumed, ignored
        withAnimation { segment = seg }
    }

    /// The trend-chart look-back window. Adding a longer range is one case here — the weekly series,
    /// axis density, and bar widths all key off `weeks` (6M ≈ 26 and 1Y ≈ 52 arrive once athletes
    /// have the history to fill them).
    enum TrendRange: String, CaseIterable, Identifiable {
        case week = "1W", month = "1M", threeMonths = "3M", sixMonths = "6M", year = "1Y"
        var id: Self { self }
        /// The windows offered in the picker. `year` stays defined (weeks + label ready) but off the
        /// switcher until it earns its place — add `.year` here to light it up in one edit.
        static let selectable: [TrendRange] = [.week, .month, .threeMonths, .sixMonths]
        /// True for the day-resolution range: charts plot the last 7 days as daily bars instead of
        /// rolling weekly windows (one weekly bar would be meaningless).
        var isDaily: Bool { self == .week }
        /// Weekly-window count for `ProgressInsights`. `.week` still asks for 5 so the ACWR/trend math
        /// (which reads recent WEEKS, window-independent) stays valid — its charts render `days`.
        var weeks: Int {
            switch self {
            case .week: 5
            case .month: 5           // ~30 days of rolling weekly windows
            case .threeMonths: 13    // ~90 days
            case .sixMonths: 26      // ~6 months
            case .year: 52           // ~1 year
            }
        }
        var accessibilityLabel: String {
            switch self {
            case .week: "Last week"
            case .month: "Last month"
            case .threeMonths: "Last three months"
            case .sixMonths: "Last six months"
            case .year: "Last year"
            }
        }
        /// Calendar-day look-back for the Athlete Panel — its body activation and windowed callouts read
        /// this many days, so the figure and its stats re-window with the picker (not a rolling weekly
        /// count like `weeks`, which is a chart-density knob).
        var activationDays: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .threeMonths: 90
            case .sixMonths: 180
            case .year: 365
            }
        }
        /// The window in whole weeks — for the VO₂ "vs …" delta, which reads weekly snapshots.
        var lookbackWeeks: Int { max(1, activationDays / 7) }
        /// The panel's eyebrow — names the window the body + callouts summarize.
        var windowLabel: String {
            switch self {
            case .week: "LAST 7 DAYS"
            case .month: "LAST MONTH"
            case .threeMonths: "LAST 3 MONTHS"
            case .sixMonths: "LAST 6 MONTHS"
            case .year: "LAST YEAR"
            }
        }
        /// Compact noun for a windowed distance callout's label.
        ///
        /// These name ROLLING windows, because that's what `activationDays` measures — so `.week`
        /// and `.month` must NOT say "THIS WEEK" / "THIS MONTH". They did, and the result was two
        /// cards visible in one screenful both labelled THIS WEEK with different numbers: the
        /// Athlete Panel's trailing-7-days ("4.45 mi") sitting directly above the calendar-week
        /// strip ("0 mi") on a Sunday. Nothing erodes trust in an analytics page faster than it
        /// contradicting itself in the same glance. The longer windows never claimed a calendar
        /// boundary, so they read the same as before.
        var distanceNoun: String {
            switch self {
            case .week: "LAST 7 DAYS"
            case .month: "LAST 30 DAYS"
            case .threeMonths: "3 MONTHS"
            case .sixMonths: "6 MONTHS"
            case .year: "12 MONTHS"
            }
        }
        /// Natural phrase for a windowed context line ("Most worked …"). Rolling, like
        /// `distanceNoun` — "this week"/"this month"/"this year" were calendar claims these
        /// windows don't make.
        var windowPhrase: String {
            switch self {
            case .week: "over the last 7 days"
            case .month: "over the last 30 days"
            case .threeMonths: "over 3 months"
            case .sixMonths: "over 6 months"
            case .year: "over 12 months"
            }
        }
        /// "…vs a month ago" phrasing for the VO₂ delta context.
        var agoLabel: String {
            switch self {
            case .week: "last week"
            case .month: "a month ago"
            case .threeMonths: "3 months ago"
            case .sixMonths: "6 months ago"
            case .year: "a year ago"
            }
        }
    }
    @State private var trendRange: TrendRange = .week

    private var plan: TrainingPlan? { profiles.first?.plan }

    /// The athlete's chosen unit — not a bare `.auto`, which ignored an explicit metric/imperial
    /// preference and silently resolved off locale instead.
    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }
    private var weightUnit: WeightUnit { WeightUnit(rawValue: profiles.first?.weightUnit ?? "") ?? .default() }

    // These aggregates walk EVERY workout (and its sets). As computed vars they re-ran on every
    // property access — `insights` alone is read 30+ times per body evaluation, so one tab switch
    // recomputed the full ACWR/CTL/ATL/TSB pipeline dozens of times. Cached per data change instead;
    // the fallback keeps the very first frame correct before the task lands.
    @State private var cachedStats: ProfileStats?
    @State private var cachedInsights: ProgressInsights?
    /// Workouts whose History row earned the PR badge — precomputed (detection fetches the full
    /// history per call; running it per visible row made History scrolling stutter).
    @State private var prBadgeIDs: Set<UUID>?
    /// The athlete-model read and the week's muscle/load work also walk every workout (the
    /// engine re-derives all its facts). Since the You merge they render inside Trends, so an
    /// uncached read re-ran them on every body evaluation — that was the tab's load stutter.
    @State private var cachedFacts: AthleteFacts?
    @State private var cachedActivation: [MuscleGroup: Double]?
    /// Total distance + session count over the selected range — the Athlete Panel's windowed
    /// distance/sessions callouts read these, recomputed together with activation on a range flip.
    @State private var cachedRangeDistanceM: Double?
    @State private var cachedRangeSessions: Int?
    /// Full-history weekly distance buckets — the season chart and volume delta read the
    /// workouts themselves (snapshots only accumulate one per week of app use).
    @State private var cachedWeekVolumes: [(week: Date, meters: Double)]?
    /// Per-render O(N) walks folded into the cache pass: the 28-day intensity mix re-walked
    /// every workout on each Trends body evaluation.
    @State private var cachedIntensityMix: IntensityMix.Mix?
    /// Whether any lifting history exists — gates the MUSCLE FOCUS rail target (running lights
    /// leg muscles too, but the strength section only mounts with actual strength workouts).
    @State private var cachedHasStrength = false
    /// The Essentials layer (2026-07-22 Trends redesign): this week vs last, the odometer totals —
    /// the numbers every endurance athlete actually quotes, computed in the same cache pass as
    /// everything else. Steps arrive async from Health (nil = loading, [] = not connected).
    @State private var cachedWeekNow: TrendsEssentials.WeekStat?
    @State private var cachedWeekPrev: TrendsEssentials.WeekStat?
    @State private var cachedTotals: TrendsEssentials.Totals?
    @State private var stepDays: [TrendsEssentials.StepPoint]?

    private var aggregatesReady: Bool { cachedInsights != nil }

    /// Data-plus-day key for the aggregate caches. The engines bake "today" into streaks, ACWR
    /// windows, and rolling cutoffs, so a count-only key froze yesterday's read in place when the
    /// app stayed in memory past midnight — the day stamp re-walks on the first visit of a new day.
    /// Content signature, not count: an equal-count mutation (edit a sport, delete one + log
    /// another) must refresh the aggregates too.
    private var aggregateKey: String {
        "\(workouts.contentSignature)-\(Int(Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate))"
    }

    /// One quiet frame of placeholder cards while the caches compute — the tab responds
    /// instantly instead of freezing through the engine walks.
    private var warmup: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface).frame(height: 420)
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface).frame(height: 150)
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface).frame(height: 220)
            }
            .padding(Theme.Space.md)
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    private var stats: ProfileStats { cachedStats ?? ProfileStats(workouts: workouts, plan: profiles.first?.plan) }
    private var insights: ProgressInsights { cachedInsights ?? ProgressInsights(workouts: workouts) }
    // (`recovery`/`cachedRecovery` deleted 2026-07-30 — the recovery cluster left this page in
    // 7d1b6ce, but its RecoveryModel full-history walk kept running on every data change.)
    private var athleteFacts: AthleteFacts { cachedFacts ?? AthleteModelEngine(workouts: workouts, plan: plan).facts }
    private var weekVolumes: [(week: Date, meters: Double)] { cachedWeekVolumes ?? computeWeekVolumes() }

    private func computeWeekVolumes() -> [(week: Date, meters: Double)] {
        let cal = Calendar.current
        var buckets: [Date: Double] = [:]
        for w in workouts {
            guard let d = w.gps?.distanceM, d > 0,
                  let start = cal.dateInterval(of: .weekOfYear, for: w.startedAt)?.start else { continue }
            buckets[start, default: 0] += d
        }
        return buckets.map { ($0.key, $0.value) }.sorted { $0.week < $1.week }
    }

    private func refreshAggregates() {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { print("⏱ Progress refreshAggregates: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms for \(workouts.count) workouts") }
        #endif
        cachedStats = ProfileStats(workouts: workouts, plan: profiles.first?.plan)
        cachedInsights = ProgressInsights(workouts: workouts, weeksBack: trendRange.weeks)
        // PR badges come from the persisted shelf (save-time persist + idempotent backfill keep it
        // complete) — ONE fetch. The old per-workout detector pass re-fetched history and faulted
        // every GPS sample per workout (O(n²)·samples on the main actor): THE Progress cold-open
        // freeze the perf audit flagged.
        let records = (try? context.fetch(FetchDescriptor<PersonalRecord>())) ?? []
        prBadgeIDs = Set(records.compactMap { $0.workout?.id })
        cachedFacts = AthleteModelEngine(workouts: workouts, plan: plan).facts
        refreshWindowed()
        cachedWeekVolumes = computeWeekVolumes()
        cachedIntensityMix = computeIntensityMix()
        cachedHasStrength = workouts.contains { $0.type.isStrengthStyle && $0.strength != nil }
        cachedWeekNow = TrendsEssentials.weekStat(workouts: workouts, weeksAgo: 0)
        cachedWeekPrev = TrendsEssentials.weekStat(workouts: workouts, weeksAgo: 1)
        cachedTotals = TrendsEssentials.totals(workouts: workouts)
    }

    // MARK: Tap-through details (the Oura move, 2026-07-23) — each card's full story, built lazily
    // at tap time. Series closures capture VALUE snapshots (weekVolumes' tuples, the workouts
    // array) and run inside the sheet's own task, so opening a detail costs nothing until a
    // window is actually requested.

    private var distanceDetail: TrendDetail {
        let unit = distanceUnit.resolved() == .imperial ? "mi" : "km"
        let all = weekVolumes
        let du = distanceUnit
        return TrendDetail(
            id: "distance", title: "Weekly distance", unit: unit,
            stats: [.average, .best, .total],
            explainer: MetricExplainers.weeklyDistance,
            format: { m in
                let v = du.resolved() == .imperial ? m / Formatters.metersPerMile : m / 1000
                return v >= 100 ? Formatters.compact(v) : (v >= 10 ? "\(Int(v.rounded()))" : String(format: "%.1f", v))
            },
            series: { weeks in
                let cutoff = Calendar.current.date(byAdding: .day, value: -weeks * 7, to: Date()) ?? .distantPast
                return all.filter { $0.week >= cutoff }.map { .init(date: $0.week, value: $0.meters) }
            })
    }

    private var paceDetail: TrendDetail {
        let du = distanceUnit
        // Value snapshot at tap time (one pass, three scalars per run) — the series closure used
        // to construct the FULL ProgressInsights per range flip (52 whole-table filter passes,
        // ACWR, a day series the sheet never reads) on the main actor. The weekly buckets below
        // reproduce ProgressInsights.weeks' pace math exactly: rolling 7-day windows ending now,
        // distance-weighted running pace, 0 for run-less weeks.
        let runs: [(t: Date, distM: Double, durS: Double)] = workouts
            .filter { $0.type.discipline == .running }
            .map { ($0.startedAt, $0.gps?.distanceM ?? 0, $0.durationS) }
        return TrendDetail(
            id: "pace", title: "Average pace", unit: du.resolved() == .imperial ? "/mi" : "/km",
            form: .line, lowerIsBetter: true, stats: [.best, .latest],
            explainer: MetricExplainers.weeklyPace,
            format: { secPerKm in
                let s = du.resolved() == .imperial ? secPerKm * (Formatters.metersPerMile / 1000) : secPerKm
                let t = Int(s.rounded())
                return "\(t / 60):\(String(format: "%02d", t % 60))"
            },
            series: { weeks in
                let cal = Calendar.current
                let now = Date()
                var pts: [TrendDetail.Point] = []
                for i in stride(from: max(1, weeks) - 1, through: 0, by: -1) {
                    guard let end = cal.date(byAdding: .day, value: -7 * i, to: now),
                          let start = cal.date(byAdding: .day, value: -7, to: end) else { continue }
                    let inWeek = runs.filter { $0.t > start && $0.t <= end }
                    let dist = inWeek.reduce(0.0) { $0 + $1.distM }
                    let dur = inWeek.reduce(0.0) { $0 + $1.durS }
                    pts.append(.init(date: start, value: dist > 0 ? dur / (dist / 1000) : 0))
                }
                return pts
            })
    }

    private var stepsDetail: TrendDetail {
        let health = services.health
        return TrendDetail(
            id: "steps", title: "Daily movement", unit: "steps",
            stats: [.average, .best],
            minimumYTop: 20_000,
            explainer: MetricExplainers.dailySteps,
            format: { Formatters.compact($0) },
            series: { weeks in
                let days = await health.dailySteps(daysBack: weeks * 7)
                    .map { TrendsEssentials.StepPoint(date: $0.day, steps: $0.steps) }
                let pts = weeks <= 5 ? days : TrendsEssentials.weeklyStepAverages(days)
                return pts.map { .init(date: $0.date, value: $0.steps) }
            })
    }

    /// The Athlete Panel's window-dependent facts — muscle activation, total distance, and session
    /// count over the selected range. One pass over the in-window workouts; called on first load and
    /// on every range flip so the figure and its callouts move with the picker.
    private func refreshWindowed() {
        let cutoff = Date().addingTimeInterval(-Double(trendRange.activationDays) * 86_400)
        let inWindow = workouts.filter { $0.startedAt >= cutoff }
        // Weekly set-equivalents, not the window total — the panel's figure grades ABSOLUTELY
        // (`.weeklyVolume`), so a muscle's light reflects its sustained weekly rate: the same
        // honest yardstick at 7D and 6M, brighter only where the athlete actually trains more.
        cachedActivation = MuscleActivation.combined(workouts: inWindow)
            .mapValues { $0 / Double(trendRange.lookbackWeeks) }
        cachedRangeDistanceM = inWindow.reduce(0) { $0 + ($1.gps?.distanceM ?? 0) }
        cachedRangeSessions = inWindow.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            segmentControl
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.md)
            // First tap renders a skeleton for one frame instead of computing every engine
            // inline: with cold caches each `insights`/`stats`/`recovery` access re-ran a full
            // history walk during the tab-switch frame — that was the freeze.
            if aggregatesReady {
                switch segment {
                case .trends: trends
                case .health: health
                case .history: history
                }
            } else {
                warmup
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        // Cross-tab segment requests (Today's readiness line, coach nav cards). Consume-then-nil,
        // on appear AND change — the request may land before or after this screen exists.
        .onAppear { consumePendingSegment() }
        .onChange(of: router.pendingProgressSegment) { _, _ in consumePendingSegment() }
        .sheet(isPresented: $showVO2Info) { vo2InfoSheet.presentationDetents([.medium, .large]) }
        // History's "+" is the other place an athlete realises a session is missing, so it opens the
        // SAME composer Today's Log button does — say it or type it, receipt, plan credit. It used
        // to drop straight into the raw form: no dictation, no receipt, and stricter rules (a
        // distance demanded for every run), which made the two entry points feel like two apps.
        .sheet(isPresented: $showLogWorkout) {
            LogActivityView { prefill in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { manualPrefill = prefill }
            }
        }
        .sheet(item: $manualPrefill) { LogWorkoutView(prefill: $0) }
        .sheet(isPresented: $showAllAdaptations) { adaptationSheet }
        .sheet(item: $correcting) { item in
            if let profile = profiles.first {
                CorrectionSheet(belief: item.value, category: item.category, noteID: item.noteID, profile: profile)
                    .presentationDetents([.medium])
            }
        }
        .sheet(item: $trendDetail) { TrendDetailSheet(detail: $0) }
        // A range flip re-windows the weekly series AND the Athlete Panel (its body activation +
        // distance/sessions callouts read the selected window). The ACWR/status verdict and the
        // current-physiology rail readings are point-in-time, so those stay put.
        .onChange(of: trendRange) {
            withAnimation(.easeOut(duration: 0.35)) {
                cachedInsights = ProgressInsights(workouts: workouts, weeksBack: trendRange.weeks)
                refreshWindowed()
            }
            // Pinned scrub cursors clear themselves — each ScrubChartHost resets when its dates change.
        }
        .task(id: aggregateKey) {
            if aggregatedForKey != aggregateKey {
                // A real pause, not a bare yield — one suspension hop resumed inside the same
                // transition, so the whole stack below still ran back-to-back on the main actor
                // before the skeleton could paint (perf audit 2026-08-13). Each stage gets the
                // run loop back before the next starts; cancellation exits between stages.
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                // The PR shelf must be complete BEFORE the aggregate pass snapshots it into
                // prBadgeIDs — running the one-time backfill after it left History badge-less
                // for the whole first session. Flag-guarded: one UserDefaults read thereafter.
                RecordsBook.backfillIfNeeded(in: context)
                await Task.yield()
                // Awards ride the same visit: history that predates the awards system earns its
                // coins here (already-seen — no celebration spam for months-old milestones).
                AwardsBook.sync(in: context)
                await Task.yield()
                withAnimation(.easeOut(duration: 0.2)) { refreshAggregates() }
                aggregatedForKey = aggregateKey
            }
            // Athlete-model upkeep (was the You tab's onAppear — idempotent, local-only).
            // Once per screen instance, and after first paint: ingest re-walks history.
            guard !didUpkeep, let p = profiles.first else { return }
            didUpkeep = true
            await Task.yield()
            services.athleteModel.seedOnboarding(for: p, in: context)
            services.athleteModel.ingest(profile: p, in: context)
        }
    }

    private var header: some View {
        // The shared masthead language (fuel / plan / progress): a small centered lowercase title
        // in the display face, accessories flanking — the big left-aligned billboard is retired.
        ZStack {
            Text("progress")
                .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Theme.Space.xs) {
                if let cachedStats { StreakChip(days: cachedStats.currentStreak) }
                Spacer()
                if segment == .history {
                    Button { Haptics.light(); showLogWorkout = true } label: {
                        Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Log a workout")
                }
                NavigationLink { SettingsView() } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
    }

    /// Trends · Health · History — the house `SegmentedCapsule`, so the page bar, the window
    /// picker below it, and Balance's 7D/30D are one control instead of three lookalikes. The
    /// selection pill now SLIDES between segments, and VoiceOver finally hears which one is
    /// active (the hand-rolled bar exposed no `.isSelected` trait at all).
    private var segmentControl: some View {
        SegmentedCapsule(items: Segment.allCases, selection: $segment, scale: .page) { $0.rawValue }
    }

    /// Compact 1W · 1M · 3M · 6M window switcher for the trend charts — one tap re-windows the
    /// weekly series (the axis label density and the whole chart block adapt to the wider ranges).
    private var trendRangePicker: some View {
        SegmentedCapsule(items: TrendRange.selectable, selection: $trendRange, scale: .compact,
                         title: { $0.rawValue }, spokenLabel: { $0.accessibilityLabel })
    }

    /// The Health segment — like `trends`/`history`, the segment owns its scroll container
    /// (the switch mounts bare views; an unscrolled overflowing VStack renders centered).
    /// The proxy powers the DriverRow chips' scroll-to-card.
    private var health: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HealthSegmentView(workouts: workouts,
                                  plan: profiles.first?.plan,
                                  checkins: checkins,
                                  events: coachingEvents,
                                  profile: profiles.first,
                                  scrollProxy: proxy)
                    .padding(Theme.Space.md)
                    .padding(.bottom, Theme.Space.xxl)
            }
        }
    }

    private var trends: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    // The hero: the athlete's own body with the week's physiology read off it.
                    // Every callout is a door into the detail card it summarizes.
                    // FREE — the athlete's own body, the hero teaser (readable summary callouts;
                    // the detail each one opens is Pro).
                    AthletePanel(activation: rangeMuscleActivation,
                                 sex: BodySex(profileSex: profiles.first?.sex),
                                 windowLabel: trendRange.windowLabel,
                                 hero: isAnalyticsPro ? panelHero : panelHeroFree,
                                 sub: isAnalyticsPro ? panelSub : panelSubFree,
                                 rail: panelRail,
                                 pro: isAnalyticsPro,
                                 onSelect: { target in
                        withAnimation(.easeOut(duration: 0.45)) { proxy.scrollTo(target, anchor: .top) }
                    },
                                 onLockedTap: { paywallController.present(for: .advancedAnalytics) })
                    // `once:` throughout this stack — Progress rebuilds the whole segment on every
                    // Trends → History → Trends flip, so the six-step entrance cascade replayed on
                    // every visit. An entrance is a greeting, not a toll.
                    .reveal(0, once: "trends.panel")
                    // The page reads as a structured report — Endurance / Strength / Coach —
                    // each chapter opened by an editorial masthead, so the two disciplines
                    // never blur into one stream of look-alike cards.
                    // FREE — the ESSENTIALS (2026-07-22 redesign): the numbers every endurance
                    // athlete actually quotes. This week vs last, distance over time, daily
                    // movement, the odometer — Bevel/Oura discipline, few cards with one clear
                    // answer each. The deep analytics below stay Pro.
                    // The window picker rides ON the masthead rather than floating in its own
                    // right-aligned row below it: a control with no visible scope reads as a page
                    // setting, and it isn't one — it re-windows this chapter (and the body above).
                    // Three items, like chapters 02 and 03 — the four-item version collided with
                    // the range picker now sharing this line and truncated to "… · RAC…".
                    trendsSectionHeader("01", "Endurance", "Volume · speed · engine",
                                        accessory: { trendRangePicker })
                        .reveal(0.02, once: "trends.01")
                    if let weekNow = cachedWeekNow, let weekPrev = cachedWeekPrev {
                        WeekStatStrip(now: weekNow, prev: weekPrev, distanceUnit: distanceUnit)
                            .reveal(0.025, once: "trends.week")
                            .id("weekStrip")
                    }
                    distanceChart(insights).reveal(0.03, once: "trends.distance").id("distanceChart")
                    StepsCard(days: stepDays, isDaily: trendIsDaily,
                              windowPhrase: trendRange.windowPhrase, animate: animateCharts,
                              onOpen: { trendDetail = stepsDetail })
                        .reveal(0.04, once: "trends.steps")
                        .id("steps")
                    if let totals = cachedTotals, totals.lifetime.sessions > 0 {
                        TrendTotalsCard(totals: totals, distanceUnit: distanceUnit)
                            .reveal(0.05, once: "trends.totals")
                            .id("totals")
                    }
                    // PRO — the fitness read (VO₂max), heart-rate zones, pace/intensity, the
                    // Fitness & Freshness curve, and the coaching. One unlock opens the whole
                    // premium page. (The 2026-07-22 redesign retired the standalone training-load
                    // bars — F&F's fatigue line tells that story — and the vitals/cadence/climb/
                    // efficiency deep-dive wall: vitals live on the Health page, and the exotic
                    // mechanics read as noise next to the numbers athletes actually track.)
                    // Free tier renders the static teaser column, not the live cluster: `.proLocked`
                    // blurs already-built content, so an un-entitled athlete used to pay the FULL
                    // build of the heaviest stack in the app (five chart systems) plus a live-subtree
                    // blur pass on every scroll frame, to see frost (perf audit 2026-08-13). Behind
                    // radius-9 blur + the 0.55 scrim, same-footprint surface shapes read identically
                    // as "the whole page, withheld". ProTrendsSection/StrengthProgressSection keep
                    // their own `pro:` seam for the `--analytics-lab` harness.
                    if !isAnalyticsPro {
                        proClusterTeaser
                            .reveal(0.06, once: "trends.pro")
                            .id("charts")
                            .proLocked(.advancedAnalytics)
                    } else {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        if insights.weeks.contains(where: { $0.avgPaceSPerKm > 0 }) { paceChart(insights) }
                        intensityMixCard.id("intensityMix")
                        fitnessHero().id("fitness")
                        hrZonesCard.id("hrZones")
                        // The marquee endurance curve — fitness, fatigue, and form (CTL·ATL·TSB).
                        ProTrendsSection(workouts: workouts, distanceUnit: distanceUnit, pro: isAnalyticsPro).id("proTrends")
                        raceOutlook()
                        // STRENGTH — its own chapter, deliberately monochrome (the strength family's
                        // ink-and-iridescence look). Header and section both vanish without lifting history.
                        if cachedHasStrength {
                            trendsSectionHeader("02", "Strength", "Lifts · volume · balance")
                                .padding(.top, Theme.Space.sm)
                        }
                        StrengthProgressSection(workouts: workouts, weightUnit: weightUnit, pro: isAnalyticsPro).id("strengthTrends")
                        // COACH — the cross-discipline read: today's readiness hand-off, the AI
                        // coach's verdict, the receipts (growth · season · record book), and what
                        // Momentum has learned about you. The subtitle names the receipts because
                        // they render here — it used to promise only "readiness · verdict" and then
                        // hand over three cards of measured history under a heading that hid them.
                        trendsSectionHeader("03", "Coach", "Readiness · verdict · your receipts")
                            .padding(.top, Theme.Space.sm)
                            .id("coachHead")
                        // "How am I right now" is the Health segment's story — Trends keeps only
                        // the compact hand-off strip (the retired recovery-card cluster was
                        // deleted 2026-07-23; Form/TSB stays with FitnessFreshnessCard above).
                        readinessStrip.id("formRace")
                        coachCard(insights)
                        athleteStory
                    }
                    .reveal(0.06, once: "trends.pro")
                    .id("charts")
                    }
                    // App Review 1.4.1: the citations door, at the foot of the page that shows
                    // the calculations (every chart's ⓘ sheet also carries its own source link).
                    SourcesFooterLink()
                        .padding(.top, Theme.Space.sm)
                }
                .padding(Theme.Space.md)
                .padding(.bottom, Theme.Space.xxl)
            }
            .onAppear {
                if reduceMotion { animateCharts = true }                               // no chart build-in
                else { withAnimation(.easeOut(duration: 0.9)) { animateCharts = true } }
                #if DEBUG   // deterministic scroll to Form/Race for sim verification
                // --scrub-demo: pin the middle point on the trend charts (simctl can't tap a chart).
                if ProcessInfo.processInfo.arguments.contains("--scrub-demo") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        guard let insights = cachedInsights else { return }
                        let pts = trendPoints(insights)
                        if pts.count > 2 { demoScrubDistance = pts[pts.count / 2].date }
                        let paced = pts.filter { $0.avgPaceSPerKm > 0 }
                        if paced.count > 1 { demoScrubPace = paced[paced.count / 2].date }
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-zones") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("hrZones", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-mix") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("intensityMix", anchor: .center) }
                }
                // These two live BELOW the async Pro sections — scroll after the models resolve
                // (at 0.9s the sections are still skeleton-height and the anchor lands too deep).
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-protrends") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { proxy.scrollTo("proTrends", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-strength") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { proxy.scrollTo("strengthTrends", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-ff") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { proxy.scrollTo("ffCard", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-coach") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { proxy.scrollTo("coachHead", anchor: .top) }
                }
                // --trend-range-{1m,3m,6m,1y}: preset the window so the Athlete Panel + picker can be
                // verified without pixel-tapping. Fires on its own (panel stays at top); pair it with
                // --progress-scroll-charts to also land on the charts.
                let ranges: [(String, TrendRange)] = [("--trend-range-1m", .month),
                                                      ("--trend-range-3m", .threeMonths),
                                                      ("--trend-range-6m", .sixMonths),
                                                      ("--trend-range-1y", .year)]
                if let hit = ranges.first(where: { ProcessInfo.processInfo.arguments.contains($0.0) }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        withAnimation(Motion.standard) { trendRange = hit.1 }
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-charts") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("charts", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-distance") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { proxy.scrollTo("distanceChart", anchor: .center) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-race") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("formRace", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-records") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("records", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-growth") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("growth", anchor: .top) }
                }
                #endif
            }
            .task {
                // Staggered off the first Trends paint — this, the steps fetch and the readiness
                // cold path all used to fan out HealthKit queries in the same frame the skeleton
                // was still settling (perf audit 2026-08-13).
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                async let s = services.health.recoverySignals()
                async let v = services.health.measuredVO2Max()
                signals = await s
                measuredVO2 = await v
            }
            // Daily movement for the steps card — refetched per window (a cheap statistics query).
            // Week fetches 14 days: the headline's vs-last-week delta needs the prior seven.
            .task(id: "steps-\(trendRange.rawValue)") {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }   // see stagger note above
                let days = await services.health.dailySteps(daysBack: trendIsDaily ? 14 : trendRange.weeks * 7)
                stepDays = days.map { TrendsEssentials.StepPoint(date: $0.day, steps: $0.steps) }
            }
            // The strip's own full-blend compute — covers the cold path (straight to Progress
            // before Today or the hub ran today) through the same ReadinessToday recipe, and
            // publishes so every sibling surface shows this exact number.
            .task(id: "\(workouts.count)-\(checkins.count)-\(Int(Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate))") {
                guard ReadinessTodayCache.today() == nil else { return }
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }   // see stagger note above
                if let r = await ReadinessToday.compute(health: services.health,
                                                        workouts: workouts, checkins: checkins) {
                    ReadinessToday.publish(r)
                    stripReadiness = (Calendar.current.startOfDay(for: Date()),
                                      r.score, r.band.rawValue, r.displayDriverWithConfidence)
                }
            }
        }
    }

    // MARK: - Fitness · Form · Race (running-excellence R4/R5 surfaced)

    private var latestSnapshot: FitnessSnapshot? {
        profiles.first?.athlete?.snapshots.max(by: { $0.weekStart < $1.weekStart })
    }
    /// True once the athlete has logged a REAL run. Until then, estimates that would otherwise fall
    /// back to the plan's ASSUMED onboarding pace stay hidden — empty-slate honesty: no concrete
    /// VO₂max, population percentile, or finish-time projection for someone who hasn't run yet.
    private var hasLoggedRun: Bool {
        workouts.contains { $0.type.discipline == .running && ($0.gps?.distanceM ?? 0) > 0 }
    }
    /// Best current running-fitness proxy: the athlete-model's Riegel-normalized 5k pace (measured
    /// from real runs), else the plan's assumed pace — but only once there's ≥1 real run to anchor it,
    /// so the fitness hero + race outlook show "not enough data" for a brand-new athlete.
    private var currentP5k: Double? {
        if let p = latestSnapshot?.p5kEquivSPerKm, p > 0 { return p }
        if hasLoggedRun, let p = plan?.p5kSPerKm, p > 0 { return p }
        return nil
    }
    /// VO₂max estimate from current fitness (P5k treated as a 5k effort — Daniels' VDOT).
    private var currentVO2: Double? {
        currentP5k.flatMap { VO2maxEstimator.fromRace(distanceM: 5000, timeS: $0 * 5) }
    }
    private var vo2EightWeeksAgo: Double? { vo2WeeksAgo(8) }
    /// VO₂max from the newest weekly snapshot at or before `weeks` ago — powers the panel's
    /// range-aware "vs a month/3 months ago" delta as well as the fitness card's 8-week read.
    private func vo2WeeksAgo(_ weeks: Int) -> Double? {
        guard let athlete = profiles.first?.athlete,
              let cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -weeks, to: Date()) else { return nil }
        let old = athlete.snapshots
            .filter { $0.weekStart <= cutoff && ($0.p5kEquivSPerKm ?? 0) > 0 }
            .max(by: { $0.weekStart < $1.weekStart })
        return old?.p5kEquivSPerKm.flatMap { VO2maxEstimator.fromRace(distanceM: 5000, timeS: $0 * 5) }
    }
    /// VO₂max over the weekly snapshots, for the hero sparkline.
    private var vo2Series: [(date: Date, vo2: Double)] {
        (profiles.first?.athlete?.snapshots ?? [])
            .sorted { $0.weekStart < $1.weekStart }
            .compactMap { s in
                guard let p = s.p5kEquivSPerKm, p > 0, let v = VO2maxEstimator.fromRace(distanceM: 5000, timeS: p * 5)
                else { return nil }
                return (s.weekStart, v)
            }
    }
    private var goalRace: RaceDistance? { profiles.first?.raceDistanceM.map { RaceDistance.nearest(toMeters: $0) } }
    private var racePredictions: [(race: RaceDistance, timeS: Double, paceSPerKm: Double)] {
        guard let p5k = currentP5k else { return [] }
        return RaceDistance.allCases.compactMap { r in
            guard let t = RacePredictor.finishTimeS(raceDistanceM: r.meters, p5kSPerKm: p5k),
                  let pace = RacePredictor.projectedPaceSPerKm(raceDistanceM: r.meters, p5kSPerKm: p5k) else { return nil }
            return (r, t, pace)
        }
    }

    /// FITNESS — the headline: VO₂max, an earned-iridescent trend chip, and a fitness sparkline. Prefers
    /// the device-measured VO₂max (Apple Watch / Garmin) when Health has one; otherwise our pace-derived
    /// estimate. The 8-week trend stays estimate-based (our continuous weekly model) so it's internally
    /// consistent even when the headline is a measurement.
    @ViewBuilder
    private func fitnessHero() -> some View {
        let estimated = currentVO2
        if let vo2 = measuredVO2 ?? estimated {
            let isMeasured = measuredVO2 != nil
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    sectionTitle("Running fitness")
                    Spacer()
                    Button { showVO2Info = true } label: {
                        Image(systemName: "info.circle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How VO₂max is estimated")
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: "%.1f", vo2)).font(.display(42, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        Text(isMeasured ? "VO₂ MAX · FROM YOUR DEVICE" : "VO₂ MAX · EST.")
                            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.8).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                    // Trend is estimate-to-estimate (our weekly model) regardless of the headline source.
                    if let cur = estimated, let old = vo2EightWeeksAgo, abs(cur - old) >= 0.3 {
                        let up = cur >= old
                        HStack(spacing: 4) {
                            Image(systemName: up ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .heavy))
                            Text("\(up ? "+" : "")\(String(format: "%.1f", cur - old)) / 8 wks").monospacedDigit()
                        }
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(up ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.hairline)))
                    }
                }
                vo2RangeBar(vo2)
                vo2Sparkline()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md).background(card)
        }
    }

    private var athleteAge: Int? {
        (profiles.first?.birthYear).map { max(14, Calendar.current.component(.year, from: Date()) - $0) }
    }
    /// Which norms table fits — `nil` when we honestly can't rate (no age, or sex unset/other:
    /// the Cooper/ACSM tables are male/female only). Never guess a demographic and present the
    /// rating as personalized.
    private var athleteNormsMale: Bool? {
        switch BiologicalSex(rawValue: profiles.first?.sex ?? "") {
        case .male: true
        case .female: false
        default: nil
        }
    }

    /// A good-vs-bad range for VO₂max: the athlete's rating for their age + sex, and where they sit on a
    /// muted→iridescent track (higher = fitter = the earned accent). Without a real age + sex the
    /// rating claim would be a lie (the old code silently rated everyone as a 35-year-old man) —
    /// so it renders a one-line nudge instead.
    @ViewBuilder
    private func vo2RangeBar(_ vo2: Double) -> some View {
        if let age = athleteAge, let male = athleteNormsMale {
            ratedVO2RangeBar(vo2, age: age, male: male)
        } else {
            Text("Add your age and sex in Profile → Edit to rate this against your age group.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func ratedVO2RangeBar(_ vo2: Double, age: Int, male: Bool) -> some View {
        let rating = VO2maxNorms.rating(vo2: vo2, age: age, male: male)
        let pos = VO2maxNorms.position(vo2: vo2, age: age, male: male)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(rating.rawValue).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Text("· \(VO2maxNorms.blurb(rating))").font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary).lineLimit(1).minimumScaleFactor(0.8)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.inkTertiary.opacity(0.22), Theme.inkTertiary.opacity(0.35)] + Theme.iridescent,
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                    Circle().fill(Theme.background).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Theme.ink, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .offset(x: pos * (w - 16))
                }
            }
            .frame(height: 16)
            HStack {
                Text("Below average").font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                Spacer()
                Text("Superior").font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.top, 2)
    }

    private var vo2InfoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("How we estimate your VO₂max")
                        .font(.display(24, weight: .black)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    infoParagraph("VO₂max is how much oxygen your body can use at full effort — the single best number for aerobic fitness. Higher is fitter.")
                    infoParagraph("If your Apple Watch or Garmin has recorded a VO₂max, we show that measured value (labelled \u{201C}from your device\u{201D}). Otherwise we estimate it from your recent 5K-equivalent pace using Daniels' VDOT model — the same science behind most GPS-watch estimates. The estimate sharpens as you log faster, harder efforts.")
                    infoParagraph("It's an estimate, not a lab test — expect it within a few points of a treadmill measurement. Read the trend over weeks, not any single number.")
                    infoParagraph("Your rating compares your estimate to population norms for your age and sex (Cooper Institute / ACSM).")
                    Text("Not medical advice.")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                        .padding(.top, Theme.Space.xs)
                }
                .padding(Theme.Space.lg)
            }
            .navigationTitle("VO₂max").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showVO2Info = false }.fontWeight(.semibold) } }
        }
    }

    private func infoParagraph(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The last 28 days of runs → the 80/20 polarized check. Reads the cache — `aggregatesReady`
    /// gates every segment behind the first `refreshAggregates()` pass, so this is always current.
    private var intensityMix: IntensityMix.Mix? { cachedIntensityMix }

    private func computeIntensityMix() -> IntensityMix.Mix? {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -28, to: Date()) else { return nil }
        let runs = workouts
            .filter { $0.type.discipline == .running && $0.startedAt >= cutoff }
            .compactMap { w -> IntensityMix.RunInput? in
                guard let gps = w.gps, gps.distanceM > 500, w.durationS > 0 else { return nil }
                return .init(paceSPerKm: w.durationS / (gps.distanceM / 1000),
                             plannedQuality: w.plannedSession?.runType?.isQuality)
            }
        return IntensityMix.analyze(runs: runs, p5kSPerKm: profiles.first?.plan?.p5kSPerKm ?? 0)
    }

    /// The polarized-training story (§12): one stacked easy/hard bar against the 80/20 target. The
    /// sweet spot earns the iridescent accent; everything else stays monochrome and matter-of-fact.
    @ViewBuilder
    private var intensityMixCard: some View {
        if let mix = intensityMix {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle("Intensity mix").accessibilityHidden(true)
                    Spacer()
                    Text("4 WKS").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.1)
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                    // Kept out of the collapsed element below so VoiceOver can still open the
                    // 80/20 explainer (the card-wide `children: .ignore` used to eat it).
                    MetricInfoButton(explainer: MetricExplainers.intensityMix).padding(.leading, 2)
                }
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            HStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(mix.verdict == .polarized ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink.opacity(0.15)))
                                    .frame(width: max(8, w * mix.easyFraction - 1))
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.ink)
                                    .frame(maxWidth: .infinity)
                            }
                            // The 80/20 target tick — background-colored so it reads over either segment.
                            Rectangle().fill(Theme.background).frame(width: 2, height: 22)
                                .shadow(color: .black.opacity(0.25), radius: 0.5)
                                .offset(x: w * 0.8)
                        }
                    }
                    .frame(height: 16)
                    HStack {
                        Text("\(Int((mix.easyFraction * 100).rounded()))% easy · \(mix.hardCount) hard run\(mix.hardCount == 1 ? "" : "s")")
                            .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                        Spacer()
                        Text("80/20 target").font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                    Text(mix.blurb)
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Intensity mix over four weeks")
                .accessibilityValue("\(Int((mix.easyFraction * 100).rounded())) percent easy. \(mix.blurb)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md).background(card)
        }
    }

    /// The athlete's five personalized HR zones (§10) — Karvonen when resting HR is known. Where every
    /// pace target gets its heart-rate anchor. Monochrome bars, Garmin-grade restraint.
    @ViewBuilder
    private var hrZonesCard: some View {
        if let maxHR = profiles.first?.maxHR,
           let zones = HRZones.zones(maxHR: maxHR, restingHR: profiles.first?.restingHR) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle("Heart rate zones")
                    Spacer()
                    MetricInfoButton(explainer: MetricExplainers.hrZones)
                }
                VStack(spacing: Theme.Space.sm) {
                    ForEach(zones) { z in
                        HStack(spacing: Theme.Space.md) {
                            Text(z.label)
                                .font(.rounded(Theme.FontSize.caption, weight: .black)).monospacedDigit()
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 26)
                                // Each band wears its zone colour (cool → hot) — effort you can read at a glance.
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(MetricColor.zone(z.index)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(z.name).font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                                Text(z.purpose).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            Spacer(minLength: Theme.Space.sm)
                            Text("\(z.bpm.lowerBound)–\(z.bpm.upperBound)")
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                }
                Text(profiles.first?.restingHR != nil
                     ? "Personalized from your max and resting heart rate."
                     : "From your estimated max heart rate — connect Apple Health to sharpen these.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md).background(card)
        }
    }

    @ViewBuilder
    private func vo2Sparkline() -> some View {
        let series = vo2Series
        if series.count >= 3 {
            let last = series.last?.date
            let lo = series.map(\.vo2).min() ?? 0, hi = series.map(\.vo2).max() ?? 1
            Chart(series, id: \.date) { pt in
                AreaMark(x: .value("W", pt.date, unit: .weekOfYear), y: .value("VO2", animateCharts ? pt.vo2 : lo))
                    .foregroundStyle(LinearGradient(colors: [MetricColor.fitness.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("W", pt.date, unit: .weekOfYear), y: .value("VO2", animateCharts ? pt.vo2 : lo))
                    .foregroundStyle(MetricColor.fitness).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                if pt.date == last {
                    PointMark(x: .value("W", pt.date, unit: .weekOfYear), y: .value("VO2", animateCharts ? pt.vo2 : lo))
                        .foregroundStyle(IridescentMaterial()).symbolSize(80)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: (lo * 0.97)...(hi * 1.03))
            .frame(height: 50)
        }
    }

    /// The Trends → Health hand-off: the compact strip that replaced the retired recovery
    /// cards (deleted 2026-07-23 — their depth lives in the Health segment now). Same blend
    /// the segment's hero computes — the two surfaces can never disagree on the number.
    private var readinessStrip: some View {
        let display = todaysReadinessDisplay()
        return ReadinessStrip(score: display?.score, bandWord: display?.band, driverLine: display?.driver) {
            withAnimation { segment = .health }
        }
    }

    /// One number everywhere: the cache (whichever surface computed the full blend most recently
    /// — deck, hub, or this page's own task) or nothing yet ("Learning you" for a beat). The old
    /// light fallback is GONE — it read 83 where the full blend read 75, and a briefly-wrong
    /// number is worse than a briefly-quiet strip.
    private func todaysReadinessDisplay() -> (score: Int, band: String, driver: String)? {
        if let cached = ReadinessTodayCache.today() { return cached }
        guard let s = stripReadiness,
              s.day == Calendar.current.startOfDay(for: Date()) else { return nil }
        return (s.score, s.band, s.driver)
    }

    /// RACE OUTLOOK — Riegel projections for every distance; your goal earns the iridescent row.
    @ViewBuilder
    private func raceOutlook() -> some View {
        let preds = racePredictions
        if !preds.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    sectionTitle("Race outlook")
                    Spacer()
                    if let days = RacePredictor.daysUntil(raceDate: profiles.first?.raceDate, from: Date()), let g = goalRace {
                        Text(days == 0 ? "Race day" : "\(days) days · \(RacePredictor.label(forRaceM: g.meters))")
                            .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background { Capsule().fill(Theme.background); Capsule().stroke(Theme.hairline) }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(preds.enumerated()), id: \.offset) { i, p in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        raceRow(p.race, p.timeS, p.paceSPerKm, isGoal: p.race == goalRace)
                    }
                }
                Text("Flat-course estimate — terrain and weather shift race day. Paces update as you train.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md).background(card)
        }
    }

    private func raceRow(_ race: RaceDistance, _ timeS: Double, _ pace: Double, isGoal: Bool) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text(RacePredictor.label(forRaceM: race.meters)).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
            if isGoal {
                Text("GOAL").font(.rounded(9, weight: .bold)).tracking(0.6).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(IridescentMaterial()).opacity(0.85))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Formatters.duration(s: timeS)).font(.display(19, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                Text(Formatters.pace(secPerKm: pace, unit: distanceUnit)).font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.vertical, Theme.Space.sm).padding(.horizontal, isGoal ? Theme.Space.sm : 0)
        .background { if isGoal { RoundedRectangle(cornerRadius: 11).fill(IridescentMaterial()).opacity(0.10) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(RacePredictor.label(forRaceM: race.meters))\(isGoal ? ", your goal" : ""): projected \(Formatters.duration(s: timeS))")
    }

    // MARK: - History (clean session feed)

    private var history: some View {
        // Free tier: the last 30 days (PRD §10 "limited history"); everything older is Pro.
        let hasFullHistory = paywallController.isEntitled(to: .fullHistory)
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        let visible = hasFullHistory ? workouts : workouts.filter { $0.startedAt >= cutoff }
        let lockedCount = workouts.count - visible.count
        return ScrollView {
            // Lazy: a long history otherwise realizes every month section (and decodes every route
            // thumbnail) up front. Sections now materialize as they scroll into view.
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                // A strip of three zeros isn't a summary, it's furniture — day one gets the one
                // honest line at the bottom of this stack instead.
                if !workouts.isEmpty {
                    historySummary().reveal(0, once: "history.summary")
                }
                // The personal heatmap lives HERE as a look-back card (decided 2026-06 — never a tab).
                // Rescued from the retired standalone History screen during the lean-cleanup pass.
                HeatmapHistoryCard(workouts: workouts, distanceUnit: distanceUnit)
                    .reveal(0.04, once: "history.heatmap")
                // No `.reveal` on the month sections: the LazyVStack discards row state past its
                // retention window, so the reveal re-fired from blank on EVERY scroll-back — content
                // flashed in both directions. The entrance stagger stays on the summary + heatmap.
                ForEach(monthGroups(visible), id: \.key) { group in
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        monthHeader(group.key, group.items)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { i, w in
                                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                                workoutFeedRow(w)
                            }
                        }
                        .padding(.horizontal, Theme.Space.md)
                        .background(card)
                    }
                }
                if lockedCount > 0 {
                    Button { paywallController.present(for: .fullHistory) } label: {
                        HStack(spacing: Theme.Space.md) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Theme.surface))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(lockedCount) earlier workout\(lockedCount == 1 ? "" : "s")")
                                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                                Text("Unlock your full history with Pro")
                                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            }
                            Spacer()
                            Text("PRO")
                                .font(.rounded(10, weight: .heavy)).tracking(1.4).foregroundStyle(Color(hex: "0E0E12"))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(Theme.route))
                        }
                        .padding(Theme.Space.md)
                        .background(card)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(lockedCount) earlier workouts locked — unlock your full history with Pro")
                }
                if workouts.isEmpty {
                    Text("Your sessions land here as you train.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .frame(maxWidth: .infinity).padding(.top, Theme.Space.xl)
                }
            }
            .padding(Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl)
        }
    }

    /// A month divider that earns its line: the month, and what the month actually came to.
    /// A bare "JULY 2026" is a label; scrolling back through a year of them told the athlete
    /// nothing they didn't already know from the row dates. Distance leads (the number they'd
    /// quote), sessions follow; a distance-free month (all strength) simply drops the first half.
    private func monthHeader(_ key: String, _ items: [Workout]) -> some View {
        let meters = items.compactMap { $0.gps?.distanceM }.reduce(0, +)
        let sessions = "\(items.count) session\(items.count == 1 ? "" : "s")"
        let summary = meters > 0
            ? "\(Formatters.distance(meters: meters, unit: distanceUnit)) · \(sessions)"
            : sessions
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(key.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(0.8).foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: Theme.Space.sm)
            Text(summary)
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key)
        .accessibilityValue(summary)
        .accessibilityAddTraits(.isHeader)
    }

    /// This-month summary strip: sessions, distance, PRs. Memoized (same non-observed-box pattern
    /// as `monthGroups` — the month filter + GPS-distance faults ran on every History body pass);
    /// the cache holds only display strings, never model refs.
    private final class HistorySummaryMemo {
        var token = 0
        var sessions = ""; var distance = ""; var distanceLabel = ""; var prs = ""
    }
    @State private var summaryMemo = HistorySummaryMemo()
    private func historySummary() -> some View {
        var h = Hasher()
        h.combine(aggregateKey); h.combine(distanceUnit)
        let token = h.finalize()
        let memo = summaryMemo
        if memo.token != token {
            let month = Calendar.current.dateInterval(of: .month, for: Date())
            let mine = workouts.filter { month?.contains($0.startedAt) ?? false }
            let far = Formatters.wholeDistance(meters: mine.compactMap { $0.gps?.distanceM }.reduce(0, +),
                                               unit: distanceUnit)
            memo.sessions = "\(mine.count)"
            memo.distance = "\(far.value)"
            memo.distanceLabel = "\(far.unit) this month"
            // Month-scoped like its siblings — the lifetime improvement-event count here read
            // as "47 PRs this month" to a two-year athlete.
            memo.prs = "\((profiles.first?.prs ?? []).filter { month?.contains($0.achievedAt) ?? false }.count)"
            memo.token = token
        }
        return HStack(spacing: 0) {
            summaryCell(memo.sessions, "Sessions")
            Divider().frame(height: 34).overlay(Theme.hairline)
            summaryCell(memo.distance, memo.distanceLabel)
            Divider().frame(height: 34).overlay(Theme.hairline)
            summaryCell(memo.prs, "PRs")
        }
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity)
        .background(card)
    }

    private func summaryCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.display(19, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.4).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Workouts grouped by month, newest first. Memoized (non-observed box, token-guarded like
    /// the Plan board's week map): `Date.formatted` per workout per History body pass was the
    /// section's biggest per-render cost. The token is the CONTENT signature + the visible count,
    /// so a delete/edit recomputes fresh on the same frame — the cache can never serve a
    /// cascade-deleted model.
    private final class MonthGroupsMemo {
        var token = 0
        var groups: [(key: String, items: [Workout])] = []
    }
    @State private var monthMemo = MonthGroupsMemo()
    private func monthGroups(_ source: [Workout]) -> [(key: String, items: [Workout])] {
        var h = Hasher()
        h.combine(aggregateKey)
        h.combine(source.count)
        let token = h.finalize()
        if monthMemo.token == token { return monthMemo.groups }
        let sorted = source.sorted { $0.startedAt > $1.startedAt }
        let fmt = Date.FormatStyle.dateTime.month(.wide).year()
        var order: [String] = []
        var map: [String: [Workout]] = [:]
        for w in sorted {
            let key = w.startedAt.formatted(fmt)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(w)
        }
        let groups = order.map { ($0, map[$0] ?? []) }
        monthMemo.token = token
        monthMemo.groups = groups
        return groups
    }

    private func workoutFeedRow(_ w: Workout) -> some View {
        NavigationLink { WorkoutDetailView(workout: w) } label: {
            HStack(spacing: Theme.Space.md) {
                feedThumb(w)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(feedTitle(w)).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: Theme.Space.xs)
                        if feedIsPR(w) {
                            Text("PR").font(.rounded(9, weight: .bold)).tracking(0.4).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(IridescentMaterial()).opacity(0.85))
                        }
                    }
                    Text(feedSubtitle(w)).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    HStack(spacing: Theme.Space.md) {
                        ForEach(feedStats(w), id: \.self) { s in
                            Text(s).font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                        }
                    }
                    .padding(.top, 3)
                }
            }
            .padding(.vertical, Theme.Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func feedThumb(_ w: Workout) -> some View { HistoryFeedThumb(workout: w) }

    private func feedTitle(_ w: Workout) -> String {
        if !w.title.isEmpty { return w.title }
        if w.type.discipline == .running, let rt = w.plannedSession?.runType { return "\(rt.rawValue.capitalized) run" }
        return w.type.title
    }
    private func feedSubtitle(_ w: Workout) -> String {
        let day = w.startedAt.formatted(.dateTime.weekday(.abbreviated).day())
        let kind = w.plannedSession?.runType?.rawValue.capitalized ?? w.type.title
        // An untitled workout's title IS its type, so repeating it below read "Weight Training ·
        // Weight Training". Say the time instead — the one fact the row doesn't already carry.
        guard kind.caseInsensitiveCompare(feedTitle(w)) != .orderedSame else {
            return "\(day) · \(w.startedAt.formatted(date: .omitted, time: .shortened))"
        }
        return "\(day) · \(kind)"
    }
    private func feedStats(_ w: Workout) -> [String] {
        if let gps = w.gps, gps.distanceM > 0 {
            let dist = Formatters.distance(meters: gps.distanceM, unit: distanceUnit)
            let pace = w.type.isCycling
                ? Formatters.speed(ms: w.durationS > 0 ? gps.distanceM / w.durationS : 0, unit: distanceUnit)
                : Formatters.pace(secPerKm: w.durationS > 0 ? w.durationS / (gps.distanceM / 1000) : 0, unit: distanceUnit)
            return [dist, pace, Formatters.duration(s: w.durationS)]
        }
        if let s = w.strength {
            let n = s.exercises.count
            return ["\(n) exercise\(n == 1 ? "" : "s")", Formatters.duration(s: w.durationS)]
        }
        return [Formatters.duration(s: w.durationS)]
    }
    private func feedIsPR(_ w: Workout) -> Bool {
        prBadgeIDs?.contains(w.id) ?? false
    }

    // MARK: AI coach card

    private func coachCard(_ insights: ProgressInsights) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "sparkles"); Text("COACH").tracking(1.5)
            }
            .font(.rounded(Theme.FontSize.label, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            Text(ProgressNarrator.coach(insights, streak: stats.currentStreak))
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            recommendationChip(insights.recommendation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(card)
    }

    /// The plan already took a structural change this week (`lastAdaptedAt` — the same ≤1/week gate
    /// every engine shares). The chip's old `@State` latch reset on every screen load, so the same
    /// completed-load recommendation could be re-applied and compound across launches — the exact
    /// hazard `PlanCoaching.apply`'s doc warns about. `lastAdaptedAt` is the persistent latch.
    private var planAdaptedThisWeek: Bool {
        guard let last = plan?.lastAdaptedAt else { return false }
        return (Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? .max) < 7
    }

    /// The recommendation chip. For actionable recs (increase/ease/rest) it's a button that
    /// reshapes the upcoming plan; hold/start are informational only.
    @ViewBuilder
    private func recommendationChip(_ rec: ProgressInsights.Recommendation) -> some View {
        let actionable = rec == .increase || rec == .ease || rec == .rest
        if adjustedPlan {
            chipLabel("Plan updated", icon: "checkmark")
        } else if planAdaptedThisWeek {
            chipLabel("Adapted this week", icon: "checkmark")
        } else if actionable {
            Button {
                let changed = PlanCoaching.apply(rec, to: plan, in: context)
                if changed > 0 {
                    Haptics.success()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { adjustedPlan = true }
                }
            } label: {
                chipLabel(ProgressNarrator.action(rec), icon: "wand.and.stars")
            }
            .buttonStyle(.plain)
        } else {
            chipLabel(ProgressNarrator.action(rec), icon: "arrow.up.forward")
        }
    }

    private func chipLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(text).font(.rounded(Theme.FontSize.caption, weight: .bold))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
        .background { Capsule().fill(IridescentMaterial()).opacity(0.3); Capsule().stroke(Theme.hairline) }
    }

    // MARK: Charts

    /// PACE — the speed instrument: a crisp ice line with the axis INVERTED so getting faster
    /// reads as climbing (the Strava/Garmin convention — a dropping line for improving pace reads
    /// as decline). Weeks without runs are dropped so a rest week doesn't read as a cliff.
    private func paceChart(_ insights: ProgressInsights) -> some View {
        let unit = distanceUnit.resolved() == .imperial ? "mi" : "km"
        let paced = trendPoints(insights).filter { $0.avgPaceSPerKm > 0 }
        let slowest = paced.map(\.avgPaceSPerKm).max() ?? 0
        let fastest = paced.map(\.avgPaceSPerKm).min() ?? 1
        let last = paced.last?.date
        let latest = paced.last.map { paceMMSS($0.avgPaceSPerKm) }
        let subtitle = trendIsDaily ? "Average running pace by day · faster reads up"
                                    : "Average running pace · faster reads up"
        // <= so exactly −1.0% lands on the faster branch (the chip renders at abs >= 1, and
        // "<" sent that boundary case to "↓-1% slower"); abs() keeps the slower text sign-safe.
        let faster = insights.paceTrendPct <= -1
        let delta: ChartDelta? = (!trendIsDaily && abs(insights.paceTrendPct) >= 1)
            ? ChartDelta(text: faster ? "↑\(Int(abs(insights.paceTrendPct).rounded()))% faster"
                                      : "↓\(Int(abs(insights.paceTrendPct).rounded()))% slower",
                         good: faster)
            : nil
        return chartSection(trendIsDaily ? "Daily pace" : "Weekly pace", subtitle: subtitle,
                            headline: latest, headlineUnit: "/\(unit)",
                            delta: delta, explainer: MetricExplainers.weeklyPace,
                            onOpen: { trendDetail = paceDetail }) {
            if paced.count < 2 { notEnoughData } else {
                ScrubChartHost(dates: paced.map(\.date), seed: demoScrubPace) { pinned in
                    Chart {
                        ForEach(paced) { p in
                            LineMark(x: .value("Date", p.date, unit: trendUnit),
                                     y: .value("Pace", animateCharts ? p.avgPaceSPerKm : slowest))
                                .foregroundStyle(MetricColor.pace).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Date", p.date, unit: trendUnit),
                                      y: .value("Pace", animateCharts ? p.avgPaceSPerKm : slowest))
                                .foregroundStyle(p.date == last ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(MetricColor.pace))
                                .symbolSize(p.date == last ? 90 : 22)
                        }
                        if let sel = pinned, let p = paced.first(where: { $0.date == sel }) {
                            TrendScrub.mark(at: sel, unit: trendUnit,
                                            value: "\(paceMMSS(p.avgPaceSPerKm)) /\(unit)", label: scrubDateLabel(sel))
                        }
                    }
                    .chartXScale(domain: paddedDomain(paced.map(\.date)))
                    // Array domain, slowest first → the y-axis runs slow-at-bottom to fast-at-top.
                    .chartYScale(domain: [slowest * 1.07, fastest * 0.93])
                    .chartXAxis { trendAxis(insights.weeks.count) }
                    .chartYAxis { paceAxis }
                    .frame(height: 172)
                }
            }
        }
    }

    /// DISTANCE — the free flagship, and the page's monochrome statement: bold ink bars (a
    /// magnitude wants bars, not a squiggle), the current bar glinting iridescent. Bevel-clean;
    /// colour arrives with the Pro domain charts below.
    private func distanceChart(_ insights: ProgressInsights) -> some View {
        let unit = distanceUnit.resolved() == .imperial ? "mi" : "km"
        func disp(_ m: Double) -> Double { distanceUnit.resolved() == .imperial ? m / Formatters.metersPerMile : m / 1000 }
        func short(_ v: Double) -> String { v >= 10 ? "\(Int(v.rounded()))" : String(format: "%.1f", v) }
        let pts = trendPoints(insights)
        let maxDist = pts.map { disp($0.distanceM) }.max() ?? 0
        let last = pts.last?.date
        // Daily view headlines the week-to-date total (a rest-day "0.0" is honest but tells the
        // athlete nothing) — CALENDAR week-to-date, matching the THIS WEEK strip above it: the
        // engine's `days` is a trailing-7-day window, and summing all of it under "This week so
        // far" contradicted the strip every Monday morning. Weekly views headline the newest
        // bar, which the engine builds as a rolling last-7-days — caption it as exactly that.
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let latest = trendIsDaily ? pts.filter { $0.date >= weekStart }.reduce(0) { $0 + disp($1.distanceM) }
                                  : pts.last.map { disp($0.distanceM) } ?? 0
        let miles = unit == "mi" ? "miles" : "kilometres"
        let title = trendIsDaily ? "Daily distance" : "Weekly distance"
        let subtitle = trendIsDaily ? "This week so far · \(miles) by day"
                                    : "Last 7 days · \(miles) per week, \(trendRange.windowPhrase)"
        let delta: ChartDelta? = (!trendIsDaily && abs(insights.distanceTrendPct) >= 1)
            ? ChartDelta(text: "\(insights.distanceTrendPct >= 0 ? "↑" : "↓")\(Int(abs(insights.distanceTrendPct).rounded()))%",
                         good: insights.distanceTrendPct >= 0)
            : nil
        return chartSection(title, subtitle: subtitle,
                            headline: maxDist > 0 ? short(latest) : nil, headlineUnit: unit,
                            delta: delta, explainer: MetricExplainers.weeklyDistance,
                            onOpen: { trendDetail = distanceDetail }) {
            if maxDist <= 0 { notEnoughData } else {
                ScrubChartHost(dates: pts.map(\.date), seed: demoScrubDistance) { pinned in
                    Chart {
                        ForEach(pts) { p in
                            // Bars read cleanly across rest weeks and rest days alike; widths slim
                            // as the window widens so 26 weeks never collide.
                            BarMark(x: .value("Date", p.date, unit: trendUnit),
                                    y: .value("Distance", animateCharts ? disp(p.distanceM) : 0),
                                    width: .fixed(trendIsDaily ? 24 : loadBarWidth(pts.count)))
                                .foregroundStyle(p.date == last ? AnyShapeStyle(IridescentMaterial())
                                                                : AnyShapeStyle(Theme.ink.opacity(0.82)))
                                .cornerRadius(3)
                        }
                        if let sel = pinned, let p = pts.first(where: { $0.date == sel }) {
                            TrendScrub.mark(at: sel, unit: trendUnit,
                                            value: "\(short(disp(p.distanceM))) \(unit)",
                                            label: scrubDateLabel(sel))
                        }
                    }
                    .chartXScale(domain: paddedDomain(pts.map(\.date)))
                    .chartYScale(domain: 0...max(1, maxDist * 1.18))
                    .chartXAxis { trendAxis(pts.count) }
                    .chartYAxis { valueAxis }
                    .frame(height: 172)
                }
            }
        }
    }

    // MARK: Shared chart axes — a quiet week timeline + faint value gridlines, so every chart reads
    // as tracking something over time (not a floating squiggle).

    /// Load-bar width for the number of weeks on screen — full-bodied at 1M, slim by 6M, so bars
    /// never touch. Steps (not a continuous scale) keep the look consistent within each range.
    private func loadBarWidth(_ weekCount: Int) -> CGFloat {
        switch weekCount {
        case ...8: 18     // 1M (5 weeks)
        case ...14: 10    // 3M (13 weeks)
        default: 6        // 6M (26 weeks) and beyond
        }
    }

    /// X axis: a week/date timeline. Both density and granularity adapt to the range — 1M/3M label
    /// every-few-weeks with month+day; at 6M+ the resolution drops to month-only (like Health when
    /// zoomed out), which reads cleaner and stops the right-edge label clipping off ("Jun…").
    private func weekAxis(_ weekCount: Int) -> some AxisContent {
        let stride = max(2, Int((Double(weekCount) / 5).rounded(.up)))
        let monthOnly = weekCount > 14
        return AxisMarks(values: .stride(by: .weekOfYear, count: stride)) { _ in
            AxisValueLabel(format: monthOnly ? .dateTime.month(.abbreviated)
                                             : .dateTime.month(.abbreviated).day())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    // MARK: Trend series — daily for the Week range, weekly otherwise (one path serves every chart).

    /// A granularity-agnostic chart point: the distance/pace/load charts plot these, so the same
    /// marks render both the daily "Week" view (7 days) and the rolling weekly ranges.
    ///
    /// Identity is the DATE, not a fresh UUID. `trendPoints(_:)` rebuilds this array on every body
    /// evaluation, so a per-instance UUID handed Charts a brand-new identity for every mark on
    /// every render — `ForEach` tore the whole plot down and rebuilt it instead of diffing, which
    /// both cost frames and killed the mark-level animation the bars were written for. A bucket's
    /// date IS its identity here (one point per day / per week, by construction).
    struct TrendPoint: Identifiable {
        let date: Date
        let load: Double
        let distanceM: Double
        let avgPaceSPerKm: Double
        var id: Date { date }
    }

    private var trendIsDaily: Bool { trendRange.isDaily }
    private var trendUnit: Calendar.Component { trendIsDaily ? .day : .weekOfYear }

    /// The points to plot for the current range — daily buckets for Week, weekly windows otherwise.
    private func trendPoints(_ insights: ProgressInsights) -> [TrendPoint] {
        trendIsDaily
            ? insights.days.map { TrendPoint(date: $0.dayStart, load: $0.load, distanceM: $0.distanceM, avgPaceSPerKm: $0.avgPaceSPerKm) }
            : insights.weeks.map { TrendPoint(date: $0.weekStart, load: $0.load, distanceM: $0.distanceM, avgPaceSPerKm: $0.avgPaceSPerKm) }
    }

    /// X domain padded to the unit: half a day for daily, four days for weekly.
    private func paddedDomain(_ dates: [Date]) -> ClosedRange<Date> {
        guard let lo = dates.min(), let hi = dates.max(), lo <= hi else { return Date()...Date().addingTimeInterval(1) }
        let pad: TimeInterval = trendIsDaily ? 12 * 3600 : 4 * 24 * 3600
        return lo.addingTimeInterval(-pad)...hi.addingTimeInterval(pad)
    }

    /// X axis for the current granularity: single-letter weekday initials across the 7-day Week view,
    /// else the existing week/month timeline.
    @AxisContentBuilder private func trendAxis(_ count: Int) -> some AxisContent {
        if trendIsDaily {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        } else {
            weekAxis(count)
        }
    }

    /// Y axis: faint hairline gridlines with muted numeric labels; the zero line is a touch stronger
    /// so the chart sits on a clear baseline.
    private var valueAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
            let isZero = (value.as(Double.self) ?? 1) == 0
            AxisGridLine().foregroundStyle(isZero ? Theme.inkTertiary.opacity(0.35) : Theme.hairline)
            AxisValueLabel()
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    /// Y axis for pace — gridlines with the value formatted as m:ss (raw seconds are unreadable).
    private var paceAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            if let secPerKm = value.as(Double.self) {
                AxisValueLabel { Text(paceMMSS(secPerKm)) }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    /// "m:ss" for the pace axis (per display unit, no suffix — the subtitle already states per-mi/km).
    private func paceMMSS(_ secPerKm: Double) -> String {
        let secPerUnit = distanceUnit.resolved() == .imperial ? secPerKm * (Formatters.metersPerMile / 1000) : secPerKm
        let total = Int(secPerUnit.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }


    /// The scrub pill's date caption for the current granularity — "Wed, Jul 15" by day, else the week.
    private func scrubDateLabel(_ d: Date) -> String {
        trendIsDaily ? TrendScrub.dayLabel(d) : TrendScrub.weekLabel(d)
    }

    /// Quiet placeholder when a chart has fewer than ~2 weeks of real data, so it never shows a lone
    /// floating bar or point.
    private var notEnoughData: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            Text("A couple more weeks and your trend shows here.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 100)
    }

    /// An editorial chapter masthead — display-face title, an index numeral, a hairline rule.
    /// The Trends page reads as a structured report (01 Endurance / 02 Strength / 03 Coach)
    /// instead of one continuous stream of cards.
    ///
    /// `accessory` sits on the subtitle line, right-aligned — where a chapter-scoped control
    /// belongs. It stays OUTSIDE the combined header element so its own buttons remain reachable
    /// (a `children: .combine` header swallows any interactive content nested inside it).
    private func trendsSectionHeader<A: View>(_ index: String, _ title: String, _ sub: String,
                                              @ViewBuilder accessory: () -> A = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .lastTextBaseline) {
                Text(title).font(.display(24, weight: .black)).foregroundStyle(Theme.ink)
                Spacer()
                Text(index).font(.display(13, weight: .bold)).monospacedDigit()
                    .tracking(1).foregroundStyle(Theme.inkTertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                Text(sub.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: Theme.Space.sm)
                accessory()
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, Theme.Space.xs)
        }
    }

    /// A chart headline's trend chip. Good-direction moves earn the legible green; the other
    /// direction stays quiet ink — no-shame, the chart itself tells that story.
    private struct ChartDelta { let text: String; let good: Bool }

    @ViewBuilder
    private func deltaChip(_ d: ChartDelta) -> some View {
        Text(d.text).font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
            .foregroundStyle(d.good ? MetricColor.positive : Theme.inkSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(d.good ? MetricColor.positive.opacity(0.12)
                                              : Theme.hairline.opacity(0.6)))
    }

    /// The shared card anatomy for a trend chart, Oura/Whoop-style: an uppercase eyebrow, a big
    /// display-face headline (the current value — the card's one-line answer), a trend chip, a
    /// quiet context caption, then the plot. Callers without a headline keep the old title header.
    private func chartSection<C: View>(_ title: String, subtitle: String,
                                       headline: String? = nil, headlineUnit: String? = nil,
                                       delta: ChartDelta? = nil,
                                       explainer: MetricExplainer? = nil,
                                       onOpen: (() -> Void)? = nil,
                                       @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Group {
                    if headline != nil {
                        sectionTitle(title.uppercased())
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                            Text(subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
                .accessibilityHidden(true)   // the collapsed summary below speaks the title
                if let explainer {
                    Spacer(minLength: Theme.Space.sm)
                    // OUTSIDE the collapsed element (the VitalsBoard rule): a card-wide
                    // `children: .ignore` swallowed every ⓘ on this page, so the science behind
                    // distance, pace and the season chart was unreachable by VoiceOver entirely.
                    MetricInfoButton(explainer: explainer)
                }
                // Depth is a promise, not a mystery (the meal-row rule): the quiet chevron says
                // "tap for the full trend" without shouting it. The card-wide tap lives on the
                // container below; the chart plot's own scrub gesture still wins inside the plot.
                if onOpen != nil {
                    if explainer == nil { Spacer(minLength: Theme.Space.sm) }
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            // Everything data-bearing collapses into ONE spoken summary (the plot itself is hard
            // to navigate aurally); the header's ⓘ stays its own element above.
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if let headline {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(headline).font(.display(30, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if let headlineUnit {
                            Text(headlineUnit).font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                        }
                        Spacer(minLength: Theme.Space.sm)
                        if let delta { deltaChip(delta) }
                    }
                    Text(subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .padding(.bottom, Theme.Space.xs)
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(((headline.map { "\($0) \(headlineUnit ?? ""), " } ?? "") + subtitle)
                .replacingOccurrences(of: "↑", with: "up ")
                .replacingOccurrences(of: "↓", with: "down ")
                .replacingOccurrences(of: " · ", with: ", "))
            .accessibilityAddTraits(onOpen != nil ? .isButton : [])
            .accessibilityHint(onOpen != nil ? "Shows the full trend" : "")
            // A tap gesture on the card is invisible to VoiceOver; without this the tap-through
            // announced itself as a button and then did nothing when activated.
            .accessibilityAction { onOpen?() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(card)
        // The Oura tap-through: anywhere on the card that ISN'T the chart plot opens the detail
        // (the plot's own selection gesture takes precedence inside it, so scrubbing survives).
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
    }

    // MARK: Weekly muscle coverage

    /// Working-sets-by-muscle (PRD §22) over the selected range, as WEEKLY set-equivalents (window
    /// total ÷ weeks). The panel grades these absolutely (`.weeklyVolume`): no training → blank
    /// anatomy, light touches → faint tint, sustained volume → the full iridescent burn.
    private var rangeMuscleActivation: [MuscleGroup: Double] {
        cachedActivation ?? MuscleActivation.combined(workouts: workouts.filter {
            $0.startedAt >= Date().addingTimeInterval(-Double(trendRange.activationDays) * 86_400)
        }).mapValues { $0 / Double(trendRange.lookbackWeeks) }
    }
    /// Total distance over the selected range — the panel's windowed distance callout.
    private var rangeDistanceM: Double {
        cachedRangeDistanceM ?? workouts.filter {
            $0.startedAt >= Date().addingTimeInterval(-Double(trendRange.activationDays) * 86_400)
        }.reduce(0) { $0 + ($1.gps?.distanceM ?? 0) }
    }

    /// The card eyebrow. Uppercases here rather than at each call site — "Intensity mix",
    /// "Running fitness", "Heart rate zones" and "Race outlook" were passing Title Case into a
    /// 1.4-tracked 11pt label, so four cards wore letter-spaced sentence text while every
    /// neighbour ("THIS WEEK", "TOTALS", "DAILY MOVEMENT", "RECORD BOOK") wore a proper eyebrow.
    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold))
            .tracking(1.4).foregroundStyle(Theme.inkTertiary)
    }

    /// ONE card in this family: `Theme.surface` with the house hairline.
    ///
    /// Progress was shipping three at once — this one (surface, no edge), the Health/F&F/strength
    /// cards (surface + hairline), and the essentials cards (surface at 60% + hairline). Scrolling
    /// Trends therefore crossed three different card weights, and the lighter essentials cards
    /// read as a different, less finished tier of content than the charts under them. Same fill,
    /// same edge, everywhere — `healthCard()` already defines exactly this.
    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }

    // MARK: - You — what Momentum has learned (ATHLETE-MODEL.md §8)

    /// One surfaced belief: a labelled fact with its confidence, the memory category it maps to, and
    /// the backing note id (if any) for "forget this".
    private struct LearnedItem: Identifiable {
        let title: String
        let value: String
        let confidence: Confidence
        var category: MemoryCategory = .habit
        var noteID: UUID? = nil
        var id: String { title }
    }

    /// The former You tab, folded into Trends and rebuilt around growth: receipts first
    /// (before → after deltas, the season, the record book), then the coach's moves, then the
    /// beliefs behind the plan. Every line is computed from the athlete's own history — no
    /// claim without its number, no number without a consequence.
    private var athleteStory: some View {
        let facts = athleteFacts
        let model = profiles.first?.athlete
        let items = learnedItems(facts, model)
        let deltas = growthDeltas
        // A digest item that can't cite a number doesn't render (receipts, not vibes).
        let nudges = Array(AthleteNudges.generate(facts).filter { $0.text.contains(where: \.isNumber) }.prefix(2))
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            if !deltas.isEmpty { growthCard(deltas).id("growth") }
            // NO second `.proLocked` here: `athleteStory` already renders inside the Trends
            // cluster's single lock, so gating the season chart again stacked two frosted layers
            // (9pt blur twice, two 55% scrims) and floated a SECOND "unlock with Pro" card over
            // the first. One unlock opens the whole page — that's the convention, and one lock
            // is how it should look.
            seasonChart.id("season")
            RecordsCard(distanceUnit: distanceUnit).id("records")
            if !coachingEvents.isEmpty { coachMoves }
            if !nudges.isEmpty { weeklyDigest(nudges) }
            if !items.isEmpty { coachKnows(items, facts: facts) }
        }
    }

    // MARK: - How you've grown (before → after receipts from the weekly snapshots)

    private struct GrowthDelta: Identifiable {
        let label: String
        let from: String
        let to: String
        let period: String
        var id: String { label }
    }

    /// Only deltas that actually exist and actually moved. Nothing here is authored — pace,
    /// volume, and strength are all measured from the athlete's snapshots.
    private var growthDeltas: [GrowthDelta] {
        let snaps = (profiles.first?.athlete?.snapshots ?? []).sorted { $0.weekStart < $1.weekStart }
        var out: [GrowthDelta] = []
        func since(_ d: Date) -> String { "since " + d.formatted(.dateTime.month(.abbreviated)) }
        // Running fitness: Riegel-normalized 5K pace, first vs latest reading.
        let paces = snaps.filter { ($0.p5kEquivSPerKm ?? 0) > 0 }
        if let first = paces.first, let last = paces.last, first.weekStart < last.weekStart,
           let p0 = first.p5kEquivSPerKm, let p1 = last.p5kEquivSPerKm,
           abs(p1 - p0) / p0 >= 0.01 {
            out.append(GrowthDelta(label: "5K PACE",
                                   from: Formatters.pace(secPerKm: p0, unit: distanceUnit),
                                   to: Formatters.pace(secPerKm: p1, unit: distanceUnit),
                                   period: since(first.weekStart)))
        }
        // Weekly volume from the workouts themselves: 3-week averages at each end, so one
        // big week can't fake a trend. The in-progress week is excluded — a half-finished
        // week reads as a fake drop.
        let nowWeek = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
        let vols = weekVolumes.filter { $0.week != nowWeek }
        if vols.count >= 4 {
            let head = vols.prefix(3), tail = vols.suffix(3)
            let a = head.map(\.meters).reduce(0, +) / Double(head.count)
            let b = tail.map(\.meters).reduce(0, +) / Double(tail.count)
            if a > 0, abs(b - a) / a >= 0.10 {
                out.append(GrowthDelta(label: "WEEKLY VOLUME",
                                       from: Formatters.distance(meters: a, unit: distanceUnit),
                                       to: Formatters.distance(meters: b, unit: distanceUnit),
                                       period: "3-wk avg, \(since(vols.first!.week))"))
            }
        }
        // Strength: the lift with the biggest measured e1RM gain between the ends.
        if let firstL = snaps.first(where: { !$0.topE1RMByLift.isEmpty }),
           let lastL = snaps.last(where: { !$0.topE1RMByLift.isEmpty }),
           firstL.weekStart < lastL.weekStart {
            var best: (lift: String, v0: Double, v1: Double)?
            for (lift, v0) in firstL.topE1RMByLift {
                guard v0 > 0, let v1 = lastL.topE1RMByLift[lift], (v1 - v0) / v0 >= 0.03 else { continue }
                if v1 - v0 > (best.map { $0.v1 - $0.v0 } ?? 0) { best = (lift, v0, v1) }
            }
            if let best {
                let unit = weightUnit   // the athlete's preference, matching every sibling strength surface
                out.append(GrowthDelta(label: best.lift.uppercased(),
                                       from: Formatters.weight(kg: best.v0, unit: unit),
                                       to: Formatters.weight(kg: best.v1, unit: unit),
                                       period: "est. 1RM, \(since(firstL.weekStart))"))
            }
        }
        return Array(out.prefix(3))
    }

    private func growthCard(_ deltas: [GrowthDelta]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("HOW YOU'VE GROWN").font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.4).foregroundStyle(Theme.inkTertiary)
            VStack(spacing: 0) {
                ForEach(Array(deltas.enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.label).font(.rounded(Theme.FontSize.label, weight: .bold))
                                .tracking(1.1).foregroundStyle(Theme.inkTertiary)
                            Text(d.period).font(.rounded(Theme.FontSize.label, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        Spacer(minLength: Theme.Space.sm)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(d.from).font(.rounded(15, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.inkTertiary)
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.inkTertiary)
                            // The after-value is earned progress — it wears the accent,
                            // same treatment as the record book.
                            Text(d.to).font(.display(18, weight: .black)).monospacedDigit()
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(IridescentMaterial()).opacity(0.30))
                        }
                    }
                    .padding(.vertical, Theme.Space.sm)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(d.label): \(d.from) to \(d.to), \(d.period)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(card)
    }

    /// The season: labeled weekly distance with record weeks dotted — the story the old naked
    /// "trajectory" line never told.
    @ViewBuilder
    private var seasonChart: some View {
        let weeks = weekVolumes
        let unit = distanceUnit.resolved()
        let divisor = unit == .imperial ? Formatters.metersPerMile : 1000.0
        if weeks.count >= 4 {
            let cal = Calendar.current
            let prWeeks = Set((profiles.first?.prs ?? []).compactMap {
                cal.dateInterval(of: .weekOfYear, for: $0.achievedAt)?.start
            })
            let recordWeeks = weeks.filter { prWeeks.contains($0.week) }
            // "All time" stated, not implied: every other card on this page names its window
            // ("4 WKS", "LAST 7 NIGHTS", the range picker) — this one silently ignored the picker
            // and plotted the whole history, which read as a bug the first time you flipped to 1W.
            chartSection("Your season",
                         subtitle: "All time · weekly \(unit == .imperial ? "miles" : "kilometers") · ● a record week",
                         explainer: MetricExplainers.weeklyDistance) {
                ScrubChartHost(dates: weeks.map(\.week)) { pinned in
                    Chart {
                        ForEach(weeks, id: \.week) { entry in
                            BarMark(x: .value("Week", entry.week, unit: .weekOfYear),
                                    y: .value("Distance", entry.meters / divisor))
                                .foregroundStyle(Theme.ink.opacity(0.8))
                                .cornerRadius(2)
                        }
                        ForEach(recordWeeks, id: \.week) { entry in
                            PointMark(x: .value("Week", entry.week, unit: .weekOfYear),
                                      y: .value("Distance", entry.meters / divisor))
                                .foregroundStyle(AnyShapeStyle(IridescentMaterial()))
                                .symbolSize(70)
                        }
                        if let sel = pinned, let entry = weeks.first(where: { $0.week == sel }) {
                            TrendScrub.mark(at: sel, unit: .weekOfYear,
                                            value: Formatters.distance(meters: entry.meters, unit: distanceUnit),
                                            label: TrendScrub.weekLabel(sel))
                        }
                    }
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    .frame(height: 150)
                }
            }
        }
    }

    /// What the plan is built on — the highest-confidence beliefs in one card, each with its
    /// correction affordance. Beliefs support the story; they aren't the story.
    private func coachKnows(_ items: [LearnedItem], facts: AthleteFacts) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("WHAT YOUR COACH KNOWS").font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.4).foregroundStyle(Theme.inkTertiary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { i, item in
                    if i > 0 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                            .padding(.vertical, Theme.Space.sm)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.title).font(.rounded(Theme.FontSize.label, weight: .bold))
                                .tracking(1.1).foregroundStyle(Theme.inkTertiary)
                            Spacer()
                            confidencePip(item.confidence)
                        }
                        Text(item.value).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        notQuiteRightButton(value: item.value, category: item.category, noteID: item.noteID)
                    }
                }
            }
            if confidentCount(facts) < 3 {
                Text("Based on \(workouts.count) workouts — this read sharpens as you train.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(card)
    }

    /// Whether the deep analytics are unlocked — the whole Progress page's Pro gate.
    private var isAnalyticsPro: Bool { paywallController.isEntitled(to: .advancedAnalytics) }

    /// What the un-entitled athlete's `.proLocked` frost covers — the Pro cluster's FOOTPRINT
    /// (chart-height surface shapes with hairlines), not the live cluster itself. Behind the
    /// radius-9 blur and 0.55 scrim the two are indistinguishable, and this one costs nothing to
    /// build and nothing per scroll frame (perf audit 2026-08-13).
    private var proClusterTeaser: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ForEach(Array([210, 150, 240, 180, 260, 150, 220].enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(Theme.hairline))
                    .frame(height: CGFloat(h))
            }
        }
    }

    /// Free-tier anchor: distance, not VO₂max. Everyone gets to see the miles they ran; the
    /// fitness read (and everything the body's rail carries) is the Pro upgrade.
    ///
    /// Targets the DISTANCE CHART, not "charts". The free callouts used to scroll into the
    /// Pro-locked block — a free athlete tapped their own mileage and landed on a frosted
    /// paywall wall. A free reading must open the free card that explains it.
    private var panelHeroFree: AthleteCallout {
        let context = trendRange == .week && insights.distanceTrendPct >= 3 ? "Trending up" : "Distance covered"
        return AthleteCallout(label: trendRange.distanceNoun,
                              value: Formatters.distance(meters: rangeDistanceM, unit: distanceUnit),
                              unit: nil, context: context, target: "distanceChart")
    }

    /// Under the free-tier hero: how many sessions the athlete banked over the range — a windowed
    /// "how consistent have I been" counterweight to the distance number. Opens the THIS WEEK
    /// strip, which carries the sessions column.
    private var panelSubFree: AthleteCallout {
        let n = cachedRangeSessions ?? 0
        return AthleteCallout(label: "SESSIONS", value: "\(n)", unit: nil,
                              context: n == 1 ? "Workout logged" : "Workouts logged", target: "weekStrip")
    }

    /// The Athlete Panel's anchor stat — VO₂max, the fitness index. Device measurement wins;
    /// context prefers the 8-week trend when the model has one.
    private var panelHero: AthleteCallout {
        if let vo2 = measuredVO2 ?? currentVO2 {
            let context: String
            // The fitness delta over the selected window; falls back to the source when the change
            // is negligible or there's no old snapshot to compare against.
            if let cur = currentVO2, let old = vo2WeeksAgo(trendRange.lookbackWeeks), abs(cur - old) >= 0.3 {
                context = String(format: "%+.1f vs \(trendRange.agoLabel)", cur - old)
            } else {
                context = measuredVO2 != nil ? "From your device" : "Estimated from pace"
            }
            return AthleteCallout(label: "VO₂ MAX", value: String(format: "%.1f", vo2), unit: nil,
                                  context: context, target: "fitness")
        }
        // No VO₂ yet → fitnessHero() renders nothing, so its anchor doesn't exist. Point the
        // tap at the always-present charts block instead of a haptic-then-nothing scroll.
        return AthleteCallout(label: "VO₂ MAX", value: "—", unit: nil,
                              context: "Needs a few runs", target: "charts")
    }

    /// Under the hero: distance banked over the selected window — the "what you actually did"
    /// counterweight to the fitness index, re-windowing with the range picker.
    private var panelSub: AthleteCallout {
        AthleteCallout(label: trendRange.distanceNoun,
                       value: Formatters.distance(meters: rangeDistanceM, unit: distanceUnit),
                       unit: nil, context: "Distance covered", target: "charts")
    }

    /// The right-hand rail: readiness, load, resting heart, muscle focus — each targeting the
    /// scroll id of the card that explains it.
    private var panelRail: [AthleteCallout] {
        var out: [AthleteCallout] = []
        // Readiness — the same cache-first source as the strip (the legacy blendedReadiness
        // offsets read 100 while the hub read 75; one app, one number).
        if let r = todaysReadinessDisplay() {
            out.append(AthleteCallout(label: "READINESS", value: "\(r.score)", unit: "/100",
                                      context: r.band, target: "formRace"))
        } else {
            out.append(AthleteCallout(label: "READINESS", value: "—", unit: nil,
                                      context: "Learning your norm", target: "formRace"))
        }
        // Training load — ACWR with a no-shame band word.
        if insights.chronic >= 1 {
            let word: String = switch insights.acwr {
            case ..<0.8:      "Fresh"
            case 0.8..<1.31:  "Sweet spot"
            case 1.31..<1.51: "Pushing"
            default:          "High — absorb it"
            }
            out.append(AthleteCallout(label: "TRAINING LOAD", value: String(format: "%.2f", insights.acwr),
                                      unit: nil, context: word, target: "charts"))
        } else {
            out.append(AthleteCallout(label: "TRAINING LOAD", value: "—", unit: nil,
                                      context: "Building baseline", target: "charts"))
        }
        // Resting heart — from Apple Health when connected. The zones card only mounts with a
        // known max HR, so target the always-present charts block otherwise — a rail tap must
        // never haptic into a no-op scroll.
        let hrTarget: String = {
            guard let maxHR = profiles.first?.maxHR,
                  HRZones.zones(maxHR: maxHR, restingHR: profiles.first?.restingHR) != nil else { return "charts" }
            return "hrZones"
        }()
        if let rhr = signals.restingHR {
            out.append(AthleteCallout(label: "RESTING HEART", value: "\(rhr)", unit: "bpm",
                                      context: signals.restingHRNote ?? "From Apple Health", target: hrTarget))
        } else {
            out.append(AthleteCallout(label: "RESTING HEART", value: "—", unit: nil,
                                      context: "Connect Health", target: hrTarget))
        }
        // Muscle focus over the selected window — falls back to the intensity mix when it was all
        // cardio (whose card needs 28-day run data to mount — same dead-anchor guard).
        // No window phrase in the rail: these context lines are one clipped line in a ~110pt
        // column, and the panel's own eyebrow already names the window for everything on it —
        // "Most worked over the last 7 days" simply truncated to "Most worked over the last 7…".
        // ("WEEK FOCUS" was wrong at 6M anyway.)
        if let top = rangeMuscleActivation.filter({ $0.key != .fullBody && $0.value > 0 }).max(by: { $0.value < $1.value }) {
            out.append(AthleteCallout(label: "MUSCLE FOCUS", value: top.key.rawValue.capitalized, unit: nil,
                                      context: "Most worked",
                                      target: cachedHasStrength ? "strengthTrends" : "charts"))
        } else {
            out.append(AthleteCallout(label: "TRAINING FOCUS", value: "Endurance", unit: nil,
                                      context: "All cardio",
                                      target: intensityMix != nil ? "intensityMix" : "charts"))
        }
        return out
    }

    /// The coaching timeline — every plan adaptation with its *why*, so the closed loop is legible: the
    /// plan doesn't quietly shift, it keeps the receipt. Monochrome (informational, not an earned accent).
    private var coachMoves: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("YOUR COACH'S MOVES").font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.4).foregroundStyle(Theme.inkTertiary)
            adaptationList(Array(coachingEvents.prefix(3)))
            if coachingEvents.count > 3 {
                Button {
                    Haptics.light(); showAllAdaptations = true
                } label: {
                    Text("See all \(coachingEvents.count) adaptations")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Capsule().stroke(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    /// Every adaptation, in a sheet — the full receipt trail behind the capped card.
    private var adaptationSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("How your plan adapted").font(.display(24, weight: .black)).foregroundStyle(Theme.ink)
                adaptationList(Array(coachingEvents))
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.background)
        .presentationDetents([.large, .medium])
    }

    private func adaptationList(_ events: [CoachingEvent]) -> some View {
            VStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { i, event in
                    HStack(alignment: .top, spacing: Theme.Space.md) {
                        VStack(spacing: 0) {
                            Image(systemName: event.kind.systemImage)
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                                .frame(width: 34, height: 34)
                                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                            if i < events.count - 1 {
                                Rectangle().fill(Theme.hairline).frame(width: 1.5).frame(maxHeight: .infinity)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(event.headline).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                                Spacer(minLength: Theme.Space.sm)
                                Text(eventRelativeDay(event.date)).font(.rounded(Theme.FontSize.label, weight: .semibold))
                                    .foregroundStyle(Theme.inkTertiary)
                            }
                            Text(event.detail).font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, i < events.count - 1 ? Theme.Space.md : 0)
                    }
                }
            }
    }

    private func eventRelativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        return days < 7 ? "\(days)d ago" : date.formatted(.dateTime.month().day())
    }

    /// A quiet "not quite right?" affordance that opens the correction sheet.
    private func notQuiteRightButton(value: String, category: MemoryCategory, noteID: UUID?) -> some View {
        Button {
            Haptics.light()
            correcting = LearnedItem(title: "correction", value: value, confidence: .confident,
                                     category: category, noteID: noteID)
        } label: {
            Text("Not quite right?").font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary).underline()
        }
        .buttonStyle(.plain)
    }

    /// Proactive nudges the model surfaces on its own (§9). Titled "WHAT WE NOTICED", not
    /// "THIS WEEK" — the essentials strip at the top of the same scroll already owns THIS WEEK,
    /// and two cards wearing one eyebrow made the page look like it had lost its place.
    private func weeklyDigest(_ nudges: [AthleteNudges.Nudge]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("WHAT WE NOTICED").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            ForEach(nudges) { nudge in
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    Image(systemName: nudge.kind.systemImage)
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(IridescentMaterial()).opacity(0.3))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nudge.title).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(nudge.text).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(card)
    }

    private func confidencePip(_ c: Confidence) -> some View {
        let filled = c == .confident ? 3 : (c == .growing ? 2 : 1)
        return HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(i < filled ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.hairline))
                    .frame(width: 5, height: 5)
            }
        }
        // The filled-pip count maps to a confidence level; name it so the meaning isn't color-only.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Confidence")
        .accessibilityValue("\(c.rawValue.capitalized), \(filled) of 3")
    }

    // MARK: You — fact → copy

    private func confidence(_ signal: AthleteModelEngine.Signal, _ facts: AthleteFacts) -> Confidence {
        AthleteModelEngine.confidence(signal, count: facts.signalSampleCounts[signal.rawValue] ?? 0)
    }

    private func confidentCount(_ facts: AthleteFacts) -> Int {
        AthleteModelEngine.Signal.allCases.filter { confidence($0, facts) == .confident }.count
    }

    /// Builds the surfaced cards from confident/growing facts (emerging signals are held back).
    /// A category the user has corrected (a pinned user note) hides the derived card and shows the
    /// correction instead — so a correction visibly "sticks".
    private func learnedItems(_ facts: AthleteFacts, _ model: AthleteModel?) -> [LearnedItem] {
        var items: [LearnedItem] = []
        let pinnedUser = (model?.notes ?? []).filter {
            $0.isActive && $0.pinned && $0.source == MemorySource.user.rawValue
        }
        let corrected = Set(pinnedUser.map(\.category))
        func addDerived(_ item: LearnedItem) {
            if !corrected.contains(item.category.rawValue) { items.append(item) }
        }

        // Rhythm (.habit)
        let rhythmC = confidence(.rhythm, facts)
        if rhythmC != .emerging, let daypart = daypartLabel(facts.trainingHourHistogram) {
            let mins = Int(facts.preferredSessionMinutes)
            let lenBit = mins > 0 ? ", usually \(mins) min" : ""
            addDerived(.init(title: "YOUR RHYTHM", value: "\(daypart) workouts\(lenBit).",
                             confidence: rhythmC, category: .habit))
        }

        // Getting fitter — easy pace at matched effort (.response)
        let paceC = confidence(.paceAtEffort, facts)
        if paceC != .emerging, facts.paceAtEffortTrendPct <= -1 {
            let pct = Int(abs(facts.paceAtEffortTrendPct).rounded())
            addDerived(.init(title: "YOU'RE GETTING FITTER",
                             value: "Easy pace down \(pct)% at the same effort over recent weeks.",
                             confidence: paceC, category: .response))
        }

        // Strength trending up (.response)
        if !corrected.contains(MemoryCategory.response.rawValue),
           let top = facts.e1rmTrendByExercise.filter({ $0.value >= 1 }).max(by: { $0.value < $1.value }) {
            let pct = Int(top.value.rounded())
            items.append(.init(title: "STRENGTH TRENDING UP", value: "\(top.key) e1RM up \(pct)% lately.",
                               confidence: confidence(.strengthProgress, facts), category: .response))
        }

        // Discipline mix (.preference)
        let mixC = confidence(.disciplineMix, facts)
        if mixC != .emerging, !facts.disciplineShare.isEmpty {
            let parts = facts.disciplineShare.sorted { $0.value > $1.value }.prefix(3).map { kv -> String in
                let name = WorkoutType(rawValue: kv.key)?.title ?? kv.key.capitalized
                return "\(name) \(Int((kv.value * 100).rounded()))%"
            }
            addDerived(.init(title: "HOW YOU TRAIN", value: parts.joined(separator: " · "),
                             confidence: mixC, category: .preference))
        }

        // What drives you — onboarding-seeded motivation (.motivation)
        if !corrected.contains(MemoryCategory.motivation.rawValue),
           let m = model?.notes.first(where: {
               $0.isActive && $0.source != MemorySource.user.rawValue && $0.category == MemoryCategory.motivation.rawValue
           }) {
            items.append(.init(title: "WHAT DRIVES YOU", value: m.text,
                               confidence: Confidence(rawValue: m.confidence) ?? .emerging,
                               category: .motivation, noteID: m.id))
        }

        // The user's own corrections, shown so they visibly stick (identity lives in the hero).
        for note in pinnedUser where note.category != MemoryCategory.identity.rawValue {
            let cat = MemoryCategory(rawValue: note.category) ?? .habit
            items.append(.init(title: "\(categoryTitle(cat)) · YOU TOLD US", value: note.text,
                               confidence: .confident, category: cat, noteID: note.id))
        }

        return items
    }

    private func categoryTitle(_ c: MemoryCategory) -> String {
        switch c {
        case .habit: "YOUR RHYTHM"
        case .preference: "HOW YOU TRAIN"
        case .response: "YOUR BODY"
        case .motivation: "WHAT DRIVES YOU"
        case .risk: "HEADS UP"
        case .identity: "WHO YOU ARE"
        }
    }

    /// The part of day the athlete trains most, if there's a clear peak.
    private func daypartLabel(_ hist: [Int]) -> String? {
        guard hist.count == 24, hist.reduce(0, +) > 0 else { return nil }
        let peak = hist.indices.max { hist[$0] < hist[$1] } ?? 0
        switch peak {
        case 5..<11: return "Morning"
        case 11..<17: return "Afternoon"
        case 17..<22: return "Evening"
        default: return "Late-night"
        }
    }
}

/// A History-feed row thumbnail. Decodes the persisted map snapshot ONCE into `@State`, off the
/// render path — the feed's non-lazy `ForEach` previously re-ran `UIImage(data:)` for every GPS row
/// on each re-render. Falls back to the discipline glyph and self-heals a missing snapshot (re-render
/// + persist) exactly like the profile grid tiles.
private struct HistoryFeedThumb: View {
    let workout: Workout
    @Environment(\.modelContext) private var context
    @State private var image: UIImage?

    /// Row-thumb LRU: a lazily-realized row that scrolls back into view re-faulted the 1320×1760
    /// external-storage blob and re-decoded it every time. Bounded (NSCache evicts under pressure),
    /// value-typed, keyed by workout id.
    @MainActor private static let thumbs: NSCache<NSUUID, UIImage> = {
        let c = NSCache<NSUUID, UIImage>()
        c.countLimit = 200
        return c
    }()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 13))
                    // Hairline ring so light basemaps don't bleed into the card with no edge.
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.hairline))
            } else {
                RoundedRectangle(cornerRadius: 13).fill(Theme.surface)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: workout.type.systemImage)
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.hairline))
            }
        }
        .task(id: workout.id) {
            let key = workout.id as NSUUID
            if let hit = Self.thumbs.object(forKey: key) {
                image = hit
                return
            }
            // Snapshots persist at 1320×1760px; decode a row-sized thumbnail via ImageIO off the
            // main actor instead of a full-res bitmap per 52pt row (156 ≈ 52pt @3x).
            if let data = workout.gps?.mapSnapshotData,
               let img = await ImageDownsampler.thumbnail(data, maxPixel: 156) {
                image = img
                Self.thumbs.setObject(img, forKey: key)
            } else {
                // No (or unreadable) snapshot — self-heal, then pick up the freshly-rendered one.
                await WorkoutSnapshotHealer.healIfNeeded(workout, context: context)
                if let data = workout.gps?.mapSnapshotData,
                   let img = await ImageDownsampler.thumbnail(data, maxPixel: 156) {
                    image = img
                    Self.thumbs.setObject(img, forKey: key)
                }
            }
        }
    }
}
