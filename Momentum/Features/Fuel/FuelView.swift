import SwiftUI
import SwiftData
import AppIntents

/// FUEL — the fueling readout + meal journal (pillar decision 2026-07-16; canonical flow in
/// docs/FUEL-FLOW.md). One page that answers "am I fueled for the work?": the deterministic
/// `FuelReadiness` readout up top (carbs vs the session that's driving the target, energy/protein/
/// sodium floors, one quiet `FuelTips` line), a notes-app composer — Amy Food Journal style: jot
/// or *speak* what you ate in plain words (`VoiceTranscriber`, on-device), the AI parses it into
/// ITEMS with portions — and today's meals as a running journal. The AI only itemizes and
/// estimates; every target and verdict is engine math, and the athlete's hand always outranks
/// the estimate (portion steppers, `manual` wins forever).
///
/// Framing rules carried from the engine: floors, never ceilings; no diet/weight language;
/// every number reads ≈. A meal logs instantly offline and estimates when it can (pending
/// estimates retry when the page appears).
///
/// Motion (house rules — transforms only, reduce-motion honored): the page enters as a reveal
/// cascade; a logged row lands instantly with a shimmer skeleton where the numbers will be (the
/// "AI is reading it" beat — Reduce Motion → static "Estimating…"), then crossfades to the
/// itemized result; the carb bar grows by scale and earns iridescence exactly when the floor is
/// met; totals roll with numeric text; the refuel banner slides in only while the window is open.
struct FuelView: View {
    /// false when tab-hosted (RootView) — the tab bar is the way out, so no Done button. true when
    /// presented as a sheet (previews/one-off entry points).
    var showsDone = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bounded on purpose. The page judges TODAY and offers repeats from the recent past — it never
    /// needed every meal ever logged. `fetchLimit` runs AFTER the sort, and we sort by the very key
    /// we window on, so "newest 500" is exactly "the recent journal" (this is NOT the case
    /// CardioSummaryView warns about — there a limit ran ahead of an in-memory filter and silently
    /// dropped rows). A relative-date `#Predicate` is the wrong tool here: a property initializer
    /// captures its `Date` once when the view's storage is created and never re-derives it, so a
    /// long-lived session would quietly drift past its own window.
    /// 500 ≈ 3 months at 6 meals/day: comfortably more than `usuals` walks (200). FuelHistoryView
    /// keeps its own unbounded query + 365-day in-memory window — untouched, and correctly divergent.
    private static var recentMeals: FetchDescriptor<Meal> {
        var d = FetchDescriptor<Meal>(sortBy: [SortDescriptor(\Meal.eatenAt, order: .reverse)])
        d.fetchLimit = 500
        return d
    }
    /// Only TODAY's workouts are ever read (`FuelReadoutBuilder` takes `prefix(20)`, then filters to
    /// today). 30 is headroom over that prefix; sorted newest-first, today's can never fall out.
    private static var recentWorkouts: FetchDescriptor<Workout> {
        var d = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\Workout.startedAt, order: .reverse)])
        d.fetchLimit = 30
        return d
    }
    @Query(FuelView.recentMeals) private var meals: [Meal]
    @Query(FuelView.recentWorkouts) private var workouts: [Workout]
    @Query private var profiles: [UserProfile]

    @State private var draft = ""
    /// In-flight estimates, retained by meal id so a Delete can CANCEL one before it comes back to a
    /// deleted SwiftData object (it also drives the shimmer, exactly like the old `Set<UUID>`).
    @State private var estimateTasks: [UUID: Task<Void, Never>] = [:]
    @State private var editing: Meal?
    @State private var showingReadout = false
    @State private var showingGoals = false
    /// Drives the `.navigationDestination` for Meal history — a Button gates the push (a
    /// NavigationLink can't be intercepted), so free athletes hit the paywall instead.
    @State private var showingHistory = false
    @State private var voice = VoiceTranscriber()
    @State private var voiceBase = ""
    /// The "Hey Siri, log a meal in Momentum" tip row — shown until the athlete dismisses it.
    @AppStorage("com.momentum.fuel.siriTip") private var siriTipVisible = true
    @FocusState private var composing: Bool
    @Environment(PaywallController.self) private var paywall
    @Environment(\.scenePhase) private var scenePhase
    private let estimator = FuelEstimator()
    /// How many times the journal will re-fire an estimate on its own before it rests. A meal the
    /// model can't parse must not cost an API call on every tab visit for the rest of its life; the
    /// athlete's own "Estimate again" always overrides the cap.
    private static let maxEstimateAttempts = 3

    // Everything derived from SwiftData is snapshotted per data change instead of per body
    // evaluation — the ProgressView `refreshAggregates` / TodayView `cachedPendingToday` pattern.
    // `readout` was a COMPUTED property read 7× per pass (banner, kcal headline, strip, rings,
    // sheet, log, retry): each read mapped 80 meals into engine inputs, walked the plan with
    // per-session calendar math, ran the BMR/carb/sodium pipeline, and built strings. Every
    // keystroke in the composer re-evaluates the body, so the athlete paid for all of it per letter.
    @State private var cachedReadout: FuelReadiness.DayReadout?
    @State private var cachedTip: String?
    @State private var cachedTodayMeals: [Meal] = []
    @State private var cachedUsuals: [Meal] = []
    /// Row titles decoded ONCE per refresh — `Meal.journalTitle` runs a JSONDecoder over `itemsData`
    /// on every single access, and every visible row calls it on every render pass.
    @State private var cachedTitles: [UUID: String] = [:]
    /// The signature the caches were built from. nil = never built (first frame).
    @State private var cacheToken: Int?
    /// The clock is a real input, not incidental: the engine paces `status` across the waking day
    /// (06:00→22:00), opens and closes the 90-minute refuel window, and `FuelTips` switches on hour
    /// bands. Today that tracks live only because the readout recomputes constantly — memoizing it
    /// without this would freeze the refuel banner on. One tick a minute while the page is visible.
    @State private var minuteTick = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if readout.refuelDue {
                        refuelBanner
                            .transition(bannerTransition)
                    }
                    // The dashboard reads top-down: the day's energy, its verdict (the strip
                    // judges the WHOLE day, so it lives up here), the gauges — then the composer
                    // (Amy: entry next) and the journal. History lives behind the calendar button.
                    kcalHeadline.reveal(0)
                    readoutStrip.reveal(0.05)
                    ringsRow.reveal(0.10)
                    composer.reveal(0.16)
                    usualsRow.reveal(0.20)
                    // Discoverability for hands-free logging ("Hey Siri, log a meal in Momentum").
                    // Apple's own tip row; dismissible once, forever.
                    if siriTipVisible {
                        SiriTipView(intent: LogMealIntent(), isVisible: $siriTipVisible)
                            .reveal(0.22)
                    }
                    todaysMeals.reveal(0.24)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
                .animation(Motion.standard, value: readout.refuelDue)
            }
            // FUEL is a Pro pillar, but the page is "try-then-paywall" (user decision, mirrors the
            // AI coach): free athletes see the REAL page — honest empty rings/kcal, a live composer
            // they can focus and TYPE into — and the wall fires only on a Pro ACTION (send, history,
            // goals, a usuals chip, a logged-meal tap). No whole-page frost; typing is the "try".
            .background(Theme.background)
            .navigationTitle("Fuel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The fueling adjuster — the plan adjuster's sibling (goals, body inputs, custom).
                ToolbarItem(placement: .topBarLeading) {
                    // Always visible; the ACTION gates. Entitled → open the adjuster; free → paywall.
                    Button {
                        if paywall.isEntitled(to: .fuel) { showingGoals = true }
                        else { paywall.present(for: .fuel) }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Fueling goals")
                }
                // The page title wears the brand voice: lowercase Space Grotesk, small and
                // centered — the shared masthead language across fuel / plan / progress
                // (user call 2026-07-16; the wordmark image experiment was walked back).
                ToolbarItem(placement: .principal) {
                    Text("fuel")
                        .font(.display(20, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // A NavigationLink can't be intercepted, so this is a Button that gates the push:
                    // entitled → navigate (via the `.navigationDestination` below); free → paywall.
                    Button {
                        if paywall.isEntitled(to: .fuel) { showingHistory = true }
                        else { paywall.present(for: .fuel) }
                    } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Meal history")
                }
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $editing) { MealDetailSheet(meal: $0) }
            .sheet(isPresented: $showingGoals) { FuelGoalsSheet() }
            // Meal history — pushed only once the gated toolbar button has confirmed entitlement.
            .navigationDestination(isPresented: $showingHistory) { FuelHistoryView() }
            // Dictation streams into the composer as it's recognized — voice is input sugar;
            // everything downstream of the field is identical to typing.
            .onChange(of: voice.transcript) { _, spoken in
                guard !spoken.isEmpty else { return }
                draft = voiceBase.isEmpty ? spoken : voiceBase + " " + spoken
            }
            .alert("Microphone access needed", isPresented: Bindable(voice).showPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Turn on Microphone and Speech Recognition for momentum to speak your meals.")
            }
            // Estimates that couldn't run at log time (offline, function down) retry quietly
            // whenever the page appears — the loop self-heals without the athlete doing anything.
            .task { await retryPendingEstimates() }
            // First frame, and every return to the tab. Unconditional: it's also how a plan edit
            // made on the Plan tab reaches the carb target (the signature hashes plan IDENTITY, not
            // its session list — see `cacheSignature`).
            .onAppear { refreshDerived() }
            // Any data change — a meal logged or deleted, an estimate landing, the adjuster saved,
            // a workout finishing, the day rolling over, the minute ticking.
            .onChange(of: cacheSignature) { refreshDerived() }
            // The clock tick. `.task` is cancelled on disappear, so an off-tab Fuel page costs
            // nothing; `&+=` so a very long session can't trap on overflow.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    minuteTick &+= 1
                }
            }
            // Foregrounding after hours asleep: the sleep above resumes late, so re-judge at once
            // rather than showing yesterday's pacing for up to a minute.
            .onChange(of: scenePhase) { _, phase in if phase == .active { refreshDerived() } }
            .onDisappear { if voice.isRecording { voice.stop() } }
        }
    }

    // MARK: Readout (SwiftData → engine inputs via the shared builder; the engine stays pure)

    /// Cheap-but-CORRECT cache key. The readout depends on meal CONTENT, not meal count — when a
    /// pending estimate lands, `carbsG` goes nil → a number with the count unchanged, so a
    /// count-only signature would silently freeze the rings on stale numbers. We hash the value
    /// fields themselves, but only over TODAY's meals: the query sorts `eatenAt` descending and a
    /// meal can't be logged in the future (the detail sheet's DatePicker is bounded `...Date()`),
    /// so today's are a leading prefix. That's a few dozen Int hash combines per body pass, against
    /// an engine run that allocates 80 structs, walks the plan, and formats strings.
    private var cacheSignature: Int {
        let todayStart = Calendar.current.startOfDay(for: Date())
        var h = Hasher()
        // The day stamp — so a rollover past midnight re-judges even on an empty journal
        // (the ProgressView lesson: engines bake "today" into their own math).
        h.combine(todayStart)
        h.combine(minuteTick)
        // Today's meals, BY CONTENT — this is the line that makes a landing estimate roll the rings.
        for m in todaySlice(since: todayStart) {
            h.combine(m.eatenAt)
            h.combine(m.kcal); h.combine(m.carbsG); h.combine(m.proteinG)
            h.combine(m.fatG); h.combine(m.sodiumMg)
            h.combine(m.potassiumMg); h.combine(m.magnesiumMg)
            h.combine(m.ironMg); h.combine(m.calciumMg)
            // The BREAKDOWN, not just the sums — `cachedTitles` is decoded from `itemsData`, and
            // an edit can rewrite the item list while every total above stays byte-identical:
            // removing a water or a black coffee subtracts zero from all five, and stepping a
            // zero-calorie item only moves `qty`. Without these three the row would keep naming an
            // item the athlete just deleted, which is precisely the promise the detail sheet makes
            // ("your hand outranks the estimate") read back to them as a lie. A few hundred bytes
            // per today-meal, against the engine run this cache exists to avoid.
            h.combine(m.itemsData); h.combine(m.fluidsMl); h.combine(m.source)
        }
        // Today's workouts, by content: they raise the energy floor, add sweat sodium, and are the
        // whole of `refuelDue`.
        for w in workouts {
            if w.isDeleted { continue }
            guard w.startedAt >= todayStart else { break }
            h.combine(w.startedAt); h.combine(w.durationS); h.combine(w.calories)
        }
        // `usuals` reads the recent past. A meal's TEXT is immutable after logging (the detail
        // sheet edits portions and the clock, never the words), and only today's meals ever gain
        // numbers — already hashed above. So count plus the identity of both ENDS of the window is
        // enough. Both ends, because `meals` is windowed at 500: past that, deleting an older meal
        // pulls the 501st row in and leaves the count pinned, so count alone would go blind to
        // exactly the delete `usuals` needs to hear about. The tail identity always shifts.
        h.combine(meals.count)
        h.combine(meals.first?.persistentModelID)
        h.combine(meals.last?.persistentModelID)
        // The fueling adjuster's inputs — O(1) scalars on one object, so exact, with no
        // sheet-dismiss hook to forget.
        let p = profiles.first
        h.combine(p?.bodyMassKg); h.combine(p?.heightCm); h.combine(p?.birthYear)
        h.combine(p?.sex); h.combine(p?.fuelGoalKind)
        h.combine(p?.fuelCustomKcal); h.combine(p?.fuelCustomProteinG)
        h.combine(p?.fuelCustomCarbsG); h.combine(p?.fuelCustomFatG); h.combine(p?.fuelCustomSodiumMg)
        // Plan IDENTITY only — deliberately NOT `plan.sessions.count`. TodayView can afford that
        // (the plan changes under it while it's on screen); Fuel has no plan-editing surface, and
        // touching the relationship would fault every session of a 52-week plan on every body
        // evaluation. Plan edits made on another tab land through the unconditional `.onAppear`.
        h.combine(p?.plan?.persistentModelID)
        return h.finalize()
    }

    private var isCacheValid: Bool { cacheToken == cacheSignature }

    /// Never serves a cached value once the signature has moved — the TodayView rule. It carries
    /// less danger here than there: `DayReadout` is a pure value type (Ints, Strings, Bools, Dates,
    /// no SwiftData references), so a stale one can only ever be stale numbers, never a
    /// cascade-deleted object. The guard is what keeps those numbers honest on the frame a meal or
    /// an estimate lands.
    private var readout: FuelReadiness.DayReadout {
        if isCacheValid, let r = cachedReadout { return r }
        return computeReadout(now: Date()).readout
    }

    /// The one tip line, judged with the SAME `now` as the readout it reads (as two independent
    /// computed properties they could disagree across an hour boundary mid-frame).
    private var tip: String? {
        if isCacheValid { return cachedTip }
        return computeReadout(now: Date()).tip
    }

    /// Today's meals as a leading slice — the query sorts `eatenAt` descending and a meal can't be
    /// logged in the future (the detail sheet's DatePicker is bounded `...Date()`), so today's rows
    /// are a prefix. Deleted models are skipped rather than read: these compute passes now run
    /// EAGERLY inside the same transaction as `context.delete`, before @Query has republished, so
    /// the array can still hold a row that no longer exists. Skipping (not breaking) on a deleted
    /// row keeps the rest of today intact.
    private func todaySlice(since todayStart: Date) -> [Meal] {
        var today: [Meal] = []
        for m in meals {
            if m.isDeleted { continue }
            guard m.eatenAt >= todayStart else { break }
            today.append(m)
        }
        return today
    }

    /// The engine pass itself. Only TODAY's meals reach the builder (it took `prefix(80)` and the
    /// engine then filtered to today — same set, same `DayReadout`, without mapping a month of
    /// history into engine inputs first).
    private func computeReadout(now: Date) -> (readout: FuelReadiness.DayReadout, today: [Meal], tip: String?) {
        let todayStart = Calendar.current.startOfDay(for: now)
        let today = todaySlice(since: todayStart)
        let r = FuelReadoutBuilder.readout(meals: today, plan: profiles.first?.plan,
                                           workouts: Array(workouts), profile: profiles.first, now: now)
        return (r, today, FuelTips.line(readout: r, now: now))
    }

    /// One pass, one place — so the body never runs an engine. Called on appear, on every signature
    /// change, on the minute tick, on foreground, and eagerly from every mutator so the change frame
    /// costs one engine run instead of four.
    private func refreshDerived() {
        let pass = computeReadout(now: Date())
        cachedReadout = pass.readout
        cachedTip = pass.tip
        cachedTodayMeals = pass.today
        let repeats = computeUsuals()
        cachedUsuals = repeats
        // Decode `itemsData` once per meal per refresh instead of once per row per render pass.
        var titles: [UUID: String] = [:]
        for m in pass.today { titles[m.id] = m.journalTitle }
        for m in repeats where titles[m.id] == nil { titles[m.id] = m.journalTitle }
        cachedTitles = titles
        cacheToken = cacheSignature
    }

    /// The row/chip title, decoded at refresh time. Honors the same validity guard as `usuals` and
    /// `todayMeals`: once the signature has moved, the map describes the meal as it WAS, so we pay
    /// the decode for one frame rather than name items the athlete has already removed. Falls back
    /// to the live property for a meal that simply isn't in the map — right, just at the old cost.
    private func title(_ meal: Meal) -> String {
        guard isCacheValid, let cached = cachedTitles[meal.id] else { return meal.journalTitle }
        return cached
    }

    // MARK: Readout strip — the judgment at a glance, deliberately quiet; tap for the full story

    /// "Building · ≈90 of 350 g carbs · FOR tomorrow's long session (1h 45m)" — status word, the
    /// carb numbers, a 5-point bar, the session the target is keyed to, and the one tip. Small
    /// type, no display numerals (those live in the tap-through sheet). The bar still grows by
    /// transform and still earns iridescence exactly at the floor — subtle ≠ unearned.
    private var readoutStrip: some View {
        let r = readout
        let tip = self.tip
        let fraction = min(1, CGFloat(r.carbsG) / CGFloat(max(1, r.carbsFloorG)))
        return Button { showingReadout = true } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(statusWord(r.status))
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .contentTransition(.opacity)
                    Text(carbsLine(r))
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    // Count what is ACTUALLY in flight, not every numberless meal: a meal that hit
                    // the retry cap has no numbers and no task, and would otherwise claim to be
                    // "estimating…" forever.
                    if !estimateTasks.isEmpty {
                        Text("\(estimateTasks.count) estimating…")
                            .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                            .transition(.opacity)
                    }
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                Capsule().fill(Theme.surface)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(r.status == .fueled ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.Fuel.carbs))
                            .scaleEffect(x: max(0.004, fraction), y: 1, anchor: .leading)
                            .opacity(r.carbsG > 0 ? 1 : 0)
                    }
                    .frame(height: 5)
                    .clipShape(Capsule())
                    .animation(Motion.lively, value: fraction)
                    .animation(Motion.standard, value: r.status)
                // WHY this target — the driving session, on the dashboard. The plan↔fuel link is
                // the page's entire differentiator, and it lived one tap deep in the sheet; now it
                // composes with the status line as one sentence: "Fueled · ≈390 g carbs banked —
                // FOR tomorrow's long session (1h 45m)". Hidden on an easy horizon (nil), exactly
                // like the sheet's keyed-to line. Race eve steps up half a voice (secondary ink,
                // semibold) — the one morning the denominator IS the headline.
                if let driving = r.drivingSession {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("FOR")
                            .font(.rounded(10, weight: .bold)).tracking(1.2)
                            .foregroundStyle(Theme.inkTertiary)
                        Text(driving)
                            .font(.rounded(Theme.FontSize.label, weight: r.raceEve ? .semibold : .medium))
                            .foregroundStyle(r.raceEve ? Theme.inkSecondary : Theme.inkTertiary)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                }
                if let tip {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("TIP")
                            .font(.rounded(10, weight: .bold)).tracking(1.2)
                            .foregroundStyle(Theme.inkTertiary)
                        Text(tip)
                            .font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .animation(Motion.standard, value: r)
        .animation(Motion.standard, value: tip)
        .accessibilityLabel("Fueling readout")
        .accessibilityValue(
            (r.status == .fueled ? "about \(r.carbsG) grams of carbohydrates banked, floor met"
                                 : "about \(r.carbsG) of \(r.carbsFloorG) grams of carbohydrates")
            + (r.drivingSession.map { ", keyed to \($0)" } ?? ""))
        .accessibilityHint("Shows the full fueling detail")
        .sheet(isPresented: $showingReadout) { FuelReadoutSheet(readout: readout) }
    }

    /// No-shame status words — "behind" never appears; a slow morning is just "building".
    private func statusWord(_ s: FuelReadiness.Status) -> String {
        switch s {
        case .empty: return "Today"
        case .behind: return "Building"
        case .onTrack: return "On track"
        case .fueled: return "Fueled"
        }
    }

    /// The carb clause after the status word. Past the floor the fraction goes away — "≈390 of
    /// 210 g" reads like a mistake once you've sailed past it (a floor is not a denominator to
    /// overshoot); from there the total banked is the whole story, in the engine's own verb.
    private func carbsLine(_ r: FuelReadiness.DayReadout) -> String {
        switch r.status {
        case .empty: return "aiming ≈\(r.carbsFloorG)–\(r.carbsHighG) g carbs"
        case .fueled: return "≈\(r.carbsG) g carbs banked"
        case .behind, .onTrack: return "≈\(r.carbsG) of \(r.carbsFloorG) g carbs"
        }
    }

    private var bannerTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// The recovery-window nudge is an AFFORDANCE, not a statement: its one job is getting the
    /// refuel meal logged, so tapping it opens the composer with the keyboard up. The chevron
    /// speaks the same quiet "tappable" language as the strip and the rows. (Focusing costs and
    /// spends nothing, so it needs no Pro gate — SEND still walls via `attemptLog`.)
    private var refuelBanner: some View {
        Button {
            composing = true
            Haptics.light()
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.purple)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.purple.opacity(0.1)))
                Text("Recovery window is open — carbs + protein within the hour do the most good.")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.purple.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.purple.opacity(0.25)))
        .accessibilityLabel("Recovery window is open — carbs and protein within the hour do the most good")
        .accessibilityHint("Opens the meal composer")
    }

    // MARK: Composer — jot it like a note, or speak it (Amy-style); logging never blocks

    /// The ChatGPT read: one clean continuous-corner pill holding the field, mic, and send — and
    /// the SAME wake-up as the coach's composer: hairline at rest, a soft iridescent ring + glow
    /// while you're writing. Static ring (no pulsing) — Reduce Motion safe by design.
    private var composer: some View {
        let fieldShape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return HStack(alignment: .bottom, spacing: Theme.Space.sm) {
            // Just the question — the old inline example ("2 eggs, toast, coffee") truncated to
            // "2 eggs, t…" on every device width once the mic + send buttons took their room,
            // which taught nothing and read broken. The usuals chips and the journal itself are
            // the teaching-by-example surface now.
            if voice.isRecording {
                // Dictating: the field becomes the live transcript, tail always in view.
                LiveTranscriptView(text: draft)
                    .padding(.leading, 4)
                    .padding(.vertical, 8)
            } else {
                TextField("What did you eat?", text: $draft, axis: .vertical)
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .focused($composing)
                    .submitLabel(.send)
                    .onSubmit(attemptLog)
                    .padding(.leading, 4)
                    .padding(.vertical, 8)
            }
            if voice.isSupported {
                micButton
            }
            Button(action: attemptLog) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.background)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(canLog ? Theme.ink : Theme.inkTertiary))
                    .scaleEffect(canLog ? 1 : 0.92)
                    .animation(Motion.lively, value: canLog)
            }
            .buttonStyle(.plain)
            .disabled(!canLog)
            .accessibilityLabel("Log meal")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 6)
        .background(fieldShape.fill(Theme.surface))
        .overlay {
            if composerGlow {
                fieldShape
                    .stroke(LinearGradient(colors: Theme.iridescent,
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.5)
                    .opacity(voice.isRecording && !reduceMotion
                             ? 0.55 + 0.45 * voice.level          // the ring breathes WITH the voice
                             : (draft.isEmpty ? 0.65 : 1))
            } else {
                fieldShape.stroke(Theme.hairline)
            }
        }
        .shadow(color: (Theme.iridescent.first ?? .clear).opacity(composerGlow ? 0.35 : 0),
                radius: composerGlow ? 9 : 0, y: 2)
        .animation(Motion.reversible, value: composerGlow)
        .animation(Motion.reversible, value: draft.isEmpty)
        .animation(Motion.standard, value: voice.isRecording)
    }

    /// Awake while writing or dictating — focused, holding text, or the mic running.
    private var composerGlow: Bool { composing || !draft.isEmpty || voice.isRecording }

    /// Tap to talk, tap to stop — words stream into the field live; review, then send.
    /// Bare glyph at rest (the ChatGPT read); a filled ink circle whose level bars ride the
    /// athlete's actual voice while hot (the shared premium-dictation meter).
    private var micButton: some View {
        Button {
            if !voice.isRecording { voiceBase = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
            voice.toggle()
            Haptics.light()
        } label: {
            ZStack {
                Circle().fill(voice.isRecording ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.clear))
                if voice.isRecording {
                    VoiceLevelBars(level: voice.level, tint: Theme.background)
                } else {
                    Image(systemName: "mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(width: 34, height: 34)
            .animation(Motion.standard, value: voice.isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate meal")
    }

    private var canLog: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Pro gate on logging — mirrors the coach's `attemptSend`. Typing is the free "try"; the
    /// SEND action is where the wall lives. Both the send button and the field's `.onSubmit` route
    /// here, so a free athlete's draft survives (the wall opens over it) while nothing logs.
    private func attemptLog() {
        guard paywall.isEntitled(to: .fuel) else { paywall.present(for: .fuel); return }
        logFromComposer()
    }

    /// The composer's send: take the draft, reset the field, run the ladder.
    private func logFromComposer() {
        guard canLog else { return }
        if voice.isRecording { voice.stop() }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        voiceBase = ""
        composing = false
        log(text: text)
    }

    /// The resolution ladder — one place, three rungs (FUEL-FLOW §2):
    ///  1. **History** — the athlete's own meal with the same canonical key; their (possibly
    ///     hand-corrected) numbers outrank every table and every model.
    ///  2. **Staples** — every food phrase is in `FoodStaples`' deterministic table; compose
    ///     locally. "2 gels and a banana" never costs an API call, even on day one.
    ///  3. **AI** — the estimator, for everything the first two rungs honestly can't answer.
    /// Rungs 1–2 land with no shimmer: the searching beat exists because the app is genuinely
    /// searching, and on a local resolve it isn't. Deliberately does NOT touch composer state —
    /// the quick-log chips call this too, and a chip tap must never eat a draft mid-typing.
    private func log(text: String) {
        // Plan-derived and meal-independent — read BEFORE the insert, while the cache token is
        // still current (reading it after lands on the stale-token fallback and pays a full
        // engine run for a string the plan already knew).
        let label = readout.drivingSession
        // Resolved BEFORE the insert so the meal being logged can't be its own candidate.
        let remembered = FuelLocalResolver.match(for: text, in: context)

        let meal = Meal()
        meal.text = text
        let resolvedLocally: Bool
        if let remembered {
            FuelLocalResolver.copyNumbers(from: remembered, to: meal)
            resolvedLocally = true
        } else {
            resolvedLocally = FuelLocalResolver.applyStaples(to: meal, text: text)
        }

        withAnimation(Motion.standard) {
            context.insert(meal)
            try? context.save()
            refreshDerived()
        }
        // One event, one haptic. A local resolve never also fires the estimate's `Haptics.light()`
        // — two taps back to back read as a stutter, not as speed.
        Haptics.success()
        if !resolvedLocally { estimate(meal, sessionLabel: label) }
    }

    /// Fire (or re-fire) the estimate for one meal. Manual numbers always survive (`apply` guards).
    /// The task is retained by meal id so a Delete can cancel it, and the write is guarded on the
    /// model still being alive: long-pressing Delete during the ~1–3s shimmer must never come back
    /// to a deleted SwiftData object.
    ///
    /// The attempt is counted at FIRE time and handed back only on a proven `.unavailable` — a
    /// request that never returns (app killed, network hung) must burn its attempt or the cap
    /// bounds nothing, but a request that never LEFT (airplane mode, unconfigured, rate-limited
    /// before sending) billed nothing and must not spend the budget. Counting those was how an
    /// hour offline used to strand a meal for good: three tab visits at 30,000 feet exhausted the
    /// cap on calls that were never made, and landing never brought the estimate back.
    private func estimate(_ meal: Meal, sessionLabel: String?) {
        let id = meal.id
        // One bill per meal across ALL paths: if the Siri intent is mid-estimate on this meal
        // (its in-flight state lives in EstimateGate, not our task map), a second concurrent
        // call would double-bill and race the writes. Restarting OUR OWN task stays allowed.
        if estimateTasks[id] == nil, EstimateGate.isEstimating(id) { return }
        estimateTasks[id]?.cancel()
        let gateToken = EstimateGate.take(id)
        meal.estimateAttempts += 1
        try? context.save()
        let task = Task { @MainActor in
            defer { EstimateGate.end(id, token: gateToken) }
            let outcome = await estimator.estimate(text: meal.text, sessionLabel: sessionLabel, durationS: nil)
            // Cancellation normally gets here first, but a delete landing during the final
            // suspension point wouldn't be seen by it — `isDeleted` flips the moment
            // `context.delete` runs, and `modelContext` goes nil once the delete is processed.
            guard !Task.isCancelled, !meal.isDeleted, meal.modelContext != nil else {
                estimateTasks[id] = nil
                return
            }
            switch outcome {
            case .estimated(let e):
                withAnimation(Motion.standard) {
                    FuelEstimator.apply(e, to: meal)
                    meal.estimateAttempts = 0   // it resolved; nothing owed
                    try? context.save()
                    refreshDerived()
                }
                Haptics.light()
            case .unavailable:
                // Never asked, never billed — refund the attempt so the meal is still due when
                // there's a network again. Floored at 0 against any double-refund.
                meal.estimateAttempts = max(0, meal.estimateAttempts - 1)
                try? context.save()
            case .declined:
                break   // the function answered and we still have no numbers — the attempt stands
            }
            withAnimation(Motion.standard) { estimateTasks[id] = nil }
        }
        estimateTasks[id] = task
    }

    /// Self-heal: pending meals from an offline log (or a not-yet-deployed function) retry when the
    /// page appears — but only `maxEstimateAttempts` times each. Past that the meal rests on its
    /// manual-entry line and stops costing anything. Bounded to today's few — never a backlog storm.
    private func retryPendingEstimates() async {
        // The AUTO-fire estimate path. Every USER-initiated estimate() caller walls too — log() via
        // attemptLog, and "Estimate again" in the row menu — but this one fires on its own when the
        // page appears. A lapsed athlete can still hold pending meals; firing the estimator for a
        // non-entitled user spends money on a non-payer, so the wall guards the auto-retry too.
        guard paywall.isEntitled(to: .fuel) else { return }
        let label = readout.drivingSession
        let due = todayMeals.filter {
            $0.needsEstimate(maxAttempts: Self.maxEstimateAttempts) && estimateTasks[$0.id] == nil
                && !EstimateGate.isEstimating($0.id)   // a Siri estimate in flight is not "due"
        }
        for meal in due.prefix(5) {
            estimate(meal, sessionLabel: label)
        }
    }

    // MARK: The day's energy — one perfectly centered number, and the target it's aiming at

    /// The biggest numeral on the page answers "how much"; the caption beneath now answers "of how
    /// much" — the page's whole question ("fueled for the work?") answered without a tap. The
    /// phrasing mirrors the readout sheet's floor cell EXACTLY, so the two zoom levels can never
    /// disagree: a chosen goal reads "of 2,347 kcal today", the classic floor keeps its "+"
    /// ("of 2,650+ kcal" — a floor, never a ceiling). VoiceOver has said "about X of Y
    /// kilocalories" since day one; sighted athletes finally get the same sentence.
    private var kcalHeadline: some View {
        let r = readout
        return VStack(spacing: 2) {
            Text(r.kcal.formatted())
                .font(.display(30, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Text(r.kcalIsGoal ? "of \(r.kcalFloor.formatted()) kcal today" : "of \(r.kcalFloor.formatted())+ kcal")
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let note = r.goalNote {
                Text(note)
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.standard, value: r.kcal)
        .animation(Motion.standard, value: r.kcalFloor)   // a finished workout raises the floor — roll it
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Energy")
        .accessibilityValue("about \(r.kcal) of \(r.kcalFloor) kilocalories")
    }

    // MARK: The fuel gauges — energy as the headline number, four rings beneath

    /// Calories lead as a plain display numeral (the day's energy, Amy's big number); beneath it
    /// carbs · protein · fat · sodium draw toward their floors and earn iridescence exactly when
    /// a floor is met. Draw-in staggers left-to-right on appear (`trim`, transform-only, Reduce
    /// Motion renders complete); a landing estimate rolls rings and numerals together.
    private var ringsRow: some View {
        let r = readout
        // The four numbers an athlete acts on TODAY. Daily rings remain the wrong surface for
        // slow-moving markers (iron/calcium/K/Mg) — but as of 2026-07-22 those live one tap away
        // in the Today card's MICROS grid, against sex-aware floors, and are estimated again
        // (they were briefly cut 2026-07-21 while nothing displayed them; the card met the
        // stated re-add condition).
        return HStack(alignment: .top, spacing: 0) {
            FuelRing(value: r.carbsG, floor: r.carbsFloorG, label: "carbs", index: 0, tint: Theme.Fuel.carbs)
            FuelRing(value: r.proteinG, floor: r.proteinFloorG, label: "protein", index: 1, tint: Theme.Fuel.protein)
            FuelRing(value: r.fatG, floor: r.fatFloorG, label: "fat", index: 2, tint: Theme.Fuel.fat)
            FuelRing(value: r.sodiumMg, floor: r.sodiumFloorMg, label: "sodium", index: 3, tint: Theme.Fuel.sodium)
        }
        .padding(.vertical, Theme.Space.xs)
        .animation(Motion.standard, value: r)
    }

    // MARK: Your usuals — one-tap repeat (the numbers are already known; nothing waits)

    /// Most-repeated meals with numbers ready to reuse, recency-breaking ties — an established
    /// athlete sees their true usuals, a new one sees recents. Same rule, no cliff.
    ///
    /// Unlike the readout, this vends live `Meal` references, so a deleted row reaching a `ForEach`
    /// is a real hazard. The signature is the first guard; `isDeleted` on the way out is the second
    /// and the unconditional one — a tombstone is filtered here whether or not the signature
    /// noticed. Deliberately does NOT recompute on a stale signature: `computeUsuals` now runs a
    /// fetch, and a fetch in `body` is the exact pattern this whole cache exists to delete. One
    /// frame of last refresh's chips is the cheaper, safer trade.
    private var usuals: [Meal] { cachedUsuals.filter { !$0.isDeleted } }

    /// Grouped by the SAME canonical key the typed lookup uses, so "2 eggs and toast" and
    /// "2 eggs, toast" are one chip counted twice, not two chips counted once — over the SAME
    /// candidate population (`FuelLocalResolver.candidates`) and ranked by the same
    /// manual-then-recency rule, so tapping the chip and re-typing the meal produce byte-identical
    /// rows. Two windows here would mean a correction the athlete made is visible to one path and
    /// not the other. Called only from `refreshDerived`, never from `body`.
    private func computeUsuals() -> [Meal] {
        var groups: [String: (count: Int, best: Meal)] = [:]
        for meal in FuelLocalResolver.candidates(in: context) {
            let key = MealTextKey.normalized(meal.text)
            guard MealTextKey.isMatchable(key) else { continue }
            if var group = groups[key] {
                group.count += 1
                if FuelLocalResolver.outranks(meal, group.best) { group.best = meal }
                groups[key] = group
            } else {
                groups[key] = (1, meal)
            }
        }
        return groups.values
            .sorted { ($0.count, $0.best.eatenAt) > ($1.count, $1.best.eatenAt) }
            .prefix(5)
            .map(\.best)
    }

    @ViewBuilder
    private var usualsRow: some View {
        let list = usuals
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                if list.isEmpty {
                    // Day one, before any usuals exist: the staples starters. These are quick-log
                    // AFFORDANCES, not sample data — nothing logs until tapped — and they carry
                    // the teaching-by-example the composer placeholder used to (badly, truncated).
                    // Every starter composes deterministically ($0, instant; a unit test pins
                    // that), and the row hands over to the athlete's own usuals the moment they
                    // have any. Free athletes see them and hit the wall on tap, like every chip.
                    ForEach(FoodStaples.starters, id: \.self) { text in
                        Button {
                            if paywall.isEntitled(to: .fuel) { log(text: text) }
                            else { paywall.present(for: .fuel) }
                        } label: {
                            chipLabel(text)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Quick log: \(text)")
                    }
                } else {
                    ForEach(list) { meal in
                        Button {
                            // A lapsed athlete with history must still hit the wall here rather
                            // than re-log for free.
                            if paywall.isEntitled(to: .fuel) { repeatMeal(meal) }
                            else { paywall.present(for: .fuel) }
                        } label: {
                            chipLabel(title(meal))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Log again: \(title(meal))")
                    }
                }
            }
        }
    }

    /// One chip, one look — a personal usual and a staples starter are the same affordance, so
    /// they wear the same anatomy and the row never shifts style as history accrues.
    private func chipLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.inkTertiary)
            Text(text)
                .font(.rounded(Theme.FontSize.label, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.sm + 2)
        .padding(.vertical, 7)
        // 250, not 210: at 210 both visible chips routinely clipped mid-word ("dark chocolate
        // and a glass of…"). At 250 a clipped chip is rare and the next chip still peeks in from
        // the edge — the scroll affordance.
        .frame(maxWidth: 250)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.hairline))
    }

    /// One tap re-logs a usual: numbers and items copy over, the clock is now, and the old note
    /// stays behind (it narrated a different day's session). No AI round-trip, no waiting.
    /// Identical semantics to a typed local match — one definition, in `FuelLocalResolver`.
    private func repeatMeal(_ source: Meal) {
        let meal = Meal()
        meal.text = source.text
        FuelLocalResolver.copyNumbers(from: source, to: meal)
        withAnimation(Motion.standard) {
            context.insert(meal)
            try? context.save()
            refreshDerived()
        }
        Haptics.success()
    }

    // MARK: Today's meals

    /// Vends live `Meal` references, so — as with `usuals` — the signature is the first guard and
    /// the `isDeleted` filter is the unconditional one: no deleted row reaches a `ForEach` or
    /// `retryPendingEstimates()` even on a frame the signature hasn't caught up with. The
    /// stale-path recompute is kept here because it is an in-memory filter, not a fetch.
    private var todayMeals: [Meal] {
        guard isCacheValid else {
            return meals.filter { !$0.isDeleted && Calendar.current.isDateInToday($0.eatenAt) }
        }
        return cachedTodayMeals.filter { !$0.isDeleted }
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    @ViewBuilder
    private var todaysMeals: some View {
        let rows = todayMeals
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("TODAY").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                VStack(spacing: 0) {
                    ForEach(rows) { meal in
                        mealRow(meal)
                            .transition(rowTransition)
                        if meal.id != rows.last?.id {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
            }
            .animation(Motion.standard, value: rows.map(\.id))
        }
    }

    private func mealRow(_ meal: Meal) -> some View {
        // The gate covers Siri-path estimates too — without it, a meal Siri was actively
        // estimating rendered as "Couldn't estimate" and was editable mid-flight (opening the
        // sheet then saving wiped the just-landed numbers).
        let isEstimating = estimateTasks[meal.id] != nil || EstimateGate.isEstimating(meal.id)
        // Once resolved, the title is the AI's clean item list ("Eggs ×2 · Toast · Coffee") —
        // the athlete's raw words stay on the model and in the detail sheet.
        return Button {
            // An estimating row still ignores taps; otherwise entitled → open the editor, free → paywall.
            guard !isEstimating else { return }
            if paywall.isEntitled(to: .fuel) { editing = meal }
            else { paywall.present(for: .fuel) }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.sm) {
                        Text(title(meal))
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .contentTransition(.opacity)
                        Spacer(minLength: 0)
                        Text(meal.eatenAt.formatted(date: .omitted, time: .shortened))
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        // Editability is a promise, not a mystery — the quiet chevron says "tap
                        // to fix portions" without shouting it.
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                            .opacity(isEstimating ? 0 : 1)
                    }
                    Group {
                        if isEstimating {
                            EstimatingShimmer()
                                .transition(.opacity)
                        } else if let numbers = meal.journalNumbersText {
                            numbers
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                                .transition(.opacity)
                        } else {
                            Text("Couldn't estimate — tap to set the numbers")
                                .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.purple)
                                .transition(.opacity)
                        }
                    }
                    .animation(Motion.standard, value: isEstimating)
                    if let note = meal.note, !note.isEmpty {
                        Text(note).font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary).lineLimit(2)
                            .transition(.opacity)
                    }
                }
            }
            .padding(Theme.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // The cap is ours, not the athlete's — asking for it by hand always earns a fresh run.
            // `isEstimable` is the same gate the automatic path uses, minus the cap: without the
            // `manual` half of it this offered a billed call on a hand-set meal, which
            // `FuelEstimator.apply` discards on arrival. Repeatable, chargeable, and inert.
            //
            // "Estimate again" fires the billed estimator, so it is a Pro ACTION and walls exactly
            // like every sibling (send, history, goals, usuals, row tap). A meal logged while Pro
            // then downgraded (lapse/refund/--debug-free) keeps its row on the honest free page; the
            // long-press menu is a separate gesture from the gated row tap (820), so it needs its own
            // wall — otherwise a non-payer could re-fire a paid AI call, repeatably, since it also
            // zeroes the cap. The Delete item stays ungated: it spends nothing and is the athlete's
            // own data.
            if !isEstimating, meal.isEstimable {
                Button {
                    guard paywall.isEntitled(to: .fuel) else { paywall.present(for: .fuel); return }
                    meal.estimateAttempts = 0
                    estimate(meal, sessionLabel: readout.drivingSession)
                } label: { Label("Estimate again", systemImage: "sparkles") }
            }
            Button(role: .destructive) {
                // Cancel FIRST: an in-flight estimate must never come back to a deleted model.
                estimateTasks[meal.id]?.cancel()
                estimateTasks[meal.id] = nil
                withAnimation(Motion.standard) {
                    context.delete(meal)
                    try? context.save()
                    refreshDerived()
                }
                Haptics.medium()
            } label: { Label("Delete meal", systemImage: "trash") }
        }
        .accessibilityLabel("Meal: \(meal.text)")
    }

}

// MARK: - The full readout (tap-through from the strip)

/// The depth behind the strip — the COMPLETE "what am I aiming for today" reference (2026-07-22):
/// the engine's plain-words headline, the display-size carb number and full band bar, the macro
/// floor cells, the sex-aware micro floors, and what session the target is keyed to. Every target
/// here already wears the athlete's chosen goal (the engine adapts energy, protein AND carbs to
/// it). Everything is the same `DayReadout` the strip judged — one engine, two zoom levels.
private struct FuelReadoutSheet: View {
    let readout: FuelReadiness.DayReadout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let r = readout
        let fraction = min(1, CGFloat(r.carbsG) / CGFloat(max(1, r.carbsFloorG)))
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text(r.headline)
                        .font(.display(22, weight: .bold)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .reveal(0)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("≈\(r.carbsG) g")
                                .font(.display(34, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                            Text("of \(r.carbsFloorG)–\(r.carbsHighG) g carbs")
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                        }
                        Capsule().fill(Theme.surface)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(r.status == .fueled ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.Fuel.carbs))
                                    .scaleEffect(x: max(0.004, fraction), y: 1, anchor: .leading)
                                    .opacity(r.carbsG > 0 ? 1 : 0)
                            }
                            .frame(height: 10)
                            .clipShape(Capsule())
                            .accessibilityElement()
                            .accessibilityLabel("Carbohydrates")
                            .accessibilityValue("about \(r.carbsG) of \(r.carbsFloorG) grams")
                    }
                    .reveal(0.08)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              alignment: .leading, spacing: Theme.Space.md) {
                        floorCell("≈\(r.kcal)", r.kcalIsGoal ? "of \(r.kcalFloor) kcal today" : "of \(r.kcalFloor)+ kcal")
                        floorCell("≈\(r.proteinG) g", "of \(r.proteinFloorG)+ g protein")
                        floorCell("≈\(r.fatG) g", "of \(r.fatFloorG)+ g fat")
                        floorCell("≈\(r.sodiumMg)", "of \(r.sodiumFloorMg)+ mg sodium")
                    }
                    .reveal(0.14)
                    // The micros (2026-07-22): sex-aware RDA/AI floors, eaten values summed from
                    // meals that carry them. Daily RINGS were and remain the wrong surface for
                    // slow-moving markers — but the tap-through card is exactly where the complete
                    // picture belongs, and this display is what re-justified estimating them.
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("MICROS")
                            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                            .foregroundStyle(Theme.inkTertiary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                                  alignment: .leading, spacing: Theme.Space.md) {
                            floorCell("≈\(r.micros.potassiumMg.formatted())",
                                      "of \(r.micros.potassiumFloorMg.formatted())+ mg potassium")
                            floorCell("≈\(r.micros.magnesiumMg)",
                                      "of \(r.micros.magnesiumFloorMg)+ mg magnesium")
                            floorCell("≈\(ironText(r.micros.ironMg)) mg",
                                      "of \(ironText(r.micros.ironFloorMg))+ mg iron")
                            floorCell("≈\(r.micros.calciumMg.formatted())",
                                      "of \(r.micros.calciumFloorMg.formatted())+ mg calcium")
                        }
                    }
                    .reveal(0.18)
                    if let driving = r.drivingSession {
                        Text("Carb target keyed to \(driving) — glycogen banks overnight, so the eve matters as much as the morning.")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .reveal(0.20)
                    }
                    Text("Floors, never ceilings — enough to fund the work. Every number is an estimate.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .reveal(0.24)
                }
                .padding(Theme.Space.lg)
            }
            .background(Theme.background)
            .navigationTitle("Today's fueling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func floorCell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Iron carries a decimal only when it earns one — "≈4.2 mg" but "of 18+ mg", never "18.0+".
    private func ironText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - One fuel ring

/// A single gauge: value drawn as a ring toward its floor, the numeral in the middle, the metric
/// word beneath. Monochrome ink until the floor is met — then the fill is iridescent (earned).
private struct FuelRing: View {
    let value: Int
    let floor: Int
    let label: String
    var index: Int = 0
    /// The micros row renders smaller and a touch quieter — same gauge, second voice.
    var small = false
    /// The metric's ink while filling (Theme.Fuel); iridescence still owns the arrival.
    var tint: Color = Theme.ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    private var fraction: CGFloat { min(1, CGFloat(value) / CGFloat(max(1, floor))) }
    private var fueled: Bool { floor > 0 && value >= floor }
    private var diameter: CGFloat { small ? 40 : 48 }
    private var stroke: CGFloat { small ? 3.5 : 4 }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: stroke)
                Circle()
                    .trim(from: 0, to: drawn ? fraction : 0)
                    .rotation(.degrees(-90))
                    .stroke(fueled ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(tint),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    // The premium halo: each arc glows its own color, softly (static, never pulsing).
                    .shadow(color: (fueled ? Theme.iridescent.first ?? tint : tint).opacity(0.45),
                            radius: small ? 3.5 : 5)
                    .animation(Motion.lively, value: fraction)
                    .animation(Motion.standard, value: fueled)
                Text(compact(value))
                    .font(.rounded(small ? 10 : 11, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                    .animation(Motion.standard, value: value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: small ? 28 : 34)
            }
            .frame(width: diameter, height: diameter)
            Text(label)
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if reduceMotion { drawn = true }
            else { withAnimation(Motion.pen(0.8).delay(Double(index) * 0.07)) { drawn = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("about \(value) of \(floor)")
    }

    /// "645" as is; sodium-scale numbers compact to "1.9k" so they stay readable in a 48pt ring.
    private func compact(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        return String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k")
    }
}

// MARK: - The "AI is reading it" beat

/// Shimmer skeleton where a pending meal's numbers will land (FUEL-FLOW §2) — two soft bars with a
/// gradient sweep. Transform-only (an offset highlight over a fixed base, never layout); Reduce
/// Motion → the static "Estimating…" line instead.
private struct EstimatingShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        Group {
            if reduceMotion {
                Text("Estimating…")
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    bar(width: 198, delay: 0)
                    bar(width: 126, delay: 0.15)
                }
                .padding(.vertical, 3)
                .onAppear { sweep = true }
            }
        }
        .accessibilityLabel("Estimating")
    }

    private func bar(width: CGFloat, delay: Double) -> some View {
        Capsule()
            .fill(Theme.hairline)
            .frame(width: width, height: 8)
            .overlay(
                Capsule()
                    .fill(LinearGradient(colors: [.clear, Theme.inkTertiary.opacity(0.45), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * 0.5)
                    .offset(x: sweep ? width * 0.75 : -width * 0.75)
            )
            .clipShape(Capsule())
            .animation(.linear(duration: 1.25).repeatForever(autoreverses: false).delay(delay), value: sweep)
    }
}

// MARK: - Meal detail (portions first; the athlete always outranks the estimate)

/// The refine beat (FUEL-FLOW §4). Itemized meals get per-item portion steppers (±½, floor ½ —
/// stepping − at the floor removes the item, Amy-style) with totals recomputed live as Σ items;
/// meals without items (offline logs, pre-itemization history) fall back to direct total fields,
/// and "Set totals by hand" converts an itemized meal for athletes who'd rather own the numbers.
/// Any numbers change marks the meal `manual`, which a later AI estimate never overwrites.
/// Eaten-at is editable (a forgotten lunch lands right); Delete lives here too.
struct MealDetailSheet: View {
    @Bindable var meal: Meal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var items: [MealItem] = []
    @State private var eatenAt = Date()
    /// true = editing the five totals directly (no items, or the athlete chose to own them).
    @State private var totalsMode = false
    /// The athlete touched numbers (steppers, removal, mode switch) — marks the meal `manual`.
    @State private var numbersDirty = false

    @State private var carbs = ""
    @State private var kcal = ""
    @State private var protein = ""
    @State private var fat = ""
    @State private var sodium = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if !meal.text.isEmpty {
                        Text(meal.text)
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if totalsMode {
                        totalsFields
                    } else {
                        itemsCard
                        Button("Set totals by hand") { switchToTotals() }
                            .font(.rounded(Theme.FontSize.label, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, -Theme.Space.sm)
                    }
                    eatenAtRow
                    Button(role: .destructive) {
                        context.delete(meal)
                        try? context.save()
                        Haptics.medium()
                        dismiss()
                    } label: {
                        Text("Delete meal").font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, Theme.Space.md)
                }
                .padding(Theme.Space.lg)
                .animation(Motion.standard, value: totalsMode)
            }
            .background(Theme.background)
            .navigationTitle("Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.bold) }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        items = meal.items
        totalsMode = items.isEmpty
        eatenAt = meal.eatenAt
        carbs = meal.carbsG.map(String.init) ?? ""
        kcal = meal.kcal.map(String.init) ?? ""
        protein = meal.proteinG.map(String.init) ?? ""
        fat = meal.fatG.map(String.init) ?? ""
        sodium = meal.sodiumMg.map(String.init) ?? ""
    }

    // MARK: Items — portion truth belongs to the athlete

    private var itemsCard: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                itemRow(item)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
            totalsFooter
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .animation(Motion.standard, value: items.map(\.id))
    }

    private func itemRow(_ item: MealItem) -> some View {
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1)
                (Text("\(item.kcal) kcal").foregroundColor(Theme.inkTertiary)
                    + Text(" · ").foregroundColor(Theme.inkTertiary)
                    + Text("\(item.carbsG) g carbs").foregroundColor(Theme.Fuel.carbs)
                    + Text(" · ").foregroundColor(Theme.inkTertiary)
                    + Text("\(item.proteinG) g protein").foregroundColor(Theme.Fuel.protein))
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: Theme.Space.sm)
            stepper(item)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .contextMenu {
            Button(role: .destructive) { remove(item) } label: { Label("Remove item", systemImage: "trash") }
        }
        .animation(Motion.standard, value: item)
    }

    /// ±½ serving; − at the ½ floor removes the item (the natural "actually, none of that").
    private func stepper(_ item: MealItem) -> some View {
        HStack(spacing: 2) {
            stepButton("minus", label: "Less \(item.name)") { adjust(item, by: -0.5) }
            Text(item.portionLabel)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .frame(minWidth: 56)
            stepButton("plus", label: "More \(item.name)") { adjust(item, by: 0.5) }
        }
        .padding(3)
        .background(Capsule().fill(Theme.background.opacity(0.7)))
        .overlay(Capsule().stroke(Theme.hairline))
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func adjust(_ item: MealItem, by delta: Double) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        numbersDirty = true
        if delta < 0, items[i].qty <= 0.5 {
            withAnimation(Motion.standard) { _ = items.remove(at: i) }
            Haptics.medium()
            if items.isEmpty { switchToTotals(prefillFromMeal: true) }
        } else {
            let target = max(0.5, items[i].qty + delta)
            withAnimation(Motion.standard) { items[i] = items[i].scaled(to: target) }
            Haptics.light()
        }
    }

    private func remove(_ item: MealItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        numbersDirty = true
        withAnimation(Motion.standard) { _ = items.remove(at: i) }
        Haptics.medium()
        if items.isEmpty { switchToTotals(prefillFromMeal: true) }
    }

    /// Live Σ over the working items — always agrees with what Save will write.
    private var totals: (kcal: Int, carbs: Int, protein: Int, fat: Int, sodium: Int, fluids: Int) {
        (items.map(\.kcal).reduce(0, +), items.map(\.carbsG).reduce(0, +),
         items.map(\.proteinG).reduce(0, +), items.map(\.fatG).reduce(0, +),
         items.map(\.sodiumMg).reduce(0, +), items.map(\.fluidsMl).reduce(0, +))
    }

    private var totalsFooter: some View {
        let t = totals
        let dot = Text(" · ").foregroundColor(Theme.inkTertiary)
        var line = Text("≈\(t.kcal) kcal").foregroundColor(Theme.inkSecondary)
            + dot + Text("\(t.carbs) g carbs").foregroundColor(Theme.Fuel.carbs)
            + dot + Text("\(t.protein) g protein").foregroundColor(Theme.Fuel.protein)
            + dot + Text("\(t.fat) g fat").foregroundColor(Theme.Fuel.fat)
            + dot + Text("\(t.sodium) mg sodium").foregroundColor(Theme.Fuel.sodium)
        if t.fluids > 0 { line = line + dot + Text("\(t.fluids) ml").foregroundColor(Theme.inkSecondary) }
        return line
            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
            .contentTransition(.numericText())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .animation(Motion.standard, value: t.kcal + t.carbs + t.protein + t.fat + t.sodium)
    }

    /// Swap to direct total fields — from the button (prefill = live Σ) or when the last item is
    /// removed (prefill = the meal's stored numbers, so nothing silently zeroes).
    private func switchToTotals(prefillFromMeal: Bool = false) {
        if prefillFromMeal {
            carbs = meal.carbsG.map(String.init) ?? ""
            kcal = meal.kcal.map(String.init) ?? ""
            protein = meal.proteinG.map(String.init) ?? ""
            fat = meal.fatG.map(String.init) ?? ""
            sodium = meal.sodiumMg.map(String.init) ?? ""
        } else {
            let t = totals
            carbs = String(t.carbs); kcal = String(t.kcal); protein = String(t.protein)
            fat = String(t.fat); sodium = String(t.sodium)
        }
        numbersDirty = true
        withAnimation(Motion.standard) { totalsMode = true }
        Haptics.light()
    }

    // MARK: Direct totals (no items to lean on)

    private var totalsFields: some View {
        VStack(spacing: 0) {
            numberRow("Carbs", unit: "g", text: $carbs)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            numberRow("Energy", unit: "kcal", text: $kcal)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            numberRow("Protein", unit: "g", text: $protein)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            numberRow("Fat", unit: "g", text: $fat)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            numberRow("Sodium", unit: "mg", text: $sodium)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }

    private func numberRow(_ label: String, unit: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 90)
            Text(unit).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .frame(width: 32, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 12)
    }

    // MARK: When it was eaten

    private var eatenAtRow: some View {
        HStack {
            Text("Eaten").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            DatePicker("", selection: $eatenAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Eaten at")
    }

    // MARK: Save

    private var fieldsChanged: Bool {
        Int(carbs) != meal.carbsG || Int(kcal) != meal.kcal || Int(protein) != meal.proteinG
            || Int(fat) != meal.fatG || Int(sodium) != meal.sodiumMg
    }

    private func save() {
        // ALL-blank totals mean "no numbers entered", never "erase the numbers": a sheet opened
        // while an estimate was in flight snapshots empty fields, and saving a time-only edit
        // was wiping the just-landed (paid) estimate to an all-nil manual meal that could never
        // re-estimate.
        let totalsBlank = carbs.isEmpty && kcal.isEmpty && protein.isEmpty
            && fat.isEmpty && sodium.isEmpty
        if totalsMode, !totalsBlank {
            let changed = numbersDirty || fieldsChanged
            meal.itemsData = nil
            meal.carbsG = Int(carbs)
            meal.kcal = Int(kcal)
            meal.proteinG = Int(protein)
            meal.fatG = Int(fat)
            meal.sodiumMg = Int(sodium)
            if changed { meal.source = "manual" }
        } else if !totalsMode, numbersDirty {
            meal.items = items   // totals recompute as Σ items
            meal.source = "manual"
        }
        // A time-only edit deliberately does NOT mark the meal manual — a pending estimate can
        // still fill the numbers for a meal whose clock the athlete just corrected.
        meal.eatenAt = eatenAt
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
