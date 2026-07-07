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
    @Query private var workouts: [Workout]
    @Query private var profiles: [UserProfile]
    @State private var animateCharts = false
    @State private var adjustedPlan = false
    @State private var segment: Segment = {
        #if DEBUG   // deterministic segment deep-links for sim verification (tab taps are flaky)
        let a = ProcessInfo.processInfo.arguments
        if a.contains("--progress-history") { return .history }
        if a.contains("--progress-you") { return .you }
        #endif
        return .trends
    }()
    @State private var correcting: LearnedItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Segment: String, CaseIterable, Identifiable {
        case trends = "Trends", history = "History", you = "You"
        var id: Self { self }
    }

    private var plan: TrainingPlan? { profiles.first?.plan }

    private var distanceUnit: DistanceUnit { .auto }
    private var stats: ProfileStats { ProfileStats(workouts: workouts) }
    private var insights: ProgressInsights { ProgressInsights(workouts: workouts) }
    private var recovery: RecoveryModel { RecoveryModel(workouts: workouts) }

    var body: some View {
        VStack(spacing: 0) {
            header
            segmentControl
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.md)
            switch segment {
            case .trends: trends
            case .history: history
            case .you: you
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text("Progress").font(.display(34, weight: .black)).foregroundStyle(Theme.ink)
            Spacer()
            StreakChip(days: stats.currentStreak)
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

    private var trends: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    // Lead with the fitness read (are you getting fitter?), then the trend graphs up top —
                    // the "how I'm progressing" section sits near the top, not buried at the bottom.
                    fitnessHero().reveal(0)
                    trendMetrics().reveal(0.05)
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        distanceChart(insights)
                        loadChart(insights)
                        if insights.weeks.contains(where: { $0.avgPaceSPerKm > 0 }) { paceChart(insights) }
                        if !weeklyMuscleActivation.isEmpty { muscleWeek }
                    }
                    .reveal(0.09)
                    .proLocked(.advancedAnalytics)
                    // Then "how am I right now" and "what can I run" — the coaching read.
                    formCard(recovery).reveal(0.14).id("formRace")
                    raceOutlook().reveal(0.18)
                    coachCard(insights).reveal(0.22)
                }
                .padding(Theme.Space.md)
                .padding(.bottom, Theme.Space.xxl)
            }
            .onAppear {
                if reduceMotion { animateCharts = true }                               // no chart build-in
                else { withAnimation(.easeOut(duration: 0.9)) { animateCharts = true } }
                #if DEBUG   // deterministic scroll to Form/Race for sim verification
                if ProcessInfo.processInfo.arguments.contains("--progress-scroll-race") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { proxy.scrollTo("formRace", anchor: .top) }
                }
                #endif
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
    private var formPoint: FitnessFreshness.Point? {
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

    /// FITNESS — the headline: VO₂max, an earned-iridescent trend chip, and a fitness sparkline.
    @ViewBuilder
    private func fitnessHero() -> some View {
        if let vo2 = currentVO2 {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionTitle("Running fitness")
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: "%.1f", vo2)).font(.display(42, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        Text("VO₂ MAX · EST.").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.8).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                    if let old = vo2EightWeeksAgo, abs(vo2 - old) >= 0.3 {
                        let up = vo2 >= old
                        HStack(spacing: 4) {
                            Image(systemName: up ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .heavy))
                            Text("\(up ? "+" : "")\(String(format: "%.1f", vo2 - old)) / 8 wks").monospacedDigit()
                        }
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(up ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.hairline)))
                    }
                }
                vo2Sparkline()
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
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                sectionTitle("Form & readiness — now")
                HStack(spacing: Theme.Space.md) {
                    readinessRing(score: r.score)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.readiness.rawValue).font(.display(20, weight: .black)).foregroundStyle(Theme.ink)
                        Text(r.guidance).font(.rounded(Theme.FontSize.label, weight: .medium))
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
            metricTile(paceFaster ? "▲ \(Int(abs(insights.paceTrendPct).rounded()))%" : "—", "Pace", iris: paceFaster)
            metricTile("\(km)", "km · 12 wk", iris: false)
            metricTile("\(profiles.first?.prs.count ?? 0)", "PRs", iris: false)
        }
    }

    private func metricTile(_ value: String, _ label: String, iris: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(19, weight: .heavy)).monospacedDigit()
                .foregroundStyle(iris ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.5).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, Theme.Space.md)
        .background(card)
    }

    // MARK: - History (clean session feed)

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                historySummary().reveal(0)
                ForEach(Array(monthGroups.enumerated()), id: \.element.key) { gi, group in
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
    private var monthGroups: [(key: String, items: [Workout])] {
        let sorted = workouts.sorted { $0.startedAt > $1.startedAt }
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
        } else {
            RoundedRectangle(cornerRadius: 13).fill(Theme.surface)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: w.type.systemImage).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.hairline))
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
        !CardioAchievements.detect(for: w, distanceUnit: distanceUnit, in: context).isEmpty
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
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("RECOVERY").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                HStack(spacing: Theme.Space.lg) {
                    readinessRing(score: r.score)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.readiness.rawValue).font(.display(24, weight: .black)).foregroundStyle(Theme.ink)
                        Text(r.guidance).font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Divider().overlay(Theme.hairline)
                HStack(spacing: Theme.Space.lg) {
                    recoveryMetric(String(format: "%.1f", r.monotony), "Monotony")
                    recoveryMetric("\(Int(r.weeklyLoad))", "Weekly load")
                    recoveryMetric("\(r.restDays)", "Rest days")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .background(card)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recovery, \(r.readiness.rawValue)")
            .accessibilityValue("Readiness \(r.score) of 100. \(r.guidance)")
        }
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

    private func recoveryMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.rounded(Theme.FontSize.headline, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let paced = insights.weeks.filter { $0.avgPaceSPerKm > 0 }
        let slowest = paced.map(\.avgPaceSPerKm).max() ?? 0
        let fastest = paced.map(\.avgPaceSPerKm).min() ?? 1
        let last = paced.last?.weekStart
        return chartSection("Weekly pace", subtitle: "Per \(unit)\(paceTrendSuffix(insights.paceTrendPct))") {
            if paced.count < 2 { notEnoughData } else {
                Chart(paced) { wk in
                    LineMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                             y: .value("Pace", animateCharts ? wk.avgPaceSPerKm : slowest))
                        .foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                              y: .value("Pace", animateCharts ? wk.avgPaceSPerKm : slowest))
                        .foregroundStyle(wk.weekStart == last ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                        .symbolSize(wk.weekStart == last ? 90 : 22)
                        .annotation(position: .top, spacing: 6) {
                            if animateCharts, wk.weekStart == last { valuePill(paceMMSS(wk.avgPaceSPerKm)) }
                        }
                }
                .chartXScale(domain: paddedWeekDomain(paced.map(\.weekStart)))
                .chartYScale(domain: (fastest * 0.93)...(slowest * 1.07))
                .chartXAxis { weekAxis }
                .chartYAxis { paceAxis }
                .frame(height: 172)
            }
        }
    }

    private func loadChart(_ insights: ProgressInsights) -> some View {
        let maxLoad = insights.weeks.map(\.load).max() ?? 0
        let last = insights.weeks.last?.weekStart
        return chartSection("Weekly training load", subtitle: "Last 8 weeks\(trendSuffix(insights.loadTrendPct))") {
            if maxLoad <= 0 { notEnoughData } else {
                Chart(insights.weeks) { wk in
                    BarMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                            y: .value("Load", animateCharts ? wk.load : 0),
                            width: 18)
                        // Earned-iridescent only on the current week; prior weeks are clean ink.
                        .foregroundStyle(wk.weekStart == last
                                         ? AnyShapeStyle(IridescentMaterial())
                                         : AnyShapeStyle(Theme.ink.opacity(0.85)))
                        .cornerRadius(3)
                        .annotation(position: .top, spacing: 5) {
                            if animateCharts, wk.weekStart == last, wk.load > 0 { valuePill(Formatters.compact(wk.load)) }
                        }
                }
                .chartXScale(domain: paddedWeekDomain(insights.weeks.map(\.weekStart)))
                .chartYScale(domain: 0...max(1, maxLoad * 1.18))
                .chartXAxis { weekAxis }
                .chartYAxis { valueAxis }
                .frame(height: 172)
            }
        }
    }

    private func distanceChart(_ insights: ProgressInsights) -> some View {
        let unit = distanceUnit.resolved() == .imperial ? "mi" : "km"
        func disp(_ m: Double) -> Double { distanceUnit.resolved() == .imperial ? m / Formatters.metersPerMile : m / 1000 }
        let maxDist = insights.weeks.map { disp($0.distanceM) }.max() ?? 0
        let last = insights.weeks.last?.weekStart
        return chartSection("Weekly distance", subtitle: "In \(unit)\(trendSuffix(insights.distanceTrendPct))") {
            if maxDist <= 0 { notEnoughData } else {
                Chart(insights.weeks) { wk in
                    AreaMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                             y: .value("Distance", animateCharts ? disp(wk.distanceM) : 0))
                        .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.10), .clear],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                             y: .value("Distance", animateCharts ? disp(wk.distanceM) : 0))
                        .foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    if disp(wk.distanceM) > 0 {
                        PointMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                                  y: .value("Distance", animateCharts ? disp(wk.distanceM) : 0))
                            .foregroundStyle(wk.weekStart == last ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                            .symbolSize(wk.weekStart == last ? 90 : 22)
                            .annotation(position: .top, spacing: 6) {
                                if animateCharts, wk.weekStart == last {
                                    let v = disp(wk.distanceM)
                                    valuePill(v >= 10 ? "\(Int(v.rounded()))" : String(format: "%.1f", v))
                                }
                            }
                    }
                }
                .chartXScale(domain: paddedWeekDomain(insights.weeks.map(\.weekStart)))
                .chartYScale(domain: 0...max(1, maxDist * 1.18))
                .chartXAxis { weekAxis }
                .chartYAxis { valueAxis }
                .frame(height: 172)
            }
        }
    }

    // MARK: Shared chart axes — a quiet week timeline + faint value gridlines, so every chart reads
    // as tracking something over time (not a floating squiggle).

    /// X axis: a week/date timeline, labelled every other week.
    private var weekAxis: some AxisContent {
        AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
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

    /// Pads a weekly date range by half a week on each side so the first/last bar or point has room
    /// and never clips against the plot edge.
    private func paddedWeekDomain(_ dates: [Date]) -> ClosedRange<Date> {
        guard let lo = dates.min(), let hi = dates.max(), lo <= hi else { return Date()...Date().addingTimeInterval(1) }
        let pad: TimeInterval = 4 * 24 * 3600
        return lo.addingTimeInterval(-pad)...hi.addingTimeInterval(pad)
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

    private func chartSection<C: View>(_ title: String, subtitle: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
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
    private var weeklyMuscleActivation: [MuscleGroup: Double] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let recent = workouts.filter { $0.type.isStrengthStyle && $0.startedAt >= cutoff }
        return MuscleActivation.from(workouts: recent)
    }

    /// A body map of where the week's volume landed, plus the most- and least-worked callouts so
    /// neglected muscles surface (the coaching value of seeing balance over time).
    private var muscleWeek: some View {
        let activation = weeklyMuscleActivation
        let ranked = activation.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("This week's muscles")
            MuscleMapView(activation: activation, sex: BodySex(profileSex: profiles.first?.sex))
                .frame(height: 260)
                .frame(maxWidth: .infinity)
            if let top = ranked.first {
                Text("Most worked: \(top.key.displayName).")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(card)
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

    private var you: some View {
        let facts = AthleteModelEngine(workouts: workouts, plan: plan).facts
        let model = profiles.first?.athlete
        let items = learnedItems(facts, model)
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                identityHero(model, facts).reveal(0)
                let nudges = AthleteNudges.generate(facts)
                if !nudges.isEmpty { weeklyDigest(nudges).reveal(0.08) }
                if confidentCount(facts) < 3 { learningState(facts).reveal(0.12) }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    learnedCard(item).reveal(0.14 + Double(i) * 0.05)
                }
                if let model, model.snapshots.count >= 2 { trajectory(model).reveal(0.2) }
            }
            .padding(Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl)
        }
        .sheet(item: $correcting) { item in
            if let profile = profiles.first {
                CorrectionSheet(belief: item.value, category: item.category, noteID: item.noteID, profile: profile)
                    .presentationDetents([.medium])
            }
        }
        .onAppear {
            // Keep the model fresh and ensure seeds exist (both idempotent, local-only).
            guard let p = profiles.first else { return }
            services.athleteModel.seedOnboarding(for: p, in: context)
            services.athleteModel.ingest(profile: p, in: context)
        }
    }

    private func identityHero(_ model: AthleteModel?, _ facts: AthleteFacts) -> some View {
        // A pinned user correction wins; then any AI/onboarding identity note; then the seed.
        let notes = model?.notes.filter { $0.isActive && $0.category == MemoryCategory.identity.rawValue } ?? []
        let pinned = notes.first(where: { $0.pinned && $0.source == MemorySource.user.rawValue })
        let text = pinned?.text
            ?? notes.first?.text
            ?? profiles.first.map { AthleteModelService.identitySeed($0) }
            ?? "Getting to know you."
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("WHAT MOMENTUM KNOWS").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            Text(text).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if profiles.first != nil {
                notQuiteRightButton(value: text, category: .identity, noteID: pinned?.id)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(IridescentMaterial()).opacity(0.32)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
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

    private func learningState(_ facts: AthleteFacts) -> some View {
        let count = facts.signalSampleCounts[AthleteModelEngine.Signal.rhythm.rawValue] ?? 0
        let need = max(1, 8 - count)
        return HStack(spacing: Theme.Space.sm) {
            Image(systemName: "sparkles").foregroundStyle(Theme.inkTertiary)
            Text("Still learning your rhythm — about \(need) more session\(need == 1 ? "" : "s") and I'll have it.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(card)
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

    private func learnedCard(_ item: LearnedItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(item.title).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2).foregroundStyle(Theme.inkTertiary)
                Spacer()
                confidencePip(item.confidence)
            }
            Text(item.value).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            notQuiteRightButton(value: item.value, category: item.category, noteID: item.noteID)
                .padding(.top, 2)
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

    private func trajectory(_ model: AthleteModel) -> some View {
        let snapshots = model.snapshots.sorted { $0.weekStart < $1.weekStart }
        return chartSection("Your trajectory", subtitle: "Weekly load over time") {
            Chart(snapshots, id: \.weekStart) { snap in
                LineMark(x: .value("Week", snap.weekStart, unit: .weekOfYear),
                         y: .value("Load", snap.weeklyLoad))
                    .foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 130)
        }
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
