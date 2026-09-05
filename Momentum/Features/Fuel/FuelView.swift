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
    @ReducedMotionPreference private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var mealStatusHeight = 20
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
    @Query(sort: \WaterEntry.drankAt, order: .reverse) private var waterEntries: [WaterEntry]

    @State private var draft = ""
    /// In-flight estimates, retained by meal id so a Delete can CANCEL one before it comes back to a
    /// deleted SwiftData object (it also drives the shimmer, exactly like the old `Set<UUID>`).
    @State private var estimateTasks: [UUID: Task<Void, Never>] = [:]
    @State private var editing: Meal?
    @State private var manualMeal: Meal?
    @State private var showingNutrition = false
    @State private var showingHydration = false
    @State private var saveError: String?
    @State private var showingReadout = false
    @State private var showingGoals = false
    /// Drives the `.navigationDestination` for Meal history — a Button gates the push (a
    /// NavigationLink can't be intercepted), so free athletes hit the paywall instead.
    @State private var showingHistory = false
    /// Same pattern for the health-score analysis page (top-right gauge).
    @State private var showingHealth = false
    @State private var voice = VoiceTranscriber()
    @State private var voiceBase = ""
    @State private var showScanner = false
    /// The "Enjoying momentum?" soft-ask, raised after a logged meal that clears a rating
    /// milestone. Fuel is a core loop of its own — an athlete who only ever logs food reaches the
    /// same 1st/5th/15th moments a runner does (`AppReview`).
    @State private var showRatingPrompt = false
    @State private var barcodeDemoShown = false   // DEBUG --barcode-demo latch (see onAppear)
    @State private var healthDemoShown = false    // DEBUG --fuel-health latch (same pattern)
    @State private var mealDetailShown = false    // DEBUG --meal-detail latch (same pattern)
    @State private var readoutDemoShown = false   // DEBUG --fuel-readout latch (same pattern)
    /// The "Hey Siri, log a meal in Momentum" tip row — shown until the athlete dismisses it.
    @AppStorage("com.momentum.fuel.siriTip") private var siriTipVisible = true
    @FocusState private var composing: Bool
    @Environment(PaywallController.self) private var paywall
    @Environment(\.scenePhase) private var scenePhase
    /// The native App Store ask, reached only through the styled pre-prompt below — same contract
    /// as the post-workout card in `WorkoutRunner`.
    @Environment(\.requestReview) private var requestReview
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
    /// Per-meal health verdicts, computed once per refresh for the same reason (`healthVerdict`
    /// decodes `itemsData` too). Absent key = no numbers yet, no chip.
    @State private var cachedScores: [UUID: HealthScore.Verdict] = [:]
    /// The whole day's verdict — the toolbar gauge and the health page's headline number.
    @State private var cachedDayVerdict: HealthScore.Verdict?
    /// The trailing week's fueling consistency (FuelWeek) — drawn in the Today's-fueling sheet.
    @State private var cachedWeek: FuelWeek.Summary?
    /// The signature the caches were built from. nil = never built (first frame).
    @State private var cacheToken: Int?
    /// Within-pass memo for the frames the @State cache CANNOT cover: the very first paint (which
    /// runs before `.onAppear` fills it) and the frame a signature moves before its eager
    /// `refreshDerived` lands. On those frames every one of the ~7 `readout`/`tip` reads used to run
    /// the full engine pass, so opening Fuel paid for it about six times over.
    ///
    /// A reference type on purpose — writing through a class held in @State is not a SwiftUI state
    /// mutation, so it is legal from a body evaluation where touching @State would not be. Same
    /// `PreviewMemo` pattern as `FuelGoalsSheet`. It is a memo, never a cache: it is keyed on the
    /// same signature plus the minute, so it can only ever collapse duplicate reads WITHIN one
    /// frame's inputs — it can never serve a number the real cache would have refused.
    private final class PassMemo {
        var key: Int?
        var pass: (readout: FuelReadiness.DayReadout, today: [Meal], tip: String?)?
    }
    @State private var passMemo = PassMemo()
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
                    kcalHeadline.reveal(0, once: "fuel.headline")
                    readoutStrip.reveal(0.01, once: "fuel.readout")
                    ringsRow.reveal(0.02, once: "fuel.rings")
                    fluidsLine.reveal(0.03, once: "fuel.fluids")
                    composer.reveal(0.04, once: "fuel.composer")
                    nutritionActions
                    usualsRow.reveal(0.05, once: "fuel.usuals")
                    // Discoverability for hands-free logging ("Hey Siri, log a meal in Momentum").
                    // Apple's own tip row; dismissible once, forever.
                    if siriTipVisible {
                        SiriTipView(intent: LogMealIntent(), isVisible: $siriTipVisible)
                            .reveal(0.06, once: "fuel.siri")
                    }
                    todaysMeals.reveal(0.06, once: "fuel.meals")
                    // No page-footer sources link here (owner call 2026-08-11: it lives in
                    // Settings → Science & sources).
                    // ⚠️ 1.4.1 NOTE: unlike Trends/Health, this page has NO ⓘ explainer sheets,
                    // so Fuel's citation doors are the "Science & sources" link inside the
                    // Today's-fueling sheet (tap the summary strip above) and the health-score
                    // page's footer (top-right gauge — added 2026-08-15 with the score itself).
                    // If App Review ever questions findability on Fuel again, restore
                    // `SourcesFooterLink()` here first — it is the cheapest fix.
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // The health-score gauge (2026-08-15) — the day's food quality at a glance,
                    // and the door to the full analysis page. Same action-gating as every
                    // sibling: always visible, the PUSH walls for free athletes.
                    Button {
                        if paywall.isEntitled(to: .fuel) { showingHealth = true }
                        else { paywall.present(for: .fuel) }
                    } label: {
                        healthGaugeGlyph
                    }
                    .accessibilityLabel("Health score")
                    .accessibilityValue(cachedDayVerdict.map { "\($0.score) out of 100, \($0.band.word)" }
                                        ?? "No meals scored yet")
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
            .sheet(item: $editing, onDismiss: refreshDerived) { MealDetailSheet(meal: $0) }
            .sheet(item: $manualMeal, onDismiss: refreshDerived) {
                MealDetailSheet(meal: $0, isNew: true) {
                    draft = ""
                    voiceBase = ""
                    mealLogged()
                }
            }
            .sheet(isPresented: $showingNutrition, onDismiss: refreshDerived) { NutritionDaySheet() }
            .sheet(isPresented: $showingHydration, onDismiss: refreshDerived) { HydrationSheet() }
            .alert("Couldn’t save your meal", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "Please try again.") }
            .sheet(isPresented: $showingGoals) { FuelGoalsSheet() }
            // Meal history — pushed only once the gated toolbar button has confirmed entitlement.
            .navigationDestination(isPresented: $showingHistory) { FuelHistoryView() }
            // The health-score analysis page — same gated-push pattern as History.
            .navigationDestination(isPresented: $showingHealth) { FuelHealthView() }
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
            .onAppear {
                do { try HydrationStore.moveWater(in: context) }
                catch { saveError = "Older water entries could not be moved to hydration. Please try again." }
                refreshDerived()
            }
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
            // The label lane: full screen because it's a camera, not a form. The scanned meal
            // inserts through `logScanned` — label numbers, source "manual", no estimator.
            .fullScreenCover(isPresented: $showScanner) {
                BarcodeScanView { product, servings in
                    logScanned(product, servings: servings)
                }
            }
            // Its OWN host: this page already chains several presentations, and from the fourth
            // onward a cover on the same chain can silently fail to present (the same trap
            // RootView documents). The positive branch latches `recordRated` — Apple never tells
            // us whether a review was written, so tapping through is the only signal there is.
            .background {
                Color.clear.fullScreenCover(isPresented: $showRatingPrompt) {
                    RatingPromptView(
                        onRate: {
                            AppReview.recordRated()
                            showRatingPrompt = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(0.6))
                                requestReview()
                            }
                        },
                        onDismiss: { showRatingPrompt = false })
                    .presentationBackground(.clear)
                }
            }
            #if DEBUG
            // `--barcode-demo` self-presents on arrival so the sim (no camera) can screenshot
            // the confirm card from one launch: `--seed-demo --debug-pro --fuel --barcode-demo`.
            // Latched: `.onAppear` re-fires when the cover dismisses, and an unlatched present
            // would trap the page in the scanner forever (caught by BarcodeScanUITests).
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("--barcode-demo"), !barcodeDemoShown {
                    barcodeDemoShown = true
                    showScanner = true
                }
                // `--fuel-health` self-pushes the analysis page for sim screenshots/UI tests:
                // `--seed-demo --debug-pro --fuel --fuel-health`. Latched for the same reason
                // as the scanner (onAppear re-fires when the push pops).
                if ProcessInfo.processInfo.arguments.contains("--fuel-health"), !healthDemoShown {
                    healthDemoShown = true
                    showingHealth = true
                }
                // `--meal-detail` self-opens the first today-meal's detail sheet (screenshots).
                if ProcessInfo.processInfo.arguments.contains("--meal-detail"), !mealDetailShown {
                    mealDetailShown = true
                    editing = meals.first { Calendar.current.isDateInToday($0.eatenAt) }
                }
                // `--fuel-readout` self-opens the Today's-fueling sheet (same latch pattern).
                if ProcessInfo.processInfo.arguments.contains("--fuel-readout"), !readoutDemoShown {
                    readoutDemoShown = true
                    showingReadout = true
                }
            }
            #endif
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
        for water in waterEntries {
            if water.isDeleted { continue }
            guard water.drankAt >= todayStart else { break }
            h.combine(water.id); h.combine(water.drankAt); h.combine(water.amountMl)
        }
        // Today's meals, BY CONTENT — this is the line that makes a landing estimate roll the rings.
        for m in todaySlice(since: todayStart) {
            h.combine(m.id); h.combine(m.text); h.combine(m.note)
            h.combine(m.eatenAt)
            h.combine(m.kcal); h.combine(m.carbsG); h.combine(m.proteinG)
            h.combine(m.fatG); h.combine(m.sodiumMg)
            h.combine(m.potassiumMg); h.combine(m.magnesiumMg)
            h.combine(m.ironMg); h.combine(m.calciumMg)
            h.combine(m.fiberG); h.combine(m.sugarG); h.combine(m.satFatG)
            // The BREAKDOWN, not just the sums — `cachedTitles` is decoded from `itemsData`, and
            // an edit can rewrite the item list while every total above stays byte-identical:
            // removing a water or a black coffee subtracts zero from all five, and stepping a
            // zero-calorie item only moves `qty`. Without these three the row would keep naming an
            // item the athlete just deleted, which is precisely the promise the detail sheet makes
            // ("your hand outranks the estimate") read back to them as a lie. A few hundred bytes
            // per today-meal, against the engine run this cache exists to avoid.
            h.combine(m.itemsData); h.combine(m.nutritionData); h.combine(m.fluidsMl); h.combine(m.source)
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
        return uncachedPass().readout
    }

    /// The one tip line, judged with the SAME `now` as the readout it reads (as two independent
    /// computed properties they could disagree across an hour boundary mid-frame). Sharing
    /// `uncachedPass` now makes that guarantee structural rather than incidental.
    private var tip: String? {
        if isCacheValid { return cachedTip }
        return uncachedPass().tip
    }

    /// The engine pass for a frame the @State cache can't serve, run at most ONCE for that frame's
    /// inputs however many readers ask. Keyed on the cache signature plus the minute, the same two
    /// things that drive `refreshDerived`, so it expires exactly when the real cache would.
    private func uncachedPass() -> (readout: FuelReadiness.DayReadout, today: [Meal], tip: String?) {
        var h = Hasher()
        h.combine(cacheSignature)
        h.combine(minuteTick)
        let key = h.finalize()
        if passMemo.key == key, let hit = passMemo.pass { return hit }
        let pass = computeReadout(now: Date())
        passMemo.key = key
        passMemo.pass = pass
        return pass
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
                                           workouts: Array(workouts), profile: profiles.first, water: waterEntries, now: now)
        return (r, today, FuelTips.line(readout: r, now: now))
    }

    /// One pass, one place — so the body never runs an engine. Called on appear, on every signature
    /// change, on the minute tick, on foreground, and eagerly from every mutator so the change frame
    /// costs one engine run instead of four.
    private func refreshDerived() {
        // Through `uncachedPass`, not a fresh compute: the first paint already ran the full
        // engine pass into `passMemo`, and `.onAppear` used to run the identical pass a second
        // time back-to-back (perf audit 2026-08-13). Same key (signature + minute), so this can
        // never serve staler data than the direct call did.
        let pass = uncachedPass()
        cachedReadout = pass.readout
        cachedTip = pass.tip
        cachedTodayMeals = pass.today
        let repeats = computeUsuals()
        cachedUsuals = repeats
        // Decode `itemsData` once per meal per refresh instead of once per row per render pass.
        var titles: [UUID: String] = [:]
        var scores: [UUID: HealthScore.Verdict] = [:]
        var dayFacts: [HealthScore.Facts] = []
        for m in pass.today {
            titles[m.id] = m.journalTitle
            let facts = m.healthFacts
            if let v = HealthScore.aggregate(facts) { scores[m.id] = v }
            dayFacts.append(contentsOf: facts)
        }
        for m in repeats where titles[m.id] == nil { titles[m.id] = m.journalTitle }
        cachedTitles = titles
        cachedScores = scores
        cachedDayVerdict = HealthScore.aggregate(dayFacts)
        // The week strip's inputs — the query sorts newest-first, so the 7-day window is a
        // leading prefix (same reasoning as `todaySlice`). A past-day edit made in History
        // reaches this through the unconditional `.onAppear` refresh, like plan edits do.
        let weekCutoff = Calendar.current.date(byAdding: .day, value: -6,
                                               to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
        cachedWeek = FuelWeek.summary(
            meals: meals.prefix { $0.eatenAt >= weekCutoff }
                .filter { !$0.isDeleted }
                .map { FuelWeek.MealInput(eatenAt: $0.eatenAt, carbsG: $0.carbsG, proteinG: $0.proteinG) },
            bodyMassKg: profiles.first?.bodyMassKg, now: Date())
        cacheToken = cacheSignature
    }

    /// The row/chip title, decoded at refresh time. Honors the same validity guard as `usuals` and
    /// `todayMeals`: once the signature has moved, the map describes the meal as it WAS, so we pay
    /// the decode for one frame rather than name items the athlete has already removed. Falls back
    /// to the live property for a meal that simply isn't in the map — right, just at the old cost.
    /// `cacheValid` comes from the CALLER, computed once per section — `isCacheValid` re-hashes
    /// the whole day signature, and this used to run it once per journal row + twice per chip.
    private func title(_ meal: Meal, cacheValid: Bool) -> String {
        guard cacheValid, let cached = cachedTitles[meal.id] else { return meal.journalTitle }
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
        // The bar follows the goal's leading macro — carbs for plan-fueling, protein for muscle goals.
        let fraction = min(1, CGFloat(r.primaryValueG) / CGFloat(max(1, r.primaryFloorG)))
        let primaryTint = r.primary == .carbs ? Theme.Fuel.carbs : Theme.Fuel.protein
        return Button { showingReadout = true } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(statusWord(r.status))
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .contentTransition(.opacity)
                        .animation(Motion.crossfade, value: r.status)
                    Text(primaryLine(r))
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                        .monospacedDigit()
                        .modifier(NumericFeedback(value: primaryLine(r)))
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
                            .fill(r.status == .fueled ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(primaryTint))
                            .scaleEffect(x: max(0.004, fraction), y: 1, anchor: .leading)
                            .opacity(r.primaryValueG > 0 ? 1 : 0)
                    }
                    .frame(height: 5)
                    .clipShape(Capsule())
                    .animation(reduceMotion ? nil : Motion.content, value: fraction)
                    .animation(Motion.standard, value: r.status)
                // WHY this target — the driving session, on the dashboard. The plan↔fuel link is
                // the page's entire differentiator, and it lived one tap deep in the sheet; now it
                // composes with the status line as one sentence: "Fueled · ≈390 g carbs banked —
                // FOR tomorrow's long session (1h 45m)". Hidden on an easy horizon (nil), exactly
                // like the sheet's keyed-to line. Race eve steps up half a voice (secondary ink,
                // semibold) — the one morning the denominator IS the headline.
                // The plan→carb link — only when carbs lead. On a protein-first goal the session
                // still sets the carb floor, but it isn't the primary story, so it stays in the sheet.
                if r.primary == .carbs, let driving = r.drivingSession {
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
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityLabel("Fueling readout")
        .accessibilityValue(
            (r.status == .fueled ? "about \(r.primaryValueG) grams of \(r.primaryLabel) banked, floor met"
                                 : "about \(r.primaryValueG) of \(r.primaryFloorG) grams of \(r.primaryLabel)")
            + (r.primary == .carbs ? (r.drivingSession.map { ", keyed to \($0)" } ?? "") : ""))
        .accessibilityHint("Shows the full fueling detail")
        .sheet(isPresented: $showingReadout) { FuelReadoutSheet(readout: readout, week: cachedWeek) }
    }

    /// The toolbar's day-score gauge: a 22-pt ring drawn to score/100 in the band's ink with the
    /// numeral inside — the day's food quality readable from the masthead. Before anything is
    /// scored it rests as a quiet hairline ring with a heart, the affordance without a number.
    private var healthGaugeGlyph: some View {
        ZStack {
            if let v = cachedDayVerdict {
                let tint = Theme.Fuel.score(v.band)
                Circle().stroke(Theme.hairline, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(v.score) / 100)
                    .rotation(.degrees(-90))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Text("\(v.score)")
                    .font(.rounded(9, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .modifier(NumericFeedback(value: v.score))
            } else {
                Circle().stroke(Theme.hairline, lineWidth: 2.5)
                Image(systemName: "heart")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(width: 22, height: 22)
        .animation(reduceMotion ? nil : Motion.content, value: cachedDayVerdict?.score)
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

    /// The leading macro's clause after the status word. Carbs carry a band top ("210–260 g");
    /// protein is a single floor. Past the floor the fraction goes away — "≈390 of 210 g" reads
    /// like a mistake once you've sailed past it (a floor is not a denominator to overshoot); from
    /// there the total banked is the whole story, in the engine's own verb.
    private func primaryLine(_ r: FuelReadiness.DayReadout) -> String {
        let label = r.primaryLabel
        switch r.status {
        case .empty:
            return r.primary == .carbs
                ? "aiming ≈\(r.carbsFloorG)–\(r.carbsHighG) g carbs"
                : "aiming ≈\(r.proteinFloorG) g protein"
        case .fueled: return "≈\(r.primaryValueG) g \(label) banked"
        case .behind, .onTrack: return "≈\(r.primaryValueG) of \(r.primaryFloorG) g \(label)"
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
                TextField(composerPrompt, text: $draft, axis: .vertical)
                    .accessibilityIdentifier("fuel-composer")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .focused($composing)
                    .submitLabel(.send)
                    .onSubmit(attemptLog)
                    .padding(.leading, 4)
                    .padding(.vertical, 8)
            }
            if !voice.isRecording {
                scanButton
            }
            if voice.isSupported {
                micButton
            }
            Button(action: attemptLog) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.background)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(canLog ? Theme.ink : Theme.inkTertiary))
                    .scaleEffect(canLog || reduceMotion ? 1 : 0.96)
                    .animation(Motion.selection, value: canLog)
            }
            .buttonStyle(.plain)
            .disabled(!canLog)
            .accessibilityLabel("Log meal")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 6)
        // The raised white field (glass pass 2026-08-27) — the composer is the page's one
        // input, so it wears the same material as every field in the app.
        .raised(fieldShape)
        .overlay {
            if composerGlow {
                // Leaf view: keeps the 45 Hz `voice.level` read out of THIS page's body.
                DictationGlowStroke(shape: fieldShape, voice: voice,
                                    restingOpacity: draft.isEmpty ? 0.65 : 1)
            }
        }
        .animation(Motion.crossfade) { content in
            content.shadow(color: (Theme.iridescent.first ?? .clear).opacity(composerGlow ? 0.35 : 0),
                           radius: composerGlow ? 9 : 0, y: 2)
        }
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
                    MicLevelBars(voice: voice, tint: Theme.background)
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

    /// The label lane's entry — same quiet 34pt circle as the mic, hidden while dictating (the
    /// transcript needs the width, and pointing a camera mid-sentence isn't a real flow).
    private var scanButton: some View {
        Button(action: attemptScan) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan a barcode")
    }

    /// Same Pro gate as `attemptLog` — the wall lives at the action, and it opens BEFORE the
    /// athlete points a camera at dinner only to be stopped at "Log it".
    private func attemptScan() {
        guard paywall.isEntitled(to: .fuel) else { paywall.present(for: .fuel); return }
        Haptics.light()
        showScanner = true
    }

    /// Save a scanned product: label numbers verbatim × servings, `source = "manual"` (a label is
    /// ground truth, and manual is what outranks estimates when these words come back typed —
    /// `MealTextKey.outranks`). No estimator, no note (nobody wrote coaching for this snack).
    private func logScanned(_ product: BarcodeFood.ScannedProduct, servings: Double) {
        guard servings.isFinite, (0.001...10_000).contains(servings) else { return }
        let numbers = BarcodeFood.portion(of: product, servings: servings)
        let meal = Meal()
        meal.text = BarcodeFood.mealText(for: product, servings: servings)
        meal.items = [MealItem(name: product.name, qty: servings, unit: "serving",
                               kcal: numbers.kcal, carbsG: numbers.carbsG,
                               proteinG: numbers.proteinG, fatG: numbers.fatG,
                               sodiumMg: numbers.sodiumMg, fluidsMl: 0,
                               potassiumMg: numbers.potassiumMg, magnesiumMg: nil,
                               ironMg: numbers.ironMg, calciumMg: numbers.calciumMg,
                               fiberG: numbers.fiberG, sugarG: numbers.sugarG,
                               satFatG: numbers.satFatG, nova: product.nova,
                               unknownNutrients: product.sodiumIsKnown ? [.fluids] : [.fluids, .sodium])]
        // Keep the package's portion basis visible after the scanner is dismissed.
        meal.items = meal.items.map { item in
            var copy = item
            copy.servingDescription = product.servingDescription
            copy.portionBasis = MealPortionBasis(quantity: 1, nutrition: BarcodeFood.nutrition(of: product))
            return copy
        }
        meal.source = "manual"
        meal.confidence = 1
        guard commitNewMeal(meal) else { return }
        mealLogged()
        Haptics.success()
    }

    /// One logged meal: count it, then — a beat later, once the row has animated into the journal
    /// — raise the rating card if this log cleared a milestone. The delay keeps the ask off the
    /// logging moment itself, and the guards keep it from covering a sheet the athlete opened.
    private func mealLogged() {
        AppReview.recordMealLogged()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            guard editing == nil, !showingGoals, !showingHistory,
                  !showingHealth, !showScanner, !showingReadout, manualMeal == nil, !showingNutrition else { return }
            if AppReview.shouldRequestReview() { showRatingPrompt = true }
        }
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
        if log(text: text) {
            draft = ""
            voiceBase = ""
            composing = false
        }
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
    @discardableResult
    private func log(text: String) -> Bool {
        if let water = HydrationInput.milliliters(in: text) { return logWater(water) }
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

        guard commitNewMeal(meal) else { return false }
        mealLogged()
        // One event, one haptic. A local resolve never also fires the estimate's `Haptics.light()`
        // — two taps back to back read as a stutter, not as speed.
        Haptics.success()
        if !resolvedLocally { estimate(meal, sessionLabel: label) }
        return true
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
        do {
            try MealNutritionStore.update(meal, in: context) { meal.estimateAttempts += 1 }
        } catch {
            EstimateGate.end(id, token: gateToken)
            saveError = "Your meal is saved, but its estimate could not start. Please try again."
            return
        }
        let task = Task { @MainActor in
            defer { EstimateGate.end(id, token: gateToken) }
            let outcome = await estimator.estimate(text: meal.text, sessionLabel: sessionLabel, durationS: nil)
            guard EstimateGate.owns(id, token: gateToken) else { return }
            // Cancellation normally gets here first, but a delete landing during the final
            // suspension point wouldn't be seen by it — `isDeleted` flips the moment
            // `context.delete` runs, and `modelContext` goes nil once the delete is processed.
            guard !Task.isCancelled, !meal.isDeleted, meal.modelContext != nil else {
                estimateTasks[id] = nil
                return
            }
            switch outcome {
            case .estimated(let e):
                do {
                    try MealNutritionStore.update(meal, in: context) {
                        FuelEstimator.apply(e, to: meal)
                        meal.estimateAttempts = 0
                    }
                    try HydrationStore.moveWater(from: [meal], in: context)
                    refreshDerived()
                    Haptics.light()
                } catch { saveError = "Your meal is saved, but its nutrition estimate could not be saved. Please try again." }
            case .unavailable:
                // Never asked, never billed — refund the attempt so the meal is still due when
                // there's a network again. Floored at 0 against any double-refund.
                meal.estimateAttempts = max(0, meal.estimateAttempts - 1)
                try? context.save()
            case .declined:
                break   // the function answered and we still have no numbers — the attempt stands
            }
            estimateTasks[id] = nil
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

    private func commitNewMeal(_ meal: Meal) -> Bool {
        do {
            try MealNutritionStore.insert(meal, in: context)
            refreshDerived()
            return true
        } catch {
            saveError = "Your meal wasn’t saved. Your typed draft is still here; please try again."
            return false
        }
    }

    private var nutritionActions: some View {
        HStack(spacing: Theme.Space.md) {
            Button {
                guard paywall.isEntitled(to: .fuel) else { paywall.present(for: .fuel); return }
                let meal = Meal()
                meal.text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                manualMeal = meal
                composing = false
            } label: { Label("Add nutrition", systemImage: "plus.circle") }
            .accessibilityIdentifier("fuel-manual-entry")
            Spacer(minLength: 0)
            Button {
                guard paywall.isEntitled(to: .fuel) else { paywall.present(for: .fuel); return }
                showingNutrition = true
            } label: { Label("Daily totals", systemImage: "list.bullet.rectangle") }
            .accessibilityIdentifier("fuel-daily-nutrition")
        }
        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
        .foregroundStyle(Theme.ink)
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    @discardableResult
    private func logWater(_ milliliters: Int) -> Bool {
        guard paywall.isEntitled(to: .fuel) else { paywall.present(for: .fuel); return false }
        let water = WaterEntry(amountMl: Double(milliliters))
        context.insert(water)
        do {
            try context.save()
            refreshDerived()
            Haptics.success()
        } catch {
            context.delete(water)
            saveError = "Your water wasn’t saved. Please try again."
            return false
        }
        return true
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
                .modifier(NumericFeedback(value: r.kcal))
            Text(r.kcalIsGoal ? "of \(r.kcalFloor.formatted()) kcal today" : "of \(r.kcalFloor.formatted())+ kcal")
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                .monospacedDigit()
                .modifier(NumericFeedback(value: r.kcalFloor))
            let known = todayMeals.filter { $0.kcal != nil }.count
            if known < todayMeals.count {
                Text("Energy recorded for \(known) of \(todayMeals.count) entries")
                    .font(.rounded(Theme.FontSize.label)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
            }
            if let note = r.goalNote {
                Text(note)
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
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
        // The leading macro takes the first ring (index 0 reveals first): protein on muscle goals,
        // carbs on plan-fueling. Fat and sodium always trail.
        return HStack(alignment: .top, spacing: 0) {
            if r.primary == .protein {
                FuelRing(value: r.proteinG, floor: r.proteinFloorG, label: "protein", index: 0, tint: Theme.Fuel.protein)
                FuelRing(value: r.carbsG, floor: r.carbsFloorG, label: "carbs", index: 1, tint: Theme.Fuel.carbs)
            } else {
                FuelRing(value: r.carbsG, floor: r.carbsFloorG, label: "carbs", index: 0, tint: Theme.Fuel.carbs)
                FuelRing(value: r.proteinG, floor: r.proteinFloorG, label: "protein", index: 1, tint: Theme.Fuel.protein)
            }
            FuelRing(value: r.fatG, floor: r.fatFloorG, label: "fat", index: 2, tint: Theme.Fuel.fat)
            FuelRing(value: r.sodiumMg, floor: r.sodiumFloorMg, label: "sodium", index: 3, tint: Theme.Fuel.sodium)
        }
        .padding(.vertical, Theme.Space.xs)
    }

    /// Hydration, as a whisper under the rings (2026-08-15) — fluids were captured on every meal
    /// and shown nowhere. One quiet line, not a fifth ring: drinking is a floor to fund, never a
    /// gauge to race. Earns nothing; the rings own the iridescent arrivals.
    private var fluidsLine: some View {
        let r = readout
        return HStack(spacing: Theme.Space.sm) {
            Button {
                guard paywall.isEntitled(to: .fuel) else { paywall.present(for: .fuel); return }
                showingHydration = true
            } label: {
                Label("≈\(litersText(r.fluidsMl)) of \(litersText(r.fluidsFloorMl))+ fluids", systemImage: "drop")
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityLabel("Fluids, about \(r.fluidsMl) of \(r.fluidsFloorMl) milliliters or more")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fuel-water-log")
            Spacer(minLength: 0)
            Button { logWater(250) } label: {
                Text("+250 ml").font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 10).frame(minHeight: 44)
            }
            .foregroundStyle(Theme.Fuel.sodium)
            .accessibilityLabel("Log 250 milliliters of water")
            .accessibilityIdentifier("fuel-water-250")
        }
    }

    /// "850 ml" below a liter, "1.2 L" from there — the compact drink grammar.
    private func litersText(_ ml: Int) -> String {
        guard ml >= 1000 else { return "\(ml) ml" }
        let l = Double(ml) / 1000
        return l == l.rounded() ? "\(Int(l)) L" : String(format: "%.1f L", l)
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
        let chipsCacheValid = isCacheValid   // once per section, not twice per chip
        // Wrapped, not horizontally scrolled (owner call 2026-08-20, "we are only a vertical
        // app"): the old ScrollView let a vertical scroll that began on a chip drift the row
        // sideways. Wrapping shows every chip with no horizontal motion; the 250pt chip cap
        // keeps a long meal name from claiming a whole line.
        FlowLayout(spacing: Theme.Space.xs) {
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
                            chipLabel(title(meal, cacheValid: chipsCacheValid))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Log again: \(title(meal, cacheValid: chipsCacheValid))")
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
        .raised(Capsule())
    }

    /// One tap re-logs a usual: numbers and items copy over, the clock is now, and the old note
    /// stays behind (it narrated a different day's session). No AI round-trip, no waiting.
    /// Identical semantics to a typed local match — one definition, in `FuelLocalResolver`.
    private func repeatMeal(_ source: Meal) {
        let meal = Meal()
        meal.text = source.text
        FuelLocalResolver.copyNumbers(from: source, to: meal)
        guard commitNewMeal(meal) else { return }
        mealLogged()   // a re-logged usual is still the athlete using the app
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

    /// The composer greets the hour ("full tracker" pass 2026-08-20) — same question, meal-shaped.
    /// Keyed off `minuteTick`'s refresh like everything time-shaped on this page.
    private var composerPrompt: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: "What was breakfast?"
        case 11..<15: "What was lunch?"
        case 17..<22: "What was dinner?"
        default: "What did you eat?"
        }
    }

    /// The day in meal-time chapters — reverse-chronological like the flat list it replaces
    /// (newest logged stays on top), each chapter carrying its own quiet kcal sum. This is the
    /// one-page-tracker read: breakfast/lunch/dinner structure without ever asking the athlete
    /// to file anything (the clock does the filing).
    private struct Daypart: Identifiable {
        let label: String
        let kcal: Int
        let meals: [Meal]
        var id: String { label }
    }

    private func dayparts(_ rows: [Meal]) -> [Daypart] {
        let cal = Calendar.current
        func label(_ meal: Meal) -> String {
            switch cal.component(.hour, from: meal.eatenAt) {
            case 5..<11: "MORNING"
            case 11..<16: "MIDDAY"
            case 16..<22: "EVENING"
            default: "LATE"
            }
        }
        var parts: [Daypart] = []
        var current: (label: String, meals: [Meal])?
        for meal in rows {   // rows are newest-first; contiguous runs share a chapter
            let l = label(meal)
            if current?.label == l { current?.meals.append(meal) }
            else {
                if let c = current { parts.append(part(from: c)) }
                current = (l, [meal])
            }
        }
        if let c = current { parts.append(part(from: c)) }
        return parts
    }

    private func part(from run: (label: String, meals: [Meal])) -> Daypart {
        Daypart(label: run.label,
                kcal: run.meals.compactMap(\.kcal).reduce(0, +),
                meals: run.meals)
    }

    @ViewBuilder
    private var todaysMeals: some View {
        let rows = todayMeals
        let rowsCacheValid = isCacheValid   // once per section, not once per row
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("TODAY").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                VStack(spacing: 0) {
                    let parts = dayparts(rows)
                    ForEach(parts) { part in
                        daypartHeader(part)
                        ForEach(part.meals) { meal in
                            mealRow(meal, cacheValid: rowsCacheValid)
                                .transition(rowTransition)
                            if meal.id != rows.last?.id {
                                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                            }
                        }
                    }
                }
                .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        }
    }

    /// One chapter head inside the journal card: MORNING / MIDDAY / EVENING / LATE with the
    /// chapter's kcal sum trailing. A quiet filing strip, not a competing section — the card
    /// stays ONE surface.
    private func daypartHeader(_ part: Daypart) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text(part.label)
                .font(.rounded(10, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
            Spacer(minLength: 0)
            if part.kcal > 0 {
                Text("≈\(part.kcal.formatted()) kcal")
                    .font(.rounded(10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(part.label.capitalized)\(part.kcal > 0 ? ", about \(part.kcal) kilocalories" : "")")
    }

    private func mealRow(_ meal: Meal, cacheValid: Bool) -> some View {
        // The gate covers Siri-path estimates too — without it, a meal Siri was actively
        // estimating rendered as "Couldn't estimate" and was editable mid-flight (opening the
        // sheet then saving wiped the just-landed numbers).
        let isEstimating = estimateTasks[meal.id] != nil || EstimateGate.isEstimating(meal.id)
        let displayTitle = title(meal, cacheValid: cacheValid)
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
                        Text(displayTitle)
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .contentTransition(.opacity)
                            .animation(Motion.crossfade, value: displayTitle)
                        Spacer(minLength: 0)
                        // The meal's health score, in its band's ink — cached per refresh like
                        // the title (`healthVerdict` decodes items). No numbers yet, no chip.
                        if !isEstimating, cacheValid, let verdict = cachedScores[meal.id] {
                            HealthScoreChip(verdict: verdict)
                                .transition(.opacity)
                        }
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
                                .modifier(NumericFeedback(value: [meal.kcal, meal.carbsG, meal.proteinG, meal.fatG]))
                                .transition(.opacity)
                        } else {
                            Text("Couldn't estimate — tap to set the numbers")
                                .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.Fuel.protein)
                                .transition(.opacity)
                        }
                    }
                    // Keep the estimating line's space when numbers arrive. Long/large text may
                    // still grow naturally; never clip it to achieve a fixed-height illusion.
                    .frame(minHeight: mealStatusHeight, alignment: .leading)
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
        // The row button's label overrides its children for VoiceOver, which would swallow the
        // score chip — speak it as the row's value instead.
        .accessibilityValue((cacheValid ? cachedScores[meal.id] : nil)
            .map { "health score \($0.score), \($0.band.word)" } ?? "")
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
            // "Again": the second helping / the repeat coffee — a fresh now-stamped copy through
            // the same shared numbers path History's "Log again today" uses. No AI call, no
            // gating (it spends nothing and copies the athlete's own data).
            if !isEstimating, !meal.nutrition.values.isEmpty {
                Button {
                    guard paywall.isEntitled(to: .fuel) else { paywall.present(for: .fuel); return }
                    repeatMeal(meal)
                } label: { Label("Log it again", systemImage: "plus.circle") }
            }
            Button(role: .destructive) {
                // Cancel FIRST: an in-flight estimate must never come back to a deleted model.
                estimateTasks[meal.id]?.cancel()
                estimateTasks[meal.id] = nil
                do {
                    try MealNutritionStore.delete(meal, in: context)
                    refreshDerived()
                    Haptics.medium()
                } catch { saveError = "This meal could not be deleted. Please try again." }
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
    /// The trailing week's consistency (FuelWeek) — nil renders nothing (a new journal owes
    /// no verdict; the engine itself also stays silent under 3 logged days).
    var week: FuelWeek.Summary?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let r = readout
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    hero(r).reveal(0)
                    targetsCard(r).reveal(0.08)
                    if r.kcal > 0 {
                        card("ENERGY SPLIT") { macroSplit(r) }.reveal(0.13)
                    }
                    microsCard(r).reveal(0.17)
                    if let week, week.line != nil {
                        card("THE LAST 7 DAYS") { weekContent(week) }.reveal(0.20)
                    }
                    footer(r).reveal(0.24)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xl)
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Hero — the verdict, its context, and the leading macro's bar

    /// The engine's plain-words headline, the FOR line naming what the target serves (promoted
    /// from the old footer — context belongs beside the verdict, not three cards below it), and
    /// the display-size primary numeral over the full band bar.
    private func hero(_ r: FuelReadiness.DayReadout) -> some View {
        let fraction = min(1, CGFloat(r.primaryValueG) / CGFloat(max(1, r.primaryFloorG)))
        let primaryTint = r.primary == .carbs ? Theme.Fuel.carbs : Theme.Fuel.protein
        let primaryCaption = r.primary == .carbs
            ? "of \(r.carbsFloorG)–\(r.carbsHighG) g carbs"
            : "of \(r.proteinFloorG)+ g protein"
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(r.headline)
                .font(.display(22, weight: .bold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let driving = r.drivingSession {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("FOR")
                        .font(.rounded(10, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Theme.inkTertiary)
                    Text(driving)
                        .font(.rounded(Theme.FontSize.caption, weight: r.raceEve ? .semibold : .medium))
                        .foregroundStyle(r.raceEve ? Theme.inkSecondary : Theme.inkTertiary)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text("≈\(r.primaryValueG) g")
                        .font(.display(34, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(primaryCaption)
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                Capsule().fill(Theme.surface)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(r.status == .fueled ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(primaryTint))
                            .scaleEffect(x: max(0.004, fraction), y: 1, anchor: .leading)
                            .opacity(r.primaryValueG > 0 ? 1 : 0)
                    }
                    .frame(height: 10)
                    .clipShape(Capsule())
                    .accessibilityElement()
                    .accessibilityLabel(r.primaryLabel.capitalized)
                    .accessibilityValue("about \(r.primaryValueG) of \(r.primaryFloorG) grams")
            }
            .padding(.top, 2)
        }
    }

    // MARK: The cards — one titled surface per idea, the app's card grammar throughout

    /// Section chrome: tracked-caps title inside a hairlined surface card (the detail sheet's
    /// NUTRITION precedent) — one structure for every idea on the page.
    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title)
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            content()
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// Every daily floor as a live gauge cell — the number, its floor, and a hairline progress
    /// capsule in the metric's ink that turns iridescent exactly at the floor (the rings' earned
    /// rule at grid scale). Replaces the old bare-text cells: the same facts, now readable as
    /// progress at a glance.
    private func targetsCard(_ r: FuelReadiness.DayReadout) -> some View {
        // A real Grid, NOT LazyVGrid: five fixed cells gain nothing from laziness, and a lazy
        // grid below the medium-detent fold genuinely omits its cells from the accessibility
        // hierarchy — VoiceOver's rotor (and the UI suite) couldn't see the sheet's own numbers.
        card("THE DAY'S FLOORS") {
            Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.md, verticalSpacing: Theme.Space.md) {
                GridRow {
                    gaugeCell("≈\(r.kcal)", r.kcalIsGoal ? "of \(r.kcalFloor) kcal today" : "of \(r.kcalFloor)+ kcal",
                              eaten: r.kcal, floor: r.kcalFloor, tint: Theme.inkSecondary)
                    // The macro NOT in the hero bar — so all four still appear exactly once.
                    if r.primary == .carbs {
                        gaugeCell("≈\(r.proteinG) g", "of \(r.proteinFloorG)+ g protein",
                                  eaten: r.proteinG, floor: r.proteinFloorG, tint: Theme.Fuel.protein)
                    } else {
                        gaugeCell("≈\(r.carbsG) g", "of \(r.carbsFloorG)–\(r.carbsHighG) g carbs",
                                  eaten: r.carbsG, floor: r.carbsFloorG, tint: Theme.Fuel.carbs)
                    }
                }
                GridRow {
                    gaugeCell("≈\(r.fatG) g", "of \(r.fatFloorG)+ g fat",
                              eaten: r.fatG, floor: r.fatFloorG, tint: Theme.Fuel.fat)
                    gaugeCell("≈\(r.sodiumMg)", "of \(r.sodiumFloorMg)+ mg sodium",
                              eaten: r.sodiumMg, floor: r.sodiumFloorMg, tint: Theme.Fuel.sodium)
                }
                GridRow {
                    // Hydration (2026-08-15) — baseline + the day's training sweat.
                    gaugeCell("≈\(litersText(r.fluidsMl))", "of \(litersText(r.fluidsFloorMl))+ fluids",
                              eaten: r.fluidsMl, floor: r.fluidsFloorMl, tint: Theme.inkSecondary)
                }
            }
        }
    }

    /// The micros, in the same gauge-cell grammar — bars stay MONOCHROME (the metric inks are
    /// reserved until the micros earn color; the doctrine note in FuelPalette), and iridescence
    /// still marks a met floor: earned is earned at any scale.
    private func microsCard(_ r: FuelReadiness.DayReadout) -> some View {
        // A real Grid for the same reason as `targetsCard` — every cell must exist for VoiceOver
        // whatever the detent.
        card("MICROS") {
            Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.md, verticalSpacing: Theme.Space.md) {
                GridRow {
                    gaugeCell("≈\(r.micros.potassiumMg.formatted())", "of \(r.micros.potassiumFloorMg.formatted())+ mg potassium",
                              eaten: r.micros.potassiumMg, floor: r.micros.potassiumFloorMg, tint: Theme.inkSecondary)
                    gaugeCell("≈\(r.micros.magnesiumMg)", "of \(r.micros.magnesiumFloorMg)+ mg magnesium",
                              eaten: r.micros.magnesiumMg, floor: r.micros.magnesiumFloorMg, tint: Theme.inkSecondary)
                }
                GridRow {
                    gaugeCell("≈\(ironText(r.micros.ironMg)) mg", "of \(ironText(r.micros.ironFloorMg))+ mg iron",
                              eaten: Int(r.micros.ironMg * 10), floor: Int(r.micros.ironFloorMg * 10), tint: Theme.inkSecondary)
                    gaugeCell("≈\(r.micros.calciumMg.formatted())", "of \(r.micros.calciumFloorMg.formatted())+ mg calcium",
                              eaten: r.micros.calciumMg, floor: r.micros.calciumFloorMg, tint: Theme.inkSecondary)
                }
            }
        }
    }

    /// One floor, one cell: value · floor · a 3.5-pt progress capsule. Iridescent at the floor.
    private func gaugeCell(_ value: String, _ label: String, eaten: Int, floor: Int, tint: Color) -> some View {
        let fraction = min(1, CGFloat(eaten) / CGFloat(max(1, floor)))
        let met = floor > 0 && eaten >= floor
        return VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            Capsule().fill(Theme.hairline)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(met ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(tint))
                        .scaleEffect(x: max(0.004, fraction), y: 1, anchor: .leading)
                        .opacity(eaten > 0 ? 1 : 0)
                }
                .frame(height: 3.5)
                .clipShape(Capsule())
                .padding(.trailing, Theme.Space.md)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The texts stay REAL staticTexts (the old floorCell's behavior) — flattening the cell
        // into an .other container hid "mg potassium" from VoiceOver's rotor and from the UI
        // suite's staticTexts assertions alike. The bar is decorative; shapes are silent anyway.
    }

    /// Where today's energy came from — C·P·F in the rings' own inks. Distribution is
    /// information, not a target: no ideal band, no verdict, just the honest shape of the day.
    private func macroSplit(_ r: FuelReadiness.DayReadout) -> some View {
        let carbsK = Double(r.carbsG) * 4, proteinK = Double(r.proteinG) * 4, fatK = Double(r.fatG) * 9
        let total = max(1, carbsK + proteinK + fatK)
        let pc = Int((carbsK / total * 100).rounded())
        let pp = Int((proteinK / total * 100).rounded())
        let pf = max(0, 100 - pc - pp)   // the three always print to 100
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.Fuel.carbs).frame(width: geo.size.width * carbsK / total)
                    Rectangle().fill(Theme.Fuel.protein).frame(width: geo.size.width * proteinK / total)
                    Rectangle().fill(Theme.Fuel.fat)
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            HStack(spacing: 6) {
                Text("\(pc)% carbs").foregroundStyle(Theme.Fuel.carbs)
                Text("·").foregroundStyle(Theme.inkTertiary)
                Text("\(pp)% protein").foregroundStyle(Theme.Fuel.protein)
                Text("·").foregroundStyle(Theme.inkTertiary)
                Text("\(pf)% fat").foregroundStyle(Theme.Fuel.fat)
            }
            .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Energy split")
        .accessibilityValue("\(pc) percent carbs, \(pp) percent protein, \(pf) percent fat")
    }

    /// Seven dots, one honest sentence. Iridescent = the carb floor was met that day (the
    /// History dot's earned language); filled ink = logged; hairline = a gap in the journal —
    /// a gap, never a failure.
    private func weekContent(_ week: FuelWeek.Summary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 0) {
                ForEach(week.cells, id: \.day) { cell in
                    VStack(spacing: 4) {
                        ZStack {
                            if cell.carbsMet {
                                Circle().fill(AnyShapeStyle(IridescentMaterial()))
                            } else if cell.logged {
                                Circle().fill(Theme.inkTertiary.opacity(0.55))
                            } else {
                                Circle().stroke(Theme.hairline, lineWidth: 1.5)
                            }
                        }
                        .frame(width: 11, height: 11)
                        Text(cell.label)
                            .font(.rounded(9, weight: cell.isToday ? .bold : .medium))
                            .foregroundStyle(cell.isToday ? Theme.ink : Theme.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(cell.isToday ? "Today" : cell.spokenDay)
                    .accessibilityValue(cell.carbsMet ? "carb floor met"
                                        : (cell.logged ? "logged" : "not logged"))
                }
            }
            if let line = week.line {
                Text(line)
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: Footer — the doctrine, and the science door

    private func footer(_ r: FuelReadiness.DayReadout) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if r.drivingSession != nil {
                Text("Glycogen banks overnight — the eve matters as much as the morning.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Floors, never ceilings — enough to fund the work. Every number is an estimate.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            // App Review 1.4.1: the published science behind these targets, one tap away
            // right where the numbers appear.
            NavigationLink { ScienceSourcesView() } label: {
                Text("Science & sources")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .underline()
            }
            .buttonStyle(.plain)
        }
    }

    /// "850 ml" below a liter, "1.2 L" from there — mirrors the dashboard's grammar.
    private func litersText(_ ml: Int) -> String {
        guard ml >= 1000 else { return "\(ml) ml" }
        let l = Double(ml) / 1000
        return l == l.rounded() ? "\(Int(l)) L" : String(format: "%.1f L", l)
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
    @ReducedMotionPreference private var reduceMotion
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
                    .animation(reduceMotion ? nil : Motion.content, value: fraction)
                    .animation(Motion.standard, value: fueled)
                Text(compact(value))
                    .font(.rounded(small ? 10 : 11, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .modifier(NumericFeedback(value: value))
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
    @ReducedMotionPreference private var reduceMotion
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
