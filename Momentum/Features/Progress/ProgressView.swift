import SwiftUI
import SwiftData
import Charts

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
    @State private var segment: Segment = .trends
    @State private var correcting: LearnedItem?

    enum Segment: String, CaseIterable, Identifiable {
        case trends = "Trends", history = "History", you = "You"
        var id: Self { self }
    }

    private var plan: TrainingPlan? { profiles.first?.plan }

    private var weightUnit: WeightUnit { .default() }
    private var distanceUnit: DistanceUnit { .auto }
    private var stats: ProfileStats { ProfileStats(workouts: workouts) }
    private var insights: ProgressInsights { ProgressInsights(workouts: workouts) }

    var body: some View {
        VStack(spacing: 0) {
            header
            segmentControl
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.md)
            switch segment {
            case .trends: trends
            case .history: HistoryView()
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
        .padding(.horizontal, Theme.Space.lg)
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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                statusHero(insights).reveal(0)
                coachCard(insights).reveal(0.06)
                // Advanced analytics — Pro (PRD §10): training load, pace/distance trends, weekly
                // sets-per-muscle, e1RM PRs. Free keeps the status read, consistency heatmap & totals.
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    loadChart(insights)
                    distanceChart(insights)
                    if !weeklyMuscleActivation.isEmpty { muscleWeek }
                    if !stats.strengthPRs.isEmpty { prShelf(stats) }
                }
                .reveal(0.12)
                .proLocked(.advancedAnalytics)
                heatmap(stats).reveal(0.24)
                totals(stats).reveal(0.36)
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { animateCharts = true } }
    }

    // MARK: Status hero

    private func statusHero(_ insights: ProgressInsights) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("TRAINING STATUS").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            Text(insights.status.rawValue).font(.display(30, weight: .black)).foregroundStyle(Theme.ink)
            acwrGauge(insights.acwr)
            Text(gaugeCaption(insights)).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
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
        .padding(Theme.Space.lg)
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

    /// Compact value label over a bar/point — "1.2k" for big loads, "23" / "4.5" for distances.
    private func valueLabel(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.1fk", v / 1000) }
        if v >= 10 || v == v.rounded() { return "\(Int(v.rounded()))" }
        return String(format: "%.1f", v)
    }

    private func barLabel(_ text: String) -> some View {
        Text(text).font(.rounded(10, weight: .bold)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
    }

    private func loadChart(_ insights: ProgressInsights) -> some View {
        let maxLoad = insights.weeks.map(\.load).max() ?? 0
        return chartSection("Weekly training load", subtitle: "Last 8 weeks\(trendSuffix(insights.loadTrendPct))") {
            Chart(insights.weeks) { wk in
                BarMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                        y: .value("Load", animateCharts ? wk.load : 0))
                    .foregroundStyle(IridescentMaterial())
                    .cornerRadius(5)
                    .annotation(position: .top, spacing: 3) {
                        if animateCharts, wk.load > 0 { barLabel(valueLabel(wk.load)) }
                    }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, maxLoad * 1.22))   // headroom so labels don't clip
            .frame(height: 150)
        }
    }

    private func distanceChart(_ insights: ProgressInsights) -> some View {
        let unit = distanceUnit.resolved() == .imperial ? "mi" : "km"
        func disp(_ m: Double) -> Double { distanceUnit.resolved() == .imperial ? m / Formatters.metersPerMile : m / 1000 }
        let maxDist = insights.weeks.map { disp($0.distanceM) }.max() ?? 0
        return chartSection("Weekly distance", subtitle: "In \(unit)\(trendSuffix(insights.distanceTrendPct))") {
            Chart(insights.weeks) { wk in
                AreaMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                         y: .value("Distance", animateCharts ? disp(wk.distanceM) : 0))
                    .foregroundStyle(IridescentMaterial()).opacity(0.25)
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                         y: .value("Distance", animateCharts ? disp(wk.distanceM) : 0))
                    .foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                // Dot + value at each week with distance, so the numbers are readable.
                PointMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                          y: .value("Distance", animateCharts ? disp(wk.distanceM) : 0))
                    .foregroundStyle(Theme.ink)
                    .symbolSize(disp(wk.distanceM) > 0 ? 26 : 0)
                    .annotation(position: .top, spacing: 2) {
                        if animateCharts, disp(wk.distanceM) > 0 { barLabel(valueLabel(disp(wk.distanceM))) }
                    }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, maxDist * 1.25))
            .frame(height: 150)
        }
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
        .padding(Theme.Space.lg)
        .background(card)
    }

    // MARK: Heatmap / PRs / totals (from ProfileStats)

    private func heatmap(_ stats: ProfileStats) -> some View {
        let today = StreakCalculator.localDay(Date())
        let weeks = 16
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Consistency")
            HStack(spacing: 3) {
                ForEach(0..<weeks, id: \.self) { col in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { row in
                            let day = today - ((weeks - 1 - col) * 7) - (6 - row)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(stats.countingDays.contains(day) ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.hairline))
                                .frame(width: 13, height: 13)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.lg)
        .background(card)
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
            MuscleMapView(activation: activation)
                .frame(height: 260)
                .frame(maxWidth: .infinity)
            if let top = ranked.first {
                Text("Most worked: \(top.key.displayName).")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    private func prShelf(_ stats: ProfileStats) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("Personal records")
            ForEach(stats.strengthPRs, id: \.name) { pr in
                NavigationLink {
                    ExerciseDetailView(exerciseName: pr.name, weightUnit: weightUnit)
                } label: {
                    HStack {
                        Text(pr.name).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(Formatters.weight(kg: pr.e1RMKg, unit: weightUnit)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    private func totals(_ stats: ProfileStats) -> some View {
        HStack(spacing: Theme.Space.xl) {
            stat("\(stats.totalWorkouts)", "Workouts")
            stat(Formatters.distance(meters: stats.totalDistanceM, unit: distanceUnit), "Distance")
            stat(Formatters.duration(s: stats.totalDurationS), "Time")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
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
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                identityHero(model, facts).reveal(0)
                let nudges = AthleteNudges.generate(facts)
                if !nudges.isEmpty { weeklyDigest(nudges).reveal(0.08) }
                if confidentCount(facts) < 3 { learningState(facts).reveal(0.12) }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    learnedCard(item).reveal(0.14 + Double(i) * 0.05)
                }
                if let model, model.snapshots.count >= 2 { trajectory(model).reveal(0.2) }
            }
            .padding(Theme.Space.lg)
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
        .padding(Theme.Space.lg)
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
        .padding(Theme.Space.lg)
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
        .padding(Theme.Space.lg)
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
        .padding(Theme.Space.lg)
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
