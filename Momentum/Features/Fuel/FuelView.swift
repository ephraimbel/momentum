import SwiftUI
import SwiftData

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
    @Query(sort: \Meal.eatenAt, order: .reverse) private var meals: [Meal]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Query private var profiles: [UserProfile]

    @State private var draft = ""
    @State private var estimating: Set<UUID> = []
    @State private var editing: Meal?
    @State private var showingReadout = false
    @State private var showingGoals = false
    @State private var voice = VoiceTranscriber()
    @State private var voiceBase = ""
    @FocusState private var composing: Bool
    @Environment(\.colorScheme) private var colorScheme
    private let estimator = FuelEstimator()

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
                    todaysMeals.reveal(0.24)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
                .animation(Motion.standard, value: readout.refuelDue)
            }
            .background(Theme.background)
            .navigationTitle("Fuel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The fueling adjuster — the plan adjuster's sibling (goals, body inputs, custom).
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingGoals = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Fueling goals")
                }
                // The masthead is the "momentum" wordmark itself (user call 2026-07-16) —
                // black on the light canvas, white on the dark one, at the quiet 17pt scale
                // the community masthead settled on. The tab bar still says where you are.
                ToolbarItem(placement: .principal) {
                    Image(colorScheme == .dark ? "WordmarkWhite" : "WordmarkBlack")
                        .resizable().scaledToFit()
                        .frame(height: 17)
                        .accessibilityLabel("Momentum")
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { FuelHistoryView() } label: {
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
            .onDisappear { if voice.isRecording { voice.stop() } }
        }
    }

    // MARK: Readout (SwiftData → engine inputs via the shared builder; the engine stays pure)

    private var readout: FuelReadiness.DayReadout {
        FuelReadoutBuilder.readout(meals: Array(meals), plan: profiles.first?.plan,
                                   workouts: Array(workouts), profile: profiles.first)
    }

    // MARK: Readout strip — the judgment at a glance, deliberately quiet; tap for the full story

    /// "Building · ≈90 of 350 g carbs" — status word, the carb numbers, a 5-point bar, and the one
    /// tip. Small type, no display numerals (those live in the tap-through sheet). The bar still
    /// grows by transform and still earns iridescence exactly at the floor — subtle ≠ unearned.
    private var readoutStrip: some View {
        let r = readout
        let tip = FuelTips.line(readout: r, now: Date())
        let fraction = min(1, CGFloat(r.carbsG) / CGFloat(max(1, r.carbsFloorG)))
        return Button { showingReadout = true } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(statusWord(r.status))
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .contentTransition(.opacity)
                    Text(r.status == .empty ? "aiming ≈\(r.carbsFloorG)–\(r.carbsHighG) g carbs"
                                            : "≈\(r.carbsG) of \(r.carbsFloorG) g carbs")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    if r.pendingCount > 0 {
                        Text("\(r.pendingCount) estimating…")
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
        .accessibilityValue("about \(r.carbsG) of \(r.carbsFloorG) grams of carbohydrates")
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

    private var bannerTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    private var refuelBanner: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.purple)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.purple.opacity(0.1)))
            Text("Recovery window is open — carbs + protein within the hour do the most good.")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.purple.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.purple.opacity(0.25)))
    }

    // MARK: Composer — jot it like a note, or speak it (Amy-style); logging never blocks

    /// The ChatGPT read: one clean continuous-corner pill holding the field, mic, and send — and
    /// the SAME wake-up as the coach's composer: hairline at rest, a soft iridescent ring + glow
    /// while you're writing. Static ring (no pulsing) — Reduce Motion safe by design.
    private var composer: some View {
        let fieldShape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return HStack(alignment: .bottom, spacing: Theme.Space.sm) {
            TextField("What did you eat? \u{201C}2 eggs, toast, coffee\u{201D}", text: $draft, axis: .vertical)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .lineLimit(1...4)
                .focused($composing)
                .submitLabel(.send)
                .onSubmit(log)
                .padding(.leading, 4)
                .padding(.vertical, 8)
            if voice.isSupported {
                micButton
            }
            Button(action: log) {
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
                    .opacity(draft.isEmpty ? 0.65 : 1)
            } else {
                fieldShape.stroke(Theme.hairline)
            }
        }
        .shadow(color: (Theme.iridescent.first ?? .clear).opacity(composerGlow ? 0.35 : 0),
                radius: composerGlow ? 9 : 0, y: 2)
        .animation(Motion.reversible, value: composerGlow)
        .animation(Motion.reversible, value: draft.isEmpty)
    }

    /// Awake while writing or dictating — focused, holding text, or the mic running.
    private var composerGlow: Bool { composing || !draft.isEmpty || voice.isRecording }

    /// Tap to talk, tap to stop — words stream into the field live; review, then send.
    /// Bare glyph at rest (the ChatGPT read); a filled ink circle with a live waveform while hot.
    private var micButton: some View {
        Button {
            if !voice.isRecording { voiceBase = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
            voice.toggle()
            Haptics.light()
        } label: {
            Image(systemName: voice.isRecording ? "waveform" : "mic")
                .font(.system(size: 15, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .repeating,
                              isActive: voice.isRecording && !reduceMotion)
                .foregroundStyle(voice.isRecording ? Theme.background : Theme.inkSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(voice.isRecording ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.clear)))
                .animation(Motion.standard, value: voice.isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate meal")
    }

    private var canLog: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func log() {
        guard canLog else { return }
        if voice.isRecording { voice.stop() }
        let meal = Meal()
        meal.text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(Motion.standard) {
            context.insert(meal)
            try? context.save()
        }
        Haptics.success()
        let label = readout.drivingSession
        draft = ""
        voiceBase = ""
        composing = false
        estimate(meal, sessionLabel: label)
    }

    /// Fire (or re-fire) the estimate for one meal. Manual numbers always survive (`apply` guards).
    private func estimate(_ meal: Meal, sessionLabel: String?) {
        estimating.insert(meal.id)
        Task {
            if let e = await estimator.estimate(text: meal.text, photoJPEG: nil,
                                                sessionLabel: sessionLabel, durationS: nil) {
                withAnimation(Motion.standard) {
                    FuelEstimator.apply(e, to: meal)
                    try? context.save()
                }
                Haptics.light()
            }
            _ = withAnimation(Motion.standard) { estimating.remove(meal.id) }
        }
    }

    /// Self-heal: pending meals from an offline log (or a not-yet-deployed function) retry when the
    /// page appears. Bounded to today's few — never a backlog storm.
    private func retryPendingEstimates() async {
        let label = readout.drivingSession
        for meal in todayMeals.filter({ $0.source == "pending" && $0.carbsG == nil && !estimating.contains($0.id) }).prefix(5) {
            estimate(meal, sessionLabel: label)
        }
    }

    // MARK: The day's energy — one perfectly centered number (floors live in the strip + sheet)

    private var kcalHeadline: some View {
        let r = readout
        return VStack(spacing: 2) {
            Text(r.kcal.formatted())
                .font(.display(30, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Text(r.kcalIsGoal ? "kcal goal" : "kcal")
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                .contentTransition(.opacity)
            if let note = r.goalNote {
                Text(note)
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.standard, value: r.kcal)
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
        // The four numbers an athlete acts on TODAY. Iron/calcium (and K/Mg) keep flowing into
        // the data for a future monthly coach insight — daily rings were the wrong surface for
        // slow-moving health markers built on the AI's roughest estimates.
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
    private var usuals: [Meal] {
        var byKey: [String: (count: Int, latest: Meal)] = [:]
        for meal in meals.prefix(200) where meal.carbsG != nil {
            let key = meal.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if var entry = byKey[key] {
                entry.count += 1
                if meal.eatenAt > entry.latest.eatenAt { entry.latest = meal }
                byKey[key] = entry
            } else {
                byKey[key] = (1, meal)
            }
        }
        return byKey.values
            .sorted { ($0.count, $0.latest.eatenAt) > ($1.count, $1.latest.eatenAt) }
            .prefix(5)
            .map(\.latest)
    }

    @ViewBuilder
    private var usualsRow: some View {
        let list = usuals
        if !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(list) { meal in
                        Button {
                            repeatMeal(meal)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.inkTertiary)
                                Text(meal.journalTitle)
                                    .font(.rounded(Theme.FontSize.label, weight: .semibold))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, Theme.Space.sm + 2)
                            .padding(.vertical, 7)
                            .frame(maxWidth: 210)
                            .background(Capsule().fill(Theme.surface))
                            .overlay(Capsule().stroke(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Log again: \(meal.journalTitle)")
                    }
                }
            }
        }
    }

    /// One tap re-logs a usual: numbers and items copy over, the clock is now, and the old note
    /// stays behind (it narrated a different day's session). No AI round-trip, no waiting.
    private func repeatMeal(_ source: Meal) {
        let meal = Meal()
        meal.text = source.text
        meal.itemsData = source.itemsData
        meal.kcal = source.kcal
        meal.carbsG = source.carbsG
        meal.proteinG = source.proteinG
        meal.fatG = source.fatG
        meal.sodiumMg = source.sodiumMg
        meal.fluidsMl = source.fluidsMl
        meal.potassiumMg = source.potassiumMg
        meal.magnesiumMg = source.magnesiumMg
        meal.ironMg = source.ironMg
        meal.calciumMg = source.calciumMg
        meal.source = source.source
        meal.confidence = source.confidence
        withAnimation(Motion.standard) {
            context.insert(meal)
            try? context.save()
        }
        Haptics.success()
    }

    // MARK: Today's meals

    private var todayMeals: [Meal] {
        meals.filter { Calendar.current.isDateInToday($0.eatenAt) }
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
        let isEstimating = estimating.contains(meal.id)
        // Once resolved, the title is the AI's clean item list ("Eggs ×2 · Toast · Coffee") —
        // the athlete's raw words stay on the model and in the detail sheet.
        return Button { if !isEstimating { editing = meal } } label: {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.sm) {
                        Text(meal.journalTitle)
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
            Button(role: .destructive) {
                withAnimation(Motion.standard) {
                    context.delete(meal)
                    try? context.save()
                }
                Haptics.medium()
            } label: { Label("Delete meal", systemImage: "trash") }
        }
        .accessibilityLabel("Meal: \(meal.text)")
    }

}

// MARK: - The full readout (tap-through from the strip)

/// The depth behind the strip: the engine's plain-words headline, the display-size carb number
/// and full band bar, the three floor cells, and what session the target is keyed to. Everything
/// here is the same `DayReadout` the strip judged — one engine, two zoom levels.
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
        if totalsMode {
            let changed = numbersDirty || fieldsChanged
            meal.itemsData = nil
            meal.carbsG = Int(carbs)
            meal.kcal = Int(kcal)
            meal.proteinG = Int(protein)
            meal.fatG = Int(fat)
            meal.sodiumMg = Int(sodium)
            if changed { meal.source = "manual" }
        } else if numbersDirty {
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
