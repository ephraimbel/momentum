import SwiftUI
import SwiftData

/// The Today deck's **Log** flow — for the workout that already happened offline. Say it or type
/// it ("ran 5 easy miles this morning", "45 min upper body, bench pressed 185 for 10 with 5
/// sets") and the receipt renders live underneath: sport, when, the numbers, the sets, and
/// whether it checks off today's planned session. One utterance can hold SEVERAL workouts — a
/// lift then a run each get their own card, and confirming logs them all. Everything saves
/// through the exact pipeline a tracked workout uses (calories, plan credit, streaks, awards).
/// Nothing is written until the athlete taps Log.
///
/// The parse ladder: `WorkoutLogParser` (deterministic, local, instant, offline) reads first;
/// when the text plainly says more than it caught, the `workout-parse` server rung reads the
/// whole sentence and completes the cards. Dictation (`VoiceTranscriber`) is input-only sugar.
/// Anything mis-read is one tap from the full manual form ("Adjust details" / "Log it manually").
struct LogActivityView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var profiles: [UserProfile]
    @Query private var library: [Exercise]

    /// "Adjust details" hands the frozen parse back to TodayView, which swaps this sheet for the
    /// full manual form pre-filled — one editor in the app, not two.
    var onAdjust: (LogWorkoutPrefill) -> Void

    /// Open holding text (the `--log-activity-draft` verification deep link).
    init(initialDraft: String = "", onAdjust: @escaping (LogWorkoutPrefill) -> Void) {
        self.onAdjust = onAdjust
        _draft = State(initialValue: initialDraft)
    }

    @State private var draft = ""
    @State private var voice = VoiceTranscriber()
    @State private var voiceBase = ""
    /// Explicit sport picks, per card — an explicit pick always beats the words.
    @State private var typeOverrides: [Int: WorkoutType] = [:]
    @State private var sportPicker: SportPickerTarget?
    @State private var saveFailed = false
    @FocusState private var composing: Bool

    // The server rung (`workout-parse`): fires on its own when the text plainly says more than
    // the grammar read. Its result is pinned to the exact text it read — one more keystroke and
    // the receipt honestly falls back to the grammar until the coach re-reads.
    @State private var aiResult: [WorkoutLogParser.Result]?
    @State private var aiReadText = ""
    @State private var aiReading = false
    @State private var aiFailed = false
    @State private var aiTask: Task<Void, Never>?

    private struct SportPickerTarget: Identifiable { let id: Int }

    // MARK: Parse (live)

    /// One receipt card per workout in the text — "lifted, then ran 4 miles" is two.
    private var parsedList: [WorkoutLogParser.Result] {
        var list = WorkoutLogParser.parseMulti(draft, weightUnit: .default(), distanceUnit: distanceUnit)
        if let ai = aiResult, aiReadText == draft {
            list = WorkoutParseService.merge(ai: ai, grammar: list)
        }
        for (i, t) in typeOverrides where i < list.count { list[i].type = t }
        return list
    }

    private var isEmptyParse: Bool { parsedList.allSatisfy(\.isEmpty) }

    /// The coach's read is on the current receipt (drives the eyebrow sparkle).
    private var coachRead: Bool { aiResult != nil && aiReadText == draft }

    private var distanceUnit: DistanceUnit { DistanceUnit.auto.resolved() }

    private func resolvedDate(_ r: WorkoutLogParser.Result) -> Date {
        WorkoutLogParser.resolveDate(dayOffset: r.dayOffset, timeHint: r.timeHint)
    }

    private func isBike(_ r: WorkoutLogParser.Result) -> Bool {
        [.ride, .mountainBikeRide, .gravelRide, .eBikeRide].contains(r.type)
    }

    private func cardSaveable(_ r: WorkoutLogParser.Result) -> Bool {
        guard let t = r.type, let d = r.durationS, d > 0 else { return false }
        if t.isGPS { return (r.distanceM ?? 0) > 0 }
        return true   // timed sports need only a duration; a duration-only lift is a real lift
    }

    /// Every card must be complete — the hints on an incomplete card say what's missing.
    private var canSave: Bool { !isEmptyParse && parsedList.allSatisfy(cardSaveable) }

    /// The receipt's plan line — computed with the same matcher that will credit on save.
    private func creditSession(_ r: WorkoutLogParser.Result) -> PlannedSession? {
        guard cardSaveable(r), let t = r.type, let d = r.durationS else { return nil }
        return PlanCoaching.creditCandidate(type: t, distanceM: r.distanceM ?? 0,
                                            durationS: d, on: resolvedDate(r),
                                            plan: profiles.first?.plan)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        header
                        composer
                        if aiReading || aiFailed { coachReadLine }
                        if isEmptyParse {
                            examples
                        } else {
                            receipts
                                .transition(.opacity.combined(with: .offset(y: 12)))
                        }
                        Color.clear.frame(height: 1).id("receiptEnd")
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.lg)
                    .animation(reduceMotion ? nil : Motion.standard, value: isEmptyParse)
                }
                // Keep the receipt in view while the keyboard is up — it grows under the field as
                // the athlete types/talks, and watching it build IS the flow.
                .onChange(of: draft) {
                    guard composing, !isEmptyParse else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo("receiptEnd", anchor: .bottom)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { close() } }
            }
            .safeAreaInset(edge: .bottom) { confirmBar }
            .sheet(item: $sportPicker) { target in
                SportPicker(selection: Binding(
                    get: { parsedList.indices.contains(target.id) ? (parsedList[target.id].type ?? .run) : .run },
                    set: { typeOverrides[target.id] = $0 })) {
                    sportPicker = nil
                }
            }
            .onChange(of: voice.transcript) { _, spoken in
                guard !spoken.isEmpty else { return }
                draft = voiceBase.isEmpty ? spoken : voiceBase + " " + spoken
            }
            .onChange(of: draft) {
                aiFailed = false
                scheduleCoachRead()
            }
            // Dictation streams the transcript continuously — hold the coach's read until the
            // mic stops, then read the settled sentence once.
            .onChange(of: voice.isRecording) { _, recording in
                if !recording { scheduleCoachRead() }
            }
            .alert("Microphone access needed", isPresented: Bindable(voice).showPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Turn on Microphone and Speech Recognition for momentum to hear your workout.")
            }
            .alert("Couldn't save your workout", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Something went wrong writing to storage. Everything you said is still here — try Log again.")
            }
            // Deliberately NO auto-focus: the mic must be one tap with no keyboard in the way
            // (dictation is the headline path), and the receipt builds in full view. Typers tap
            // the field — the standard beat.
            // A sheet that OPENS holding text (the deep-link draft) never fires onChange —
            // give the coach's read the same chance a keystroke would.
            .onAppear { if !draft.isEmpty { scheduleCoachRead() } }
            .onDisappear {
                aiTask?.cancel()
                if voice.isRecording { voice.stop() }
            }
        }
    }

    // MARK: Header + composer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What did you do?")
                .font(.display(Theme.FontSize.title, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("Say it or type it — you get the receipt before anything saves.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.top, Theme.Space.sm)
    }

    /// The same pill grammar as the fuel/coach composers: hairline at rest, soft iridescent ring
    /// while writing or dictating. One field, one mic — no send button; the parse is live.
    private var composer: some View {
        let fieldShape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return HStack(alignment: .bottom, spacing: Theme.Space.sm) {
            TextField("Ran 5 easy miles this morning…", text: $draft, axis: .vertical)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .lineLimit(1...5)
                .focused($composing)
                .padding(.leading, 4)
                .padding(.vertical, 8)
            if voice.isSupported {
                micButton
            }
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

    private var composerGlow: Bool { composing || !draft.isEmpty || voice.isRecording }

    /// Debounced server read — fires only when the grammar's receipt is plainly thinner than the
    /// text ("worked up to 225 on bench for 3…"), never while dictating, and pins its result to
    /// the exact text it read. `force` is the failed-state retry tap.
    private func scheduleCoachRead(force: Bool = false) {
        aiTask?.cancel()
        let snapshot = draft
        let text = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        if aiResult != nil, aiReadText != snapshot { aiResult = nil }   // stale read — text moved on
        guard !text.isEmpty, !voice.isRecording else { return }
        guard force || aiReadText != snapshot else { return }
        if !force {
            let grammar = WorkoutLogParser.parseMulti(text, weightUnit: .default(), distanceUnit: distanceUnit)
            guard WorkoutLogParser.looksRicher(text, than: grammar) else { return }
        }
        aiTask = Task {
            if !force { try? await Task.sleep(for: .seconds(1.1)) }
            guard !Task.isCancelled else { return }
            aiReading = true
            let outcome = await WorkoutParseService().parse(text: text, weightUnit: .default(),
                                                            distanceUnit: distanceUnit)
            aiReading = false
            guard !Task.isCancelled, draft == snapshot else { return }
            switch outcome {
            case .parsed(let list):
                aiResult = list
                aiReadText = snapshot
                Haptics.light()
            case .unavailable:
                aiFailed = true
            }
        }
    }

    /// One quiet line while (or after) the server rung runs — never a blocker, never a modal.
    @ViewBuilder
    private var coachReadLine: some View {
        if aiReading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Your coach is reading it…")
            }
            .font(.rounded(Theme.FontSize.caption, weight: .medium))
            .foregroundStyle(Theme.inkTertiary)
        } else if aiFailed {
            Button {
                aiFailed = false
                scheduleCoachRead(force: true)
            } label: {
                Label("Couldn't read it all — tap to retry", systemImage: "arrow.clockwise")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .buttonStyle(.plain)
        }
    }

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
        .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate workout")
    }

    /// Teaching by doing: each example is tappable and fills the field, so the first receipt the
    /// athlete ever sees is one the grammar is guaranteed to read perfectly.
    private var examples: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Try one")
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            exampleChip("Ran 5 easy miles this morning")
            exampleChip("Bench pressed 185 for 10 with 5 sets")
            exampleChip("45 min lift, then ran 4 miles at 9:23 pace")
        }
        .padding(.top, Theme.Space.xs)
    }

    private func exampleChip(_ text: String) -> some View {
        Button {
            draft = text
            Haptics.light()
        } label: {
            Text("“\(text)”")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 9)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: Receipts — one card per workout

    private var receipts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 5) {
                Text(parsedList.count > 1 ? "RECEIPT · \(parsedList.count) WORKOUTS" : "RECEIPT")
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(2.2)
                if coachRead {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
                        .accessibilityLabel("Read by your coach")
                }
            }
            .foregroundStyle(Theme.inkTertiary)

            ForEach(Array(parsedList.enumerated()), id: \.offset) { i, r in
                receiptCard(i, r)
            }
        }
    }

    private func receiptCard(_ index: Int, _ r: WorkoutLogParser.Result) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sportRow(index, r)
                .padding(.bottom, Theme.Space.sm)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                .padding(.bottom, Theme.Space.sm)

            VStack(spacing: 10) {
                metricRow("Duration", r.durationS.map { Formatters.duration(s: $0) })
                if r.type?.isGPS ?? false {
                    metricRow("Distance", r.distanceM.map { Formatters.distance(meters: $0, unit: distanceUnit) })
                    if let pace = paceLine(r) { metricRow(isBike(r) ? "Avg speed" : "Avg pace", pace) }
                }
                if let e = r.effort {
                    metricRow("Effort", "\(effortWord(e)) · \(e)/10")
                }
            }

            if r.type?.isStrengthStyle ?? false {
                exerciseRows(r)
            }

            if let hint = missingHint(r) {
                Text(hint)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, Theme.Space.sm)
            }

            if let credit = creditSession(r) {
                creditLine(credit, for: r)
                    .padding(.top, Theme.Space.md)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline))
    }

    private func sportRow(_ index: Int, _ r: WorkoutLogParser.Result) -> some View {
        Button {
            sportPicker = SportPickerTarget(id: index)
            Haptics.light()
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: r.type?.systemImage ?? "questionmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.background))
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.type?.title ?? "Choose a sport")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(whenLine(r))
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sport: \(r.type?.title ?? "not set"). Tap to change.")
    }

    private func whenLine(_ r: WorkoutLogParser.Result) -> String {
        let date = resolvedDate(r)
        let cal = Calendar.current
        let day = cal.isDateInToday(date) ? "Today"
            : cal.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.weekday(.wide))
        return "\(day) · \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func metricRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
                .font(.rounded(Theme.FontSize.body, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
            Text(value ?? "—")
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Theme.inkTertiary : Theme.ink)
        }
    }

    private func paceLine(_ r: WorkoutLogParser.Result) -> String? {
        guard let d = r.durationS, let m = r.distanceM, d > 0, m > 0 else { return nil }
        if isBike(r) {
            let kmh = (m / d) * 3.6
            let val = distanceUnit == .imperial ? kmh / 1.609344 : kmh
            return String(format: "%.1f %@", val, distanceUnit == .imperial ? "mph" : "km/h")
        }
        return Formatters.pace(secPerKm: d / (m / 1000), unit: distanceUnit)
    }

    private func exerciseRows(_ r: WorkoutLogParser.Result) -> some View {
        VStack(spacing: 10) {
            if r.exercises.isEmpty {
                Text("No exercises listed — Adjust details to add sets, or log it as time only.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(r.exercises.enumerated()), id: \.offset) { _, ex in
                    HStack {
                        Text(ex.name)
                            .font(.rounded(Theme.FontSize.body, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text(setLine(ex))
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    private func setLine(_ ex: WorkoutLogParser.ParsedExercise) -> String {
        guard let kg = ex.weightKg else { return "\(ex.sets)×\(ex.reps)" }
        let unit = WeightUnit.default()
        // Snap display to the nearest half — real plates come in halves, and the server's
        // kg-rounding round-trip otherwise prints "225.1 lb" for a 225 bench.
        let v = ((unit == .lb ? kg / Formatters.kgPerLb : kg) * 2).rounded() / 2
        let w = v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return "\(ex.sets)×\(ex.reps) · \(w) \(unit.rawValue)"
    }

    /// One nudge at a time toward a saveable card — the same order save checks.
    private func missingHint(_ r: WorkoutLogParser.Result) -> String? {
        if r.type == nil { return "Which sport? Tap the row above to pick." }
        if r.durationS == nil { return "How long was it? Try “45 minutes”." }
        if r.type?.isGPS ?? false, (r.distanceM ?? 0) <= 0 { return "How far? Try “5 miles” or “10k”." }
        return nil
    }

    /// The plan line wears the iridescent check — logging this IS today's progress.
    private func creditLine(_ session: PlannedSession, for r: WorkoutLogParser.Result) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .frame(width: 18, height: 18)
                .background(Circle().fill(LinearGradient(colors: Theme.iridescent,
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text("Checks off \(creditDayWord(session, for: r)) planned \(sessionLabel(session))")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func creditDayWord(_ session: PlannedSession, for r: WorkoutLogParser.Result) -> String {
        let cal = Calendar.current
        if cal.isDate(session.date, inSameDayAs: resolvedDate(r)) {
            return cal.isDateInToday(session.date) ? "today's" : "that day's"
        }
        return session.date.formatted(.dateTime.weekday(.wide)) + "'s"
    }

    private func sessionLabel(_ session: PlannedSession) -> String {
        if session.discipline == .strength { return "strength session" }
        switch session.runType {
        case .long: return "long run"
        case .easy: return "easy run"
        case .recovery: return "recovery run"
        case .freeRun, nil: return "session"
        case .some(let rt): return "\(rt.rawValue) session"
        }
    }

    private func effortWord(_ e: Int) -> String {
        switch e {
        case 1...2: "Easy"
        case 3...4: "Steady"
        case 5...6: "Moderate"
        case 7...8: "Hard"
        default: "Max"
        }
    }

    // MARK: Confirm bar

    private var confirmBar: some View {
        VStack(spacing: Theme.Space.sm) {
            OversizedButton(title: parsedList.count > 1 ? "Log \(parsedList.count) workouts" : "Log workout",
                            systemImage: "checkmark") { save() }
                .opacity(canSave ? 1 : 0.35)
                .disabled(!canSave)
            // The manual path, always one tap away. With several cards the TEXT is the editor
            // (a single pre-filled form can't hold two workouts), so the button hides.
            if parsedList.count <= 1 {
                Button {
                    adjust()
                } label: {
                    Text(isEmptyParse ? "Log it manually" : "Adjust details")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.xs)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    // MARK: Actions

    private func close() {
        aiTask?.cancel()
        if voice.isRecording { voice.stop() }
        dismiss()
    }

    /// Same pipeline as the manual form (and as a tracked save), once per card: build → calories
    /// → insert → save-or-roll-back (all cards, atomically) → plan credit → awards. A spoken
    /// workout is a real workout.
    private func save() {
        let cards = parsedList
        guard canSave, !cards.isEmpty else { return }
        aiTask?.cancel()   // the receipt is frozen the moment they confirm — no late read may land
        if voice.isRecording { voice.stop() }
        // Resolve each name once per save (the LogWorkoutView rule): the `library` snapshot
        // doesn't refresh mid-save, so two mentions of the same NEW exercise must not create
        // twin rows — across cards too.
        var resolved: [String: Exercise] = [:]
        let cachedRef: (String) -> Exercise = { name in
            let key = name.lowercased()
            if let hit = resolved[key] { return hit }
            let e = exerciseRef(named: name)
            resolved[key] = e
            return e
        }

        var workouts: [Workout] = []
        for card in cards {
            guard let type = card.type, let dur = card.durationS else { return }
            let inputs = card.exercises.map { ex in
                LogWorkoutBuilder.ExerciseInput(
                    name: ex.name,
                    sets: Array(repeating: LogWorkoutBuilder.SetInput(reps: ex.reps, weightKg: ex.weightKg),
                                count: ex.sets))
            }
            let w = LogWorkoutBuilder.make(type: type, date: resolvedDate(card), durationS: dur,
                                           distanceM: card.distanceM ?? 0, indoor: card.indoor,
                                           effort: card.effort, note: "",
                                           exercises: inputs, resolveExercise: cachedRef)
            w.calories = CalorieEstimator.kcal(for: w, bodyMassKg: profiles.first?.bodyMassKg)
            context.insert(w)
            workouts.append(w)
        }
        do { try context.save() } catch {
            workouts.forEach { context.delete($0) }   // roll back so a retry can't double-log
            saveFailed = true
            return
        }
        for w in workouts {
            PlanCoaching.creditWorkout(w, to: profiles.first?.plan, in: context)
        }
        AwardsBook.syncSoon()
        Haptics.success()
        dismiss()
    }

    private func exerciseRef(named name: String) -> Exercise {
        if let found = library.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return found }
        let e = Exercise()
        e.name = name
        e.isCustom = true
        context.insert(e)
        return e
    }

    private func adjust() {
        let p = parsedList.first ?? WorkoutLogParser.Result()
        let prefill = LogWorkoutPrefill(
            type: p.type ?? .run,
            date: resolvedDate(p),
            durationS: p.durationS ?? 45 * 60,
            distanceM: p.distanceM ?? 0,
            indoor: p.indoor,
            effort: p.effort,
            exercises: p.exercises.map { .init(name: $0.name, sets: $0.sets, reps: $0.reps, weightKg: $0.weightKg) })
        aiTask?.cancel()
        if voice.isRecording { voice.stop() }
        dismiss()
        onAdjust(prefill)
    }
}

/// The frozen parse handed to the full manual form — TodayView swaps the composer sheet for
/// `LogWorkoutView` pre-filled with these values.
struct LogWorkoutPrefill: Identifiable {
    struct ExerciseLine {
        var name: String
        var sets: Int
        var reps: Int
        var weightKg: Double?
    }

    let id = UUID()
    var type: WorkoutType
    var date: Date
    var durationS: Double
    var distanceM: Double
    var indoor: Bool
    var effort: Int?
    var exercises: [ExerciseLine]
}
