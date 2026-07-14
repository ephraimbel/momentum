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
    @State private var animateCharts = false
    @State private var adjustedPlan = false
    @State private var segment: Segment = {
        #if DEBUG   // deterministic segment deep-links for sim verification (tab taps are flaky)
        let a = ProcessInfo.processInfo.arguments
        if a.contains("--progress-history") { return .history }
        #endif
        return .trends
    }()
    @State private var correcting: LearnedItem?
    @State private var showVO2Info = false
    @State private var showLogWorkout = false
    @State private var signals: RecoverySignals = .empty   // HRV / resting HR / sleep from Apple Health
    @State private var measuredVO2: Double?                 // device-measured VO₂max (Watch/Garmin), if any
    @State private var connectingHealth = false
    @State private var didUpkeep = false                     // athlete-model upkeep runs once per screen
    @State private var aggregatedForCount = -1               // .task(id:) re-fires on every tab visit; only re-walk when data moved
    @State private var showAllAdaptations = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Segment: String, CaseIterable, Identifiable {
        case trends = "Trends", history = "History"
        var id: Self { self }
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
    }
    @State private var trendRange: TrendRange = .week

    private var plan: TrainingPlan? { profiles.first?.plan }

    private var distanceUnit: DistanceUnit { .auto }
    private var weightUnit: WeightUnit { WeightUnit(rawValue: profiles.first?.weightUnit ?? "") ?? .default() }

    // These aggregates walk EVERY workout (and its sets). As computed vars they re-ran on every
    // property access — `insights` alone is read 30+ times per body evaluation, so one tab switch
    // recomputed the full ACWR/CTL/ATL/TSB pipeline dozens of times. Cached per data change instead;
    // the fallback keeps the very first frame correct before the task lands.
    @State private var cachedStats: ProfileStats?
    @State private var cachedInsights: ProgressInsights?
    @State private var cachedRecovery: RecoveryModel?
    /// Workouts whose History row earned the PR badge — precomputed (detection fetches the full
    /// history per call; running it per visible row made History scrolling stutter).
    @State private var prBadgeIDs: Set<UUID>?
    /// The athlete-model read and the week's muscle/load work also walk every workout (the
    /// engine re-derives all its facts). Since the You merge they render inside Trends, so an
    /// uncached read re-ran them on every body evaluation — that was the tab's load stutter.
    @State private var cachedFacts: AthleteFacts?
    @State private var cachedActivation: [MuscleGroup: Double]?
    @State private var cachedFormPoint: FitnessFreshness.Point?
    /// Full-history weekly distance buckets — the season chart and volume delta read the
    /// workouts themselves (snapshots only accumulate one per week of app use).
    @State private var cachedWeekVolumes: [(week: Date, meters: Double)]?

    private var aggregatesReady: Bool { cachedInsights != nil }

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
    private var recovery: RecoveryModel { cachedRecovery ?? RecoveryModel(workouts: workouts) }
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
        cachedStats = ProfileStats(workouts: workouts, plan: profiles.first?.plan)
        cachedInsights = ProgressInsights(workouts: workouts, weeksBack: trendRange.weeks)
        cachedRecovery = RecoveryModel(workouts: workouts)
        prBadgeIDs = Set(workouts.filter { feedIsPRUncached($0) }.map(\.id))
        cachedFacts = AthleteModelEngine(workouts: workouts, plan: plan).facts
        cachedActivation = computeWeeklyMuscleActivation()
        cachedFormPoint = computeFormPoint()
        cachedWeekVolumes = computeWeekVolumes()
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
                case .history: history
                }
            } else {
                warmup
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .sheet(isPresented: $showVO2Info) { vo2InfoSheet.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showLogWorkout) { LogWorkoutView() }
        .sheet(isPresented: $showAllAdaptations) { adaptationSheet }
        .sheet(item: $correcting) { item in
            if let profile = profiles.first {
                CorrectionSheet(belief: item.value, category: item.category, noteID: item.noteID, profile: profile)
                    .presentationDetents([.medium])
            }
        }
        // Range flips only re-window the weekly series — the ACWR/status verdict and the other
        // aggregates are window-independent, so nothing else needs recomputing.
        .onChange(of: trendRange) {
            withAnimation(.easeOut(duration: 0.35)) {
                cachedInsights = ProgressInsights(workouts: workouts, weeksBack: trendRange.weeks)
            }
        }
        .task(id: workouts.count) {
            if aggregatedForCount != workouts.count {
                await Task.yield()   // let the skeleton frame paint before the heavy pass
                withAnimation(.easeOut(duration: 0.2)) { refreshAggregates() }
                aggregatedForCount = workouts.count
            }
            // Athlete-model upkeep (was the You tab's onAppear — idempotent, local-only).
            // Once per screen instance, and after first paint: ingest re-walks history.
            guard !didUpkeep, let p = profiles.first else { return }
            didUpkeep = true
            services.athleteModel.seedOnboarding(for: p, in: context)
            services.athleteModel.ingest(profile: p, in: context)
            RecordsBook.backfillIfNeeded(in: context)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text("Progress").font(.display(34, weight: .black)).foregroundStyle(Theme.ink)
            Spacer()
            if let cachedStats { StreakChip(days: cachedStats.currentStreak) }
            if segment == .history {
                Button { Haptics.light(); showLogWorkout = true } label: {
                    Image(systemName: "plus").font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Add a past workout")
            }
            NavigationLink { SettingsView() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
    }

    private var segmentControl: some View {
        HStack(spacing: 4) {
            ForEach(Segment.allCases) { seg in
                Button { Haptics.selection(); withAnimation(.easeOut(duration: 0.2)) { segment = seg } } label: {
                    Text(seg.rawValue)
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(segment == seg ? Theme.background : Theme.ink)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background { if segment == seg { Capsule().fill(Theme.ink) } }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.surface))
    }

    /// Compact 1M · 3M · 6M window switcher for the trend charts — one tap re-windows the weekly
    /// series (the axis label density and the whole chart block adapt to the wider ranges).
    private var trendRangePicker: some View {
        HStack(spacing: 2) {
            ForEach(TrendRange.selectable) { range in
                let on = trendRange == range
                Button {
                    Haptics.selection()
                    withAnimation(Motion.standard) { trendRange = range }
                } label: {
                    Text(range.rawValue)
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Theme.background : Theme.inkSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background { if on { Capsule().fill(Theme.ink) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.accessibilityLabel)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.surface))
    }

    private var trends: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    // The hero: the athlete's own body with the week's physiology read off it.
                    // Every callout is a door into the detail card it summarizes.
                    // FREE — the athlete's own body, the hero teaser (readable summary callouts;
                    // the detail each one opens is Pro).
                    AthletePanel(activation: weeklyMuscleActivation,
                                 sex: BodySex(profileSex: profiles.first?.sex),
                                 hero: isAnalyticsPro ? panelHero : panelHeroFree,
                                 sub: isAnalyticsPro ? panelSub : panelSubFree,
                                 rail: panelRail,
                                 pro: isAnalyticsPro,
                                 onSelect: { target in
                        withAnimation(.easeOut(duration: 0.45)) { proxy.scrollTo(target, anchor: .top) }
                    },
                                 onLockedTap: { paywallController.present(for: .advancedAnalytics) })
                    .reveal(0)
                    // FREE — distance is the one chart everyone gets: total + miles per week.
                    HStack { Spacer(); trendRangePicker }
                        .reveal(0.02)
                    distanceChart(insights).reveal(0.03)
                    // PRO — the fitness read (VO₂max), heart-rate zones, load/pace/intensity, the
                    // deep-dive analytics, and the coaching. One unlock opens the whole premium page.
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        fitnessHero().id("fitness")
                        hrZonesCard.id("hrZones")
                        trendMetrics()
                        loadChart(insights)
                        if insights.weeks.contains(where: { $0.avgPaceSPerKm > 0 }) { paceChart(insights) }
                        intensityMixCard.id("intensityMix")
                        // The fitness/freshness curve, cadence, climb, aerobic efficiency.
                        ProTrendsSection(workouts: workouts, distanceUnit: distanceUnit, pro: isAnalyticsPro).id("proTrends")
                        // Strength progression — renders nothing without lifting history.
                        StrengthProgressSection(workouts: workouts, weightUnit: weightUnit, pro: isAnalyticsPro).id("strengthTrends")
                        // "How am I right now", "what can I run", and what the coach has learned.
                        formCard(recovery).id("formRace")
                        raceOutlook()
                        coachCard(insights)
                        athleteStory
                    }
                    .reveal(0.06)
                    .id("charts")
                    .proLocked(.advancedAnalytics)
                }
                .padding(Theme.Space.md)
                .padding(.bottom, Theme.Space.xxl)
            }
            .onAppear {
                if reduceMotion { animateCharts = true }                               // no chart build-in
                else { withAnimation(.easeOut(duration: 0.9)) { animateCharts = true } }
                #if DEBUG   // deterministic scroll to Form/Race for sim verification
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-zones") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("hrZones", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-mix") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("intensityMix", anchor: .center) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-protrends") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("proTrends", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-strength") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("strengthTrends", anchor: .top) }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-charts") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("charts", anchor: .top) }
                    // Pair with --trend-range-{3m,6m,1y} to land on a wide window (picker verification).
                    let ranges: [(String, TrendRange)] = [("--trend-range-3m", .threeMonths),
                                                          ("--trend-range-6m", .sixMonths),
                                                          ("--trend-range-1y", .year)]
                    if let hit = ranges.first(where: { ProcessInfo.processInfo.arguments.contains($0.0) }) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { trendRange = hit.1 }
                    }
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
                async let s = services.health.recoverySignals()
                async let v = services.health.measuredVO2Max()
                signals = await s
                measuredVO2 = await v
            }
        }
    }

    // MARK: - Fitness · Form · Race (running-excellence R4/R5 surfaced)

    private var latestSnapshot: FitnessSnapshot? {
        profiles.first?.athlete?.snapshots.max(by: { $0.weekStart < $1.weekStart })
    }
    /// Best current running-fitness proxy: the athlete-model's Riegel-normalized 5k pace, else the plan's.
    private var currentP5k: Double? {
        if let p = latestSnapshot?.p5kEquivSPerKm, p > 0 { return p }
        if let p = plan?.p5kSPerKm, p > 0 { return p }
        return nil
    }
    /// VO₂max estimate from current fitness (P5k treated as a 5k effort — Daniels' VDOT).
    private var currentVO2: Double? {
        currentP5k.flatMap { VO2maxEstimator.fromRace(distanceM: 5000, timeS: $0 * 5) }
    }
    private var vo2EightWeeksAgo: Double? {
        guard let athlete = profiles.first?.athlete,
              let cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -8, to: Date()) else { return nil }
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
    /// Daily training load over the last 9 weeks → CTL/ATL/Form (Fitness/Fatigue/Form).
    private var formPoint: FitnessFreshness.Point? { cachedFormPoint ?? computeFormPoint() }
    private func computeFormPoint() -> FitnessFreshness.Point? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -62, to: today) else { return nil }
        var buckets: [Date: Double] = [:]
        for w in workouts where w.startedAt >= start {
            buckets[cal.startOfDay(for: w.startedAt), default: 0] += TrainingLoad.session(w)
        }
        let loads = (0...62).map { i -> Double in
            let day = cal.date(byAdding: .day, value: i - 62, to: today) ?? today
            return buckets[cal.startOfDay(for: day)] ?? 0
        }
        return FitnessFreshness.current(dailyLoads: loads)
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

    private var athleteAge: Int {
        (profiles.first?.birthYear).map { max(14, Calendar.current.component(.year, from: Date()) - $0) } ?? 35
    }
    private var athleteMale: Bool { BiologicalSex(rawValue: profiles.first?.sex ?? "") != .female }

    /// A good-vs-bad range for VO₂max: the athlete's rating for their age + sex, and where they sit on a
    /// muted→iridescent track (higher = fitter = the earned accent).
    @ViewBuilder
    private func vo2RangeBar(_ vo2: Double) -> some View {
        let age = athleteAge, male = athleteMale
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

    /// The last 28 days of runs → the 80/20 polarized check (prescribed quality outranks the pace read).
    private var intensityMix: IntensityMix.Mix? {
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
                    sectionTitle("Intensity mix")
                    Spacer()
                    Text("4 WKS").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.1)
                        .foregroundStyle(Theme.inkTertiary)
                    MetricInfoButton(explainer: MetricExplainers.intensityMix).padding(.leading, 2)
                }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md).background(card)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Intensity mix over four weeks: \(Int((mix.easyFraction * 100).rounded())) percent easy. \(mix.blurb)")
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
                    .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("W", pt.date, unit: .weekOfYear), y: .value("VO2", animateCharts ? pt.vo2 : lo))
                    .foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
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

    /// CTL/ATL Form only reads true after ~6 weeks of training — on a fresh account CTL sits near 0 and
    /// TSB pegs deeply negative even when you're rested. Require enough history before showing Form.
    private var hasFormHistory: Bool {
        let cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -5, to: Date()) ?? Date()
        return workouts.count >= 10 && workouts.contains { $0.startedAt <= cutoff }
    }

    /// FORM & READINESS — Form (CTL−ATL) on a Buried→Peaked scale, next to the readiness ring. Falls
    /// back to the plain recovery card until there's enough load history for a trustworthy Form read.
    @ViewBuilder
    private func formCard(_ r: RecoveryModel) -> some View {
        if r.hasData, hasFormHistory, let form = formPoint {
            let score = signals.blendedReadiness(base: r.score)
            let band = RecoveryModel.band(score)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    sectionTitle("Form & readiness — now")
                    Spacer()
                    if signals.hasPhysio { fromDevicesChip }
                    MetricInfoButton(explainer: MetricExplainers.recoveryForm).padding(.leading, 2)
                }
                HStack(spacing: Theme.Space.md) {
                    readinessRing(score: score)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(band.rawValue).font(.display(20, weight: .black)).foregroundStyle(Theme.ink)
                        Text(RecoveryModel.guidance(band)).font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(form.tsb >= 0 ? "+" : "")\(Int(form.tsb.rounded()))")
                            .font(.display(24, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        Text(FitnessFreshness.formLabel(form.tsb)).font(.rounded(Theme.FontSize.label, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                formBar(tsb: form.tsb)
                if signals.hasPhysio {
                    Divider().overlay(Theme.hairline)
                    signalsRow
                } else {
                    Divider().overlay(Theme.hairline)
                    recoveryUpsell
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md).background(card)
        } else {
            recoveryCard(r)
        }
    }

    private func formBar(tsb: Double) -> some View {
        let frac = max(0, min(1, (tsb + 40) / 70))   // −40 (buried) … +30 (peaked)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(IridescentMaterial()).opacity(0.5).frame(width: w * 0.22).offset(x: w * 0.46)
                    Circle().fill(Theme.ink).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                        .offset(x: max(0, min(w - 14, w * frac - 7)))
                }
            }
            .frame(height: 12)
            HStack {
                Text("Buried"); Spacer(); Text("Balanced"); Spacer(); Text("Peaked")
            }
            .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
        }
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

    /// The at-a-glance trend row — free + up top, so "how I'm trending" reads before the Pro charts.
    private func trendMetrics() -> some View {
        let paceFaster = insights.paceTrendPct < -1
        let cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -12, to: Date()) ?? Date()
        let km = Int((workouts.filter { $0.startedAt >= cutoff }.compactMap { $0.gps?.distanceM }.reduce(0, +) / 1000).rounded())
        return HStack(spacing: Theme.Space.sm) {
            metricTile(paceFaster ? "▲ \(Int(abs(insights.paceTrendPct).rounded()))%" : "Steady",
                       paceFaster ? "Faster / 8 wk" : "Pace", iris: paceFaster)
            metricTile("\(km)", "km · 12 wk", iris: false)
            metricTile("\(profiles.first?.prs.count ?? 0)", "PRs", iris: false)
        }
    }

    private func metricTile(_ value: String, _ label: String, iris: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(19, weight: .heavy)).monospacedDigit()
                // "Faster" is a good-direction move → legible emerald, matching the vitals chips.
                .foregroundStyle(iris ? AnyShapeStyle(MetricColor.positive) : AnyShapeStyle(Theme.ink))
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.5).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, Theme.Space.md)
        .background(card)
    }

    // MARK: - History (clean session feed)

    private var history: some View {
        // Free tier: the last 30 days (PRD §10 "limited history"); everything older is Pro.
        let hasFullHistory = paywallController.isEntitled(to: .fullHistory)
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        let visible = hasFullHistory ? workouts : workouts.filter { $0.startedAt >= cutoff }
        let lockedCount = workouts.count - visible.count
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                historySummary().reveal(0)
                // The personal heatmap lives HERE as a look-back card (decided 2026-06 — never a tab).
                // Rescued from the retired standalone History screen during the lean-cleanup pass.
                HeatmapHistoryCard(workouts: workouts, distanceUnit: distanceUnit).reveal(0.04)
                ForEach(Array(monthGroups(visible).enumerated()), id: \.element.key) { gi, group in
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(group.key.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold))
                            .tracking(0.8).foregroundStyle(Theme.inkSecondary).padding(.leading, 2)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { i, w in
                                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                                workoutFeedRow(w)
                            }
                        }
                        .padding(.horizontal, Theme.Space.md)
                        .background(card)
                    }
                    .reveal(min(0.28, 0.06 + Double(gi) * 0.05))
                }
                if lockedCount > 0 {
                    Button { paywallController.present(for: .fullHistory) } label: {
                        HStack(spacing: Theme.Space.sm) {
                            Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(lockedCount) earlier workout\(lockedCount == 1 ? "" : "s")")
                                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                                Text("Unlock your full history with Pro")
                                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            }
                            Spacer()
                            Image(systemName: "sparkles").font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(Theme.ink)
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

    /// This-month summary strip: sessions, distance, PRs.
    private func historySummary() -> some View {
        let cal = Calendar.current
        let month = cal.dateInterval(of: .month, for: Date())
        let mine = workouts.filter { month?.contains($0.startedAt) ?? false }
        let km = Int((mine.compactMap { $0.gps?.distanceM }.reduce(0, +) / 1000).rounded())
        return HStack(spacing: 0) {
            summaryCell("\(mine.count)", "Sessions")
            Divider().frame(height: 34).overlay(Theme.hairline)
            summaryCell("\(km)", "km this month")
            Divider().frame(height: 34).overlay(Theme.hairline)
            summaryCell("\(profiles.first?.prs.count ?? 0)", "PRs")
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

    /// Workouts grouped by month, newest first.
    private func monthGroups(_ source: [Workout]) -> [(key: String, items: [Workout])] {
        let sorted = source.sorted { $0.startedAt > $1.startedAt }
        let fmt = Date.FormatStyle.dateTime.month(.wide).year()
        var order: [String] = []
        var map: [String: [Workout]] = [:]
        for w in sorted {
            let key = w.startedAt.formatted(fmt)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(w)
        }
        return order.map { ($0, map[$0] ?? []) }
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

    @ViewBuilder
    private func feedThumb(_ w: Workout) -> some View {
        if let data = w.gps?.mapSnapshotData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 13))
                // Same hairline ring as the glyph fallback — light basemaps otherwise bleed into
                // the card with no edge.
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.hairline))
        } else {
            RoundedRectangle(cornerRadius: 13).fill(Theme.surface)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: w.type.systemImage).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.hairline))
                // Self-heal like the grid tiles: a GPS workout whose finish-time snapshot render
                // failed re-renders + persists here, beyond the launch sweep's recency window.
                .task(id: w.id) { await WorkoutSnapshotHealer.healIfNeeded(w, context: context) }
        }
    }

    private func feedTitle(_ w: Workout) -> String {
        if !w.title.isEmpty { return w.title }
        if w.type.discipline == .running, let rt = w.plannedSession?.runType { return "\(rt.rawValue.capitalized) run" }
        return w.type.title
    }
    private func feedSubtitle(_ w: Workout) -> String {
        let day = w.startedAt.formatted(.dateTime.weekday(.abbreviated).day())
        let kind = w.plannedSession?.runType?.rawValue.capitalized ?? w.type.title
        return "\(day) · \(kind)"
    }
    private func feedStats(_ w: Workout) -> [String] {
        if let gps = w.gps, gps.distanceM > 0 {
            let dist = Formatters.distance(meters: gps.distanceM, unit: distanceUnit)
            let pace = w.type == .ride
                ? Formatters.speed(ms: w.durationS > 0 ? gps.distanceM / w.durationS : 0, unit: distanceUnit)
                : Formatters.pace(secPerKm: w.durationS > 0 ? w.durationS / (gps.distanceM / 1000) : 0, unit: distanceUnit)
            return [dist, pace, Formatters.duration(s: w.durationS)]
        }
        if let s = w.strength {
            return ["\(s.exercises.count) exercises", Formatters.duration(s: w.durationS)]
        }
        return [Formatters.duration(s: w.durationS)]
    }
    private func feedIsPR(_ w: Workout) -> Bool {
        prBadgeIDs?.contains(w.id) ?? false
    }

    /// One full detection pass — only ever run from `refreshAggregates`, never per row.
    private func feedIsPRUncached(_ w: Workout) -> Bool {
        // The cardio detector early-returns [] for strength, so lifts need their own check — a bench
        // PR celebrated on the summary shouldn't vanish from the feed.
        if w.type.isStrengthStyle {
            return !StrengthPRs.detect(for: w, weightUnit: .default(), in: context).isEmpty
        }
        return !CardioAchievements.detect(for: w, distanceUnit: distanceUnit, in: context).isEmpty
    }

    // MARK: Status hero

    private func statusHero(_ insights: ProgressInsights) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("TRAINING STATUS").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            Text(insights.status.rawValue).font(.display(28, weight: .black)).foregroundStyle(Theme.ink)
            acwrGauge(insights.acwr)
            Text(gaugeCaption(insights)).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(card)
    }

    private func acwrGauge(_ acwr: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                // Optimal band (ACWR 0.8–1.3 on a 0–2 scale).
                Capsule().fill(IridescentMaterial()).opacity(0.55)
                    .frame(width: w * 0.25).offset(x: w * 0.40)
                Circle().fill(Theme.ink).frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                    .offset(x: max(0, min(w - 16, w * min(1, acwr / 2) - 8)))
            }
        }
        .frame(height: 16)
    }

    private func gaugeCaption(_ insights: ProgressInsights) -> String {
        guard insights.acwr > 0 else { return "Build a couple of weeks and your load balance shows here." }
        return "Load balance \(String(format: "%.2f", insights.acwr)) · sweet spot is 0.8–1.3"
    }

    // MARK: Recovery / readiness (PRD §4.8)

    @ViewBuilder
    private func recoveryCard(_ r: RecoveryModel) -> some View {
        if r.hasData {
            // Blend the load-derived readiness with device signals (HRV / resting HR / sleep) when present.
            let score = signals.blendedReadiness(base: r.score)
            let band = RecoveryModel.band(score)
            let guidance = RecoveryModel.guidance(band)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Text("RECOVERY").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                    if signals.hasPhysio { fromDevicesChip }
                }
                HStack(spacing: Theme.Space.lg) {
                    readinessRing(score: score)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(band.rawValue).font(.display(24, weight: .black)).foregroundStyle(Theme.ink)
                        Text(guidance).font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Divider().overlay(Theme.hairline)
                // Device users get the physiological trio (HRV / resting HR / sleep, each vs their
                // baseline); everyone else gets the load-derived readout.
                if signals.hasPhysio {
                    signalsRow
                } else {
                    HStack(alignment: .top, spacing: Theme.Space.lg) {
                        recoveryMetric(Formatters.compact(r.weeklyLoad), "Weekly load", loadVsUsual(r.acwr))
                        recoveryMetric("\(r.restDays)", "Rest days", "of last 7")
                        recoveryMetric(varietyWord(r.monotony), "Training mix", varietyNote(r.monotony))
                    }
                    recoveryUpsell.padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .background(card)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recovery, \(band.rawValue)")
            .accessibilityValue("Readiness \(score) of 100. \(guidance)\(signalsAXSummary)")
        }
    }

    /// The physiological trio read from Apple Health — HRV, resting HR, last night's sleep — each
    /// anchored to the athlete's own baseline. Only the signals that are actually present render.
    @ViewBuilder
    private var signalsRow: some View {
        // Units (ms for HRV, bpm for resting HR) are conventional enough to leave off — the note carries
        // the meaning ("above your norm"), and appending "· ms" only forces an ugly wrap.
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            if let v = signals.hrvValue { recoveryMetric(v, "HRV", signals.hrvNote) }
            if let v = signals.restingHRValue { recoveryMetric(v, "Resting HR", signals.restingHRNote) }
            if let v = signals.sleepValue { recoveryMetric(v, "Sleep", signals.sleepNote) }
        }
    }

    /// The no-device state — honest, never a nagging popup. If Health isn't connected yet, a tappable
    /// row opens the permission flow (and re-reads on grant); if it's connected but no wearable is
    /// writing HRV/sleep, a quiet line explains why. Either way the readiness above stays valid — it's
    /// load-based, not wrong.
    @ViewBuilder
    private var recoveryUpsell: some View {
        if services.health.isAuthorized {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "applewatch").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                Text("Add an Apple Watch, Garmin, or Oura ring and your HRV & sleep will sharpen this automatically.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Button {
                connectingHealth = true
                Task {
                    _ = await services.health.requestAuthorization()
                    async let s = services.health.recoverySignals()
                    async let v = services.health.measuredVO2Max()
                    signals = await s; measuredVO2 = await v
                    connectingHealth = false
                }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "applewatch").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Connect Apple Health for HRV & sleep-based readiness")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(connectingHealth)
        }
    }

    /// Small "from your devices" attribution so users know the readiness is device-backed, not guessed.
    private var fromDevicesChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "applewatch").font(.system(size: 9, weight: .bold))
            Text("FROM YOUR DEVICES").font(.rounded(9, weight: .bold)).tracking(0.5)
        }
        .foregroundStyle(Theme.inkTertiary)
    }

    private var signalsAXSummary: String {
        guard signals.hasPhysio else { return "" }
        var parts: [String] = []
        if let v = signals.hrvValue, let n = signals.hrvNote { parts.append("HRV \(v) milliseconds, \(n)") }
        if let v = signals.restingHRValue, let n = signals.restingHRNote { parts.append("resting heart rate \(v), \(n)") }
        if let v = signals.sleepValue, let n = signals.sleepNote { parts.append("sleep \(v), \(n)") }
        return parts.isEmpty ? "" : ". From your devices: " + parts.joined(separator: ", ")
    }

    private func readinessRing(score: Int) -> some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 8)
            Circle().trim(from: 0, to: max(0.01, Double(score) / 100))
                .stroke(IridescentMaterial(), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.display(22, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
        }
        .frame(width: 72, height: 72)
    }

    /// A recovery mini-stat: the number, its label, and a plain-language anchor so the value carries
    /// meaning on its own — a bare "832" or "1.4" reads as noise without it (the Oura/Whoop rule:
    /// never a naked metric).
    private func recoveryMetric(_ value: String, _ label: String, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.rounded(Theme.FontSize.headline, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.inkTertiary)
            if let note {
                Text(note).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Frames the week's load against the athlete's own recent norm (the acute:chronic ratio) so "832"
    /// reads as "about your usual week" rather than a naked number.
    private func loadVsUsual(_ acwr: Double) -> String? {
        guard acwr > 0 else { return nil }
        switch acwr {
        case ..<0.8:     return "lighter week"
        case 0.8..<1.15: return "on par"
        case 1.15..<1.4: return "above usual"
        default:         return "well up"
        }
    }

    /// Monotony (how samey the daily load is) reframed as a plain "training mix" word — lower is better.
    private func varietyWord(_ monotony: Double) -> String {
        switch monotony {
        case ..<1.5:    return "Varied"
        case 1.5..<2.0: return "Steady"
        default:        return "Samey"
        }
    }

    private func varietyNote(_ monotony: Double) -> String? {
        switch monotony {
        case ..<1.5:    return "hard + easy"
        case 1.5..<2.0: return "repetitive"
        default:        return "one-note"
        }
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

    /// The recommendation chip. For actionable recs (increase/ease/rest) it's a button that
    /// reshapes the upcoming plan; hold/start are informational only.
    @ViewBuilder
    private func recommendationChip(_ rec: ProgressInsights.Recommendation) -> some View {
        let actionable = rec == .increase || rec == .ease || rec == .rest
        if adjustedPlan {
            chipLabel("Plan updated", icon: "checkmark")
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

    /// "↑12%" / "↓8%" vs the prior 3-week average; empty when essentially flat or no data.
    private func trendSuffix(_ pct: Double) -> String {
        guard abs(pct) >= 1 else { return "" }
        return " · \(pct >= 0 ? "↑" : "↓")\(Int(abs(pct).rounded()))%"
    }

    /// Pace improves when seconds-per-km drops, so a negative trend reads as "faster".
    private func paceTrendSuffix(_ pct: Double) -> String {
        guard abs(pct) >= 1 else { return "" }
        return pct < 0 ? " · \(Int(abs(pct).rounded()))% faster" : " · \(Int(pct.rounded()))% slower"
    }

    /// Weekly average running pace (PRD §10 pace trends) — lower is faster; weeks without runs are
    /// dropped so a rest week doesn't read as a cliff.
    private func paceChart(_ insights: ProgressInsights) -> some View {
        let unit = distanceUnit.resolved() == .imperial ? "mi" : "km"
        let paced = trendPoints(insights).filter { $0.avgPaceSPerKm > 0 }
        let slowest = paced.map(\.avgPaceSPerKm).max() ?? 0
        let fastest = paced.map(\.avgPaceSPerKm).min() ?? 1
        let last = paced.last?.date
        let subtitle = trendIsDaily ? "Per \(unit), by day" : "Per \(unit)\(paceTrendSuffix(insights.paceTrendPct))"
        return chartSection(trendIsDaily ? "Daily pace" : "Weekly pace", subtitle: subtitle,
                            explainer: MetricExplainers.weeklyPace) {
            if paced.count < 2 { notEnoughData } else {
                Chart(paced) { p in
                    LineMark(x: .value("Date", p.date, unit: trendUnit),
                             y: .value("Pace", animateCharts ? p.avgPaceSPerKm : slowest))
                        .foregroundStyle(MetricColor.chart).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", p.date, unit: trendUnit),
                              y: .value("Pace", animateCharts ? p.avgPaceSPerKm : slowest))
                        .foregroundStyle(p.date == last ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(MetricColor.chart))
                        .symbolSize(p.date == last ? 90 : 22)
                        .annotation(position: .top, spacing: 6) {
                            if animateCharts, p.date == last { valuePill(paceMMSS(p.avgPaceSPerKm)) }
                        }
                }
                .chartXScale(domain: paddedDomain(paced.map(\.date)))
                .chartYScale(domain: (fastest * 0.93)...(slowest * 1.07))
                .chartXAxis { trendAxis(insights.weeks.count) }
                .chartYAxis { paceAxis }
                .frame(height: 172)
            }
        }
    }

    private func loadChart(_ insights: ProgressInsights) -> some View {
        let pts = trendPoints(insights)
        let maxLoad = pts.map(\.load).max() ?? 0
        let last = pts.last?.date
        // The "usual" baseline is a WEEKLY norm — meaningless against daily bars, so it's hidden in
        // the Week view (a daily load sits far below a weekly average and would float off the top).
        let usual = trendIsDaily ? 0 : insights.chronic   // 4-week average weekly load = own baseline
        let barW: CGFloat = trendIsDaily ? 24 : loadBarWidth(insights.weeks.count)
        let subtitle = "Effort × time, every sport\(trendIsDaily ? ", by day" : trendSuffix(insights.loadTrendPct))"
        return chartSection(trendIsDaily ? "Daily training load" : "Weekly training load", subtitle: subtitle,
                            explainer: MetricExplainers.trainingLoad) {
            if maxLoad <= 0 { notEnoughData } else {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Chart(pts) { p in
                        // Bars slim down as the window widens so 13 or 26 weeks never collide.
                        BarMark(x: .value("Date", p.date, unit: trendUnit),
                                y: .value("Load", animateCharts ? p.load : 0),
                                width: .fixed(barW))
                            // Earned-iridescent only on the current bar; prior ones are clean ink.
                            .foregroundStyle(p.date == last
                                             ? AnyShapeStyle(IridescentMaterial())
                                             : AnyShapeStyle(MetricColor.chart.opacity(0.9)))
                            .cornerRadius(3)
                            .annotation(position: .top, spacing: 5) {
                                if animateCharts, p.date == last, p.load > 0 { valuePill(Formatters.compact(p.load)) }
                            }
                        // Your recent norm — each bar reads as above/below "usual" rather than a bare number.
                        if usual > 0, animateCharts {
                            RuleMark(y: .value("Usual", usual))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundStyle(Theme.inkTertiary.opacity(0.55))
                                .annotation(position: .top, alignment: .leading, spacing: 1) {
                                    Text("usual").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                                }
                        }
                    }
                    .chartXScale(domain: paddedDomain(pts.map(\.date)))
                    .chartYScale(domain: 0...max(1, maxLoad * 1.18))
                    .chartXAxis { trendAxis(insights.weeks.count) }
                    .chartYAxis { valueAxis }
                    .frame(height: 172)
                    Text(trendIsDaily
                         ? "Runs and lifts on one scale — how hard × how long you trained each day this week."
                         : "Runs and lifts on one scale — how hard × how long you trained. The line is your recent norm.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func distanceChart(_ insights: ProgressInsights) -> some View {
        let unit = distanceUnit.resolved() == .imperial ? "mi" : "km"
        func disp(_ m: Double) -> Double { distanceUnit.resolved() == .imperial ? m / Formatters.metersPerMile : m / 1000 }
        let pts = trendPoints(insights)
        let maxDist = pts.map { disp($0.distanceM) }.max() ?? 0
        let last = pts.last?.date
        let miles = unit == "mi" ? "Miles" : "Kilometres"
        let title = trendIsDaily ? "Daily distance" : "Weekly distance"
        let subtitle = trendIsDaily ? "\(miles) this week, by day"
                                    : "\(miles) per week\(trendSuffix(insights.distanceTrendPct))"
        return chartSection(title, subtitle: subtitle, explainer: MetricExplainers.weeklyDistance) {
            if maxDist <= 0 { notEnoughData } else {
                Chart(pts) { p in
                    if trendIsDaily {
                        // Daily bars read cleanly across a rest-day-punctuated week (a line would dip
                        // to zero and zigzag); the current day glints iridescent.
                        BarMark(x: .value("Day", p.date, unit: .day),
                                y: .value("Distance", animateCharts ? disp(p.distanceM) : 0),
                                width: .fixed(24))
                            .foregroundStyle(p.date == last ? AnyShapeStyle(IridescentMaterial())
                                                            : AnyShapeStyle(MetricColor.chart.opacity(0.9)))
                            .cornerRadius(3)
                            .annotation(position: .top, spacing: 5) {
                                if animateCharts, p.date == last, disp(p.distanceM) > 0 {
                                    let v = disp(p.distanceM)
                                    valuePill(v >= 10 ? "\(Int(v.rounded()))" : String(format: "%.1f", v))
                                }
                            }
                    } else {
                        AreaMark(x: .value("Week", p.date, unit: .weekOfYear),
                                 y: .value("Distance", animateCharts ? disp(p.distanceM) : 0))
                            .foregroundStyle(LinearGradient(colors: [MetricColor.chart.opacity(0.20), .clear],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Week", p.date, unit: .weekOfYear),
                                 y: .value("Distance", animateCharts ? disp(p.distanceM) : 0))
                            .foregroundStyle(MetricColor.chart).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        if disp(p.distanceM) > 0 {
                            PointMark(x: .value("Week", p.date, unit: .weekOfYear),
                                      y: .value("Distance", animateCharts ? disp(p.distanceM) : 0))
                                .foregroundStyle(p.date == last ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(MetricColor.chart))
                                .symbolSize(p.date == last ? 90 : 22)
                                .annotation(position: .top, spacing: 6) {
                                    if animateCharts, p.date == last {
                                        let v = disp(p.distanceM)
                                        valuePill(v >= 10 ? "\(Int(v.rounded()))" : String(format: "%.1f", v))
                                    }
                                }
                        }
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
    struct TrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let load: Double
        let distanceM: Double
        let avgPaceSPerKm: Double
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


    /// A small monospaced value callout pinned to the current week's mark — the "where you are now"
    /// number, so the latest point reads precisely without labelling every week.
    private func valuePill(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).monospacedDigit()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.background))
            .overlay(Capsule().stroke(Theme.hairline))
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

    private func chartSection<C: View>(_ title: String, subtitle: String,
                                       explainer: MetricExplainer? = nil,
                                       @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
                if let explainer {
                    Spacer(minLength: Theme.Space.sm)
                    MetricInfoButton(explainer: explainer)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(card)
        // Collapse the chart into one clean spoken summary (the plot itself is hard to navigate aurally).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle
            .replacingOccurrences(of: "↑", with: "up ")
            .replacingOccurrences(of: "↓", with: "down ")
            .replacingOccurrences(of: " · ", with: ", "))
    }

    // MARK: Weekly muscle coverage

    /// Trailing-7-day working-sets-by-muscle (PRD §22) across strength sessions.
    private var weeklyMuscleActivation: [MuscleGroup: Double] { cachedActivation ?? computeWeeklyMuscleActivation() }
    private func computeWeeklyMuscleActivation() -> [MuscleGroup: Double] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let recent = workouts.filter { $0.type.isStrengthStyle && $0.startedAt >= cutoff }
        return MuscleActivation.from(workouts: recent)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
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
            seasonChart.id("season").proLocked(.advancedAnalytics)
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
                let unit = WeightUnit.default()
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
            chartSection("Your season", subtitle: "Weekly \(unit == .imperial ? "miles" : "kilometers") · ● a record week") {
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
                }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .frame(height: 150)
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

    /// Free-tier anchor: distance, not VO₂max. Everyone gets to see the miles they ran; the
    /// fitness read (and everything the body's rail carries) is the Pro upgrade.
    private var panelHeroFree: AthleteCallout {
        let weekM = insights.weeks.last?.distanceM ?? 0
        return AthleteCallout(label: "THIS WEEK", value: Formatters.distance(meters: weekM, unit: distanceUnit),
                              unit: nil,
                              context: insights.distanceTrendPct >= 3 ? "Trending up" : "Distance covered",
                              target: "charts")
    }

    /// Under the free-tier hero: total distance over the visible range — the "miles banked" number.
    private var panelSubFree: AthleteCallout {
        let totalM = insights.weeks.reduce(0.0) { $0 + $1.distanceM }
        return AthleteCallout(label: "TOTAL", value: Formatters.distance(meters: totalM, unit: distanceUnit),
                              unit: nil, context: "Across this range", target: "charts")
    }

    /// The Athlete Panel's anchor stat — VO₂max, the fitness index. Device measurement wins;
    /// context prefers the 8-week trend when the model has one.
    private var panelHero: AthleteCallout {
        if let vo2 = measuredVO2 ?? currentVO2 {
            let context: String
            if let cur = currentVO2, let old = vo2EightWeeksAgo, abs(cur - old) >= 0.3 {
                context = String(format: "%+.1f vs 8 wks ago", cur - old)
            } else {
                context = measuredVO2 != nil ? "From your device" : "Estimated from pace"
            }
            return AthleteCallout(label: "VO₂ MAX", value: String(format: "%.1f", vo2), unit: nil,
                                  context: context, target: "fitness")
        }
        return AthleteCallout(label: "VO₂ MAX", value: "—", unit: nil,
                              context: "Needs a few runs", target: "fitness")
    }

    /// Under the hero: the week's distance — the "what you actually did" counterweight.
    private var panelSub: AthleteCallout {
        let weekM = insights.weeks.last?.distanceM ?? 0
        return AthleteCallout(label: "THIS WEEK", value: Formatters.distance(meters: weekM, unit: distanceUnit),
                              unit: nil,
                              context: insights.distanceTrendPct >= 3 ? "Trending up" : "Distance covered",
                              target: "charts")
    }

    /// The right-hand rail: readiness, load, resting heart, muscle focus — each targeting the
    /// scroll id of the card that explains it.
    private var panelRail: [AthleteCallout] {
        var out: [AthleteCallout] = []
        // Readiness — blended with Health signals when present, same as the form card.
        if recovery.hasData {
            let score = signals.blendedReadiness(base: recovery.score)
            out.append(AthleteCallout(label: "READINESS", value: "\(score)", unit: "/100",
                                      context: RecoveryModel.band(score).rawValue, target: "formRace"))
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
        // Resting heart — from Apple Health when connected.
        if let rhr = signals.restingHR {
            out.append(AthleteCallout(label: "RESTING HEART", value: "\(rhr)", unit: "bpm",
                                      context: signals.restingHRNote ?? "From Apple Health", target: "hrZones"))
        } else {
            out.append(AthleteCallout(label: "RESTING HEART", value: "—", unit: nil,
                                      context: "Connect Health", target: "hrZones"))
        }
        // Muscle focus — falls back to the intensity mix when the week was all cardio.
        if let top = weeklyMuscleActivation.filter({ $0.key != .fullBody && $0.value > 0 }).max(by: { $0.value < $1.value }) {
            out.append(AthleteCallout(label: "MUSCLE FOCUS", value: top.key.rawValue.capitalized, unit: nil,
                                      context: "Most worked this week", target: "strengthTrends"))
        } else {
            out.append(AthleteCallout(label: "WEEK FOCUS", value: "Endurance", unit: nil,
                                      context: "All cardio this week", target: "intensityMix"))
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

    /// "This week with Momentum" — proactive nudges the model surfaces on its own (§9).
    private func weeklyDigest(_ nudges: [AthleteNudges.Nudge]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("THIS WEEK").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
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
