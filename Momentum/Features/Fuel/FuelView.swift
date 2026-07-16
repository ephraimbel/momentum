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
    @State private var voice = VoiceTranscriber()
    @State private var voiceBase = ""
    @FocusState private var composing: Bool
    private let estimator = FuelEstimator()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    readoutHeader.reveal(0)
                    if readout.refuelDue {
                        refuelBanner
                            .transition(bannerTransition)
                    }
                    composer.reveal(0.10)
                    todaysMeals.reveal(0.16)
                    weekStrip.reveal(0.22)
                    Text(FuelingGuide.Guidance.disclaimer)
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Theme.Space.sm)
                        .reveal(0.28)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
                .animation(Motion.standard, value: readout.refuelDue)
            }
            .background(Theme.background)
            .navigationTitle("Fuel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $editing) { MealDetailSheet(meal: $0) }
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
                                   workouts: Array(workouts), bodyMassKg: profiles.first?.bodyMassKg)
    }

    // MARK: Header — the judgment, then the numbers, then one quiet tip

    private var readoutHeader: some View {
        let r = readout
        let tip = FuelTips.line(readout: r, now: Date())
        let fraction = min(1, CGFloat(r.carbsG) / CGFloat(max(1, r.carbsFloorG)))
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(r.headline)
                .font(.display(22, weight: .bold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(Motion.standard, value: r.headline)
            // Carbs — the readiness bar. Grows by TRANSFORM (scale from the leading edge, never a
            // layout change) and earns iridescence exactly when the floor is met.
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text("≈\(r.carbsG) g")
                        .font(.display(28, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                        .animation(Motion.standard, value: r.carbsG)
                    Text("of \(r.carbsFloorG)–\(r.carbsHighG) g carbs")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    Spacer(minLength: 0)
                    if r.pendingCount > 0 {
                        Text("\(r.pendingCount) estimating…")
                            .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                            .transition(.opacity)
                    }
                }
                Capsule().fill(Theme.surface)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(r.status == .fueled ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                            .scaleEffect(x: max(0.004, fraction), y: 1, anchor: .leading)
                            .opacity(r.carbsG > 0 ? 1 : 0)
                    }
                    .frame(height: 10)
                    .clipShape(Capsule())
                    .animation(Motion.lively, value: fraction)
                    .animation(Motion.standard, value: r.status)
                    .accessibilityElement()
                    .accessibilityLabel("Carbohydrates")
                    .accessibilityValue("about \(r.carbsG) of \(r.carbsFloorG) grams")
            }
            // The floors — quiet, ≈, never a ceiling.
            HStack(spacing: 0) {
                floorCell("≈\(r.kcal)", "of \(r.kcalFloor)+ kcal")
                floorCell("≈\(r.proteinG) g", "of \(r.proteinFloorG)+ protein")
                floorCell("≈\(r.sodiumMg)", "of \(r.sodiumFloorMg)+ mg sodium")
            }
            .animation(Motion.standard, value: r)
            // One deterministic tip, often absent — silence is a feature (FuelTips).
            if let tip {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("TIP")
                        .font(.rounded(10, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Theme.inkTertiary)
                    Text(tip)
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.standard, value: tip)
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }

    private func floorCell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Text(label).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.sm) {
            TextField("What did you eat? \u{201C}2 eggs, toast, coffee\u{201D}", text: $draft, axis: .vertical)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .lineLimit(1...4)
                .focused($composing)
                .submitLabel(.send)
                .onSubmit(log)
            if voice.isSupported {
                micButton
            }
            Button(action: log) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.background)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(canLog ? Theme.ink : Theme.inkTertiary))
                    .scaleEffect(canLog ? 1 : 0.92)
                    .animation(Motion.lively, value: canLog)
            }
            .buttonStyle(.plain)
            .disabled(!canLog)
            .accessibilityLabel("Log meal")
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
    }

    /// Tap to talk, tap to stop — words stream into the field live; review, then send.
    private var micButton: some View {
        Button {
            if !voice.isRecording { voiceBase = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
            voice.toggle()
            Haptics.light()
        } label: {
            Image(systemName: voice.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .repeating,
                              isActive: voice.isRecording && !reduceMotion)
                .foregroundStyle(voice.isRecording ? Theme.background : Theme.inkSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(voice.isRecording ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.background.opacity(0.7))))
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
                        Text(rowTitle(meal))
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .contentTransition(.opacity)
                        Spacer(minLength: 0)
                        Text(meal.eatenAt.formatted(date: .omitted, time: .shortened))
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                    Group {
                        if isEstimating {
                            EstimatingShimmer()
                                .transition(.opacity)
                        } else if let carbs = meal.carbsG {
                            Text(numbersLine(meal, carbs: carbs))
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.inkSecondary)
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

    private func rowTitle(_ meal: Meal) -> String {
        let items = meal.items
        guard !items.isEmpty else { return meal.text }
        return items.map { $0.qty == 1 ? $0.name : "\($0.name) ×\($0.qtyText)" }.joined(separator: " · ")
    }

    private func numbersLine(_ meal: Meal, carbs: Int) -> String {
        var parts = ["≈\(carbs) g carbs"]
        if let kcal = meal.kcal { parts.append("\(kcal) kcal") }
        if let p = meal.proteinG { parts.append("\(p) g protein") }
        if let s = meal.sodiumMg { parts.append("\(s) mg sodium") }
        return parts.joined(separator: " · ")
    }

    // MARK: The week, at a glance — filled dot = that day met the easy floor

    private var weekStrip: some View {
        let cal = Calendar.current
        let kg = profiles.first?.bodyMassKg ?? FuelReadiness.fallbackMassKg
        let easyFloor = Int(FuelReadiness.carbsPerKgEasy * kg)
        let days: [(String, Bool, Bool)] = (0..<7).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: Date())!
            let dayMeals = meals.filter { cal.isDate($0.eatenAt, inSameDayAs: day) }
            let carbs = dayMeals.compactMap(\.carbsG).reduce(0, +)
            let letter = day.formatted(.dateTime.weekday(.narrow))
            return (letter, !dayMeals.isEmpty, carbs >= easyFloor)
        }
        return HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 5) {
                    Circle()
                        .fill(day.2 ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(day.1 ? Theme.inkTertiary : Theme.surface))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: day.1 ? 0 : 1))
                    Text(day.0).font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, Theme.Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last seven days of fueling")
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
private struct MealDetailSheet: View {
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
                Text("\(item.kcal) kcal · \(item.carbsG) g carbs · \(item.proteinG) g protein")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
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
        var line = "≈\(t.kcal) kcal · \(t.carbs) g carbs · \(t.protein) g protein · \(t.fat) g fat · \(t.sodium) mg sodium"
        if t.fluids > 0 { line += " · \(t.fluids) ml" }
        return Text(line)
            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Theme.inkSecondary)
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
