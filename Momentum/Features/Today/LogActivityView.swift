import SwiftUI
import SwiftData

/// The Today deck's **Log** flow — for the workout that already happened offline. Say it or type
/// it ("ran 5 easy miles this morning", "45 min upper body, bench 4x8 at 185") and the receipt
/// renders live underneath: sport, when, the numbers, the sets, and whether it checks off today's
/// planned session. Confirm, and it saves through the exact pipeline a tracked workout uses
/// (calories, plan credit, streaks, awards). Nothing is written until the athlete taps Log.
///
/// The parse is `WorkoutLogParser` — deterministic and local, so the receipt updates on every
/// keystroke with zero latency and works with no connection. Dictation (`VoiceTranscriber`) is
/// input-only sugar: spoken words land in the same field. Anything mis-read is one tap from the
/// full manual form, pre-filled with the parse ("Adjust details").
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
    @State private var typeOverride: WorkoutType?
    @State private var showSportPicker = false
    @State private var saveFailed = false
    @FocusState private var composing: Bool

    // MARK: Parse (live)

    private var parsed: WorkoutLogParser.Result {
        var p = WorkoutLogParser.parse(draft, weightUnit: .default())
        if let t = typeOverride { p.type = t }   // an explicit pick always beats the words
        return p
    }

    private var resolvedDate: Date {
        WorkoutLogParser.resolveDate(dayOffset: parsed.dayOffset, timeHint: parsed.timeHint)
    }

    private var distanceUnit: DistanceUnit { DistanceUnit.auto.resolved() }
    private var isBike: Bool {
        [.ride, .mountainBikeRide, .gravelRide, .eBikeRide].contains(parsed.type)
    }

    private var canSave: Bool {
        guard let t = parsed.type, let d = parsed.durationS, d > 0 else { return false }
        if t.isGPS { return (parsed.distanceM ?? 0) > 0 }
        return true   // timed sports need only a duration; a duration-only lift is a real lift
    }

    /// The receipt's plan line — computed with the same matcher that will credit on save.
    private var creditSession: PlannedSession? {
        guard canSave, let t = parsed.type, let d = parsed.durationS else { return nil }
        return PlanCoaching.creditCandidate(type: t, distanceM: parsed.distanceM ?? 0,
                                            durationS: d, on: resolvedDate,
                                            plan: profiles.first?.plan)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        header
                        composer
                        if parsed.isEmpty {
                            examples
                        } else {
                            receipt
                                .transition(.opacity.combined(with: .offset(y: 12)))
                        }
                        Color.clear.frame(height: 1).id("receiptEnd")
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.lg)
                    .animation(reduceMotion ? nil : Motion.standard, value: parsed.isEmpty)
                }
                // Keep the receipt in view while the keyboard is up — it grows under the field as
                // the athlete types/talks, and watching it build IS the flow.
                .onChange(of: draft) {
                    guard composing, !parsed.isEmpty else { return }
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
            .sheet(isPresented: $showSportPicker) {
                SportPicker(selection: Binding(get: { parsed.type ?? .run },
                                               set: { typeOverride = $0 })) {
                    showSportPicker = false
                }
            }
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
            .onDisappear { if voice.isRecording { voice.stop() } }
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
            exampleChip("45 min upper body, bench 4x8 at 185")
            exampleChip("Biked 40 minutes on the trainer")
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

    // MARK: Receipt

    private var receipt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECEIPT")
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.bottom, Theme.Space.sm)

            sportRow
                .padding(.bottom, Theme.Space.sm)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                .padding(.bottom, Theme.Space.sm)

            VStack(spacing: 10) {
                metricRow("Duration", parsed.durationS.map { Formatters.duration(s: $0) })
                if parsed.type?.isGPS ?? false {
                    metricRow("Distance", parsed.distanceM.map { Formatters.distance(meters: $0, unit: distanceUnit) })
                    if let pace = paceLine { metricRow(isBike ? "Avg speed" : "Avg pace", pace) }
                }
                if let e = parsed.effort {
                    metricRow("Effort", "\(effortWord(e)) · \(e)/10")
                }
            }

            if parsed.type?.isStrengthStyle ?? false {
                exerciseRows
            }

            if let hint = missingHint {
                Text(hint)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, Theme.Space.sm)
            }

            if let credit = creditSession {
                creditLine(credit)
                    .padding(.top, Theme.Space.md)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline))
    }

    private var sportRow: some View {
        Button {
            showSportPicker = true
            Haptics.light()
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: parsed.type?.systemImage ?? "questionmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.background))
                VStack(alignment: .leading, spacing: 1) {
                    Text(parsed.type?.title ?? "Choose a sport")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(whenLine)
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
        .accessibilityLabel("Sport: \(parsed.type?.title ?? "not set"). Tap to change.")
    }

    private var whenLine: String {
        let cal = Calendar.current
        let day = cal.isDateInToday(resolvedDate) ? "Today"
            : cal.isDateInYesterday(resolvedDate) ? "Yesterday"
            : resolvedDate.formatted(.dateTime.weekday(.wide))
        return "\(day) · \(resolvedDate.formatted(date: .omitted, time: .shortened))"
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

    private var paceLine: String? {
        guard let d = parsed.durationS, let m = parsed.distanceM, d > 0, m > 0 else { return nil }
        if isBike {
            let kmh = (m / d) * 3.6
            let val = distanceUnit == .imperial ? kmh / 1.609344 : kmh
            return String(format: "%.1f %@", val, distanceUnit == .imperial ? "mph" : "km/h")
        }
        return Formatters.pace(secPerKm: d / (m / 1000), unit: distanceUnit)
    }

    private var exerciseRows: some View {
        VStack(spacing: 10) {
            if parsed.exercises.isEmpty {
                Text("No exercises listed — Adjust details to add sets, or log it as time only.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(parsed.exercises.enumerated()), id: \.offset) { _, ex in
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
        // Round to a tenth BEFORE the whole-number check — the lb→kg→lb round-trip leaves
        // 185.00000000000003, which would otherwise print as "185.0 lb".
        let v = ((unit == .lb ? kg / Formatters.kgPerLb : kg) * 10).rounded() / 10
        let w = v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return "\(ex.sets)×\(ex.reps) · \(w) \(unit.rawValue)"
    }

    /// One nudge at a time toward a saveable receipt — the same order save checks.
    private var missingHint: String? {
        if parsed.type == nil { return "Which sport? Tap the row above to pick." }
        if parsed.durationS == nil { return "How long was it? Try “45 minutes”." }
        if parsed.type?.isGPS ?? false, (parsed.distanceM ?? 0) <= 0 { return "How far? Try “5 miles” or “10k”." }
        return nil
    }

    /// The plan line wears the iridescent check — logging this IS today's progress.
    private func creditLine(_ session: PlannedSession) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .frame(width: 18, height: 18)
                .background(Circle().fill(LinearGradient(colors: Theme.iridescent,
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text("Checks off \(creditDayWord(session)) planned \(sessionLabel(session))")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func creditDayWord(_ session: PlannedSession) -> String {
        let cal = Calendar.current
        if cal.isDate(session.date, inSameDayAs: resolvedDate) {
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
            OversizedButton(title: "Log workout", systemImage: "checkmark") { save() }
                .opacity(canSave ? 1 : 0.35)
                .disabled(!canSave)
            Button {
                adjust()
            } label: {
                Text(parsed.isEmpty ? "Fill it in yourself" : "Adjust details")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.xs)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    // MARK: Actions

    private func close() {
        if voice.isRecording { voice.stop() }
        dismiss()
    }

    /// Same pipeline as the manual form (and as a tracked save): build → calories → insert →
    /// save-or-roll-back → plan credit → awards. A spoken workout is a real workout.
    private func save() {
        guard canSave, let type = parsed.type, let dur = parsed.durationS else { return }
        if voice.isRecording { voice.stop() }
        let inputs = parsed.exercises.map { ex in
            LogWorkoutBuilder.ExerciseInput(
                name: ex.name,
                sets: Array(repeating: LogWorkoutBuilder.SetInput(reps: ex.reps, weightKg: ex.weightKg),
                            count: ex.sets))
        }
        // Resolve each name once per save (the LogWorkoutView rule): the `library` snapshot doesn't
        // refresh mid-save, so two mentions of the same NEW exercise must not create twin rows.
        var resolved: [String: Exercise] = [:]
        let cachedRef: (String) -> Exercise = { name in
            let key = name.lowercased()
            if let hit = resolved[key] { return hit }
            let e = exerciseRef(named: name)
            resolved[key] = e
            return e
        }
        let w = LogWorkoutBuilder.make(type: type, date: resolvedDate, durationS: dur,
                                       distanceM: parsed.distanceM ?? 0, indoor: parsed.indoor,
                                       effort: parsed.effort, note: "",
                                       exercises: inputs, resolveExercise: cachedRef)
        w.calories = CalorieEstimator.kcal(for: w, bodyMassKg: profiles.first?.bodyMassKg)
        context.insert(w)
        do { try context.save() } catch {
            context.delete(w)   // roll back the orphaned insert so a retry can't double-log
            saveFailed = true
            return
        }
        PlanCoaching.creditWorkout(w, to: profiles.first?.plan, in: context)
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
        let p = parsed
        let prefill = LogWorkoutPrefill(
            type: p.type ?? .run,
            date: resolvedDate,
            durationS: p.durationS ?? 45 * 60,
            distanceM: p.distanceM ?? 0,
            indoor: p.indoor,
            effort: p.effort,
            exercises: p.exercises.map { .init(name: $0.name, sets: $0.sets, reps: $0.reps, weightKg: $0.weightKg) })
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
