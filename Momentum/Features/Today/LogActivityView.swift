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
    @Environment(Services.self) private var services   // records → Health mirror → funnel, same as a tracked save
    @Query private var profiles: [UserProfile]
    @Query private var library: [Exercise]
    /// A short window of recent sessions — only to offer them back as one-tap repeats. Bounded:
    /// this sheet must never pay for the whole history to draw its blank slate.
    static var recents: FetchDescriptor<Workout> {
        var d = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = 12
        return d
    }
    @Query(LogActivityView.recents) private var recentWorkouts: [Workout]

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
    /// Per-card manual edits from the card editor (tap a card → full form → Save returns here).
    /// An edit REPLACES that card's parse; any change to the text clears all edits (the words are
    /// the source of truth again) and edits freeze the coach's re-reads (the athlete took over).
    @State private var cardEdits: [Int: LogWorkoutPrefill] = [:]
    /// Durations chosen with one tap on a card's chip row, for the workout the athlete described
    /// perfectly except for how long it took (every lift, basically). Cleared with the text, like
    /// every other derived state here — the words are the source of truth.
    @State private var durationPicks: [Int: Double] = [:]
    /// Cards the athlete took off the receipt. A sentence can split into a workout they never meant
    /// ("ran 4 miles then walked the dog back") and the only way out was to rewrite the text —
    /// with an incomplete phantom card blocking the log button while they worked out why.
    @State private var dismissedCards: Set<Int> = []
    /// The card being edited in the nested form sheet.
    @State private var editingCard: EditingCard?
    @State private var saveFailed = false
    /// Drives the "you did it" beat that plays over the composer after a successful log.
    @State private var celebrating = false
    @FocusState private var composing: Bool

    private struct EditingCard: Identifiable {
        let id: Int
        var prefill: LogWorkoutPrefill
    }

    // The server rung (`workout-parse`): fires on its own when the text plainly says more than
    // the grammar read. Its result is pinned to the exact text it read — one more keystroke and
    // the receipt honestly falls back to the grammar until the coach re-reads.
    @State private var aiResult: [WorkoutLogParser.Result]?
    @State private var aiReadText = ""
    @State private var aiReading = false
    @State private var aiFailed = false
    @State private var aiTask: Task<Void, Never>?
    /// Only the newest read may touch `aiReading`/`aiFailed` — a superseded task finishing late
    /// must not kill the spinner the newer task owns.
    @State private var aiGeneration = 0

    // MARK: Parse (live)

    /// Grammar + coach read, before the athlete's explicit sport picks. Memoized per
    /// (draft, AI-merge) change: `parseMulti` compiles the full regex grammar per call, and the
    /// body reads this ~6× per render — every keystroke and every live-dictation tick was
    /// re-running the grammar a dozen times exactly during the streaming moment the feature is
    /// built around. A reference box (fields unobserved), the codebase's standard memo idiom.
    private final class ParseMemo {
        var key = "\u{0}"
        var value: [WorkoutLogParser.Result] = []
        /// Sports the text named without numbers — dropped from the receipt on purpose, surfaced
        /// in a line so the drop is never silent.
        var unlogged: [WorkoutType] = []
    }
    @State private var parseMemo = ParseMemo()
    private func refreshMemo() {
        let aiApplies = aiResult != nil && aiReadText == draft
        let key = "\(aiApplies)|\(aiGeneration)|\(draft)"
        guard parseMemo.key != key else { return }
        let parsed = WorkoutLogParser.parseMultiDetailed(draft, weightUnit: .default(),
                                                         distanceUnit: distanceUnit)
        var list = parsed.results
        if aiApplies, let ai = aiResult {
            list = WorkoutParseService.merge(ai: ai, grammar: list)
        }
        parseMemo.key = key
        parseMemo.value = list
        // A coach read that came back with more cards has already accounted for the mention.
        parseMemo.unlogged = list.count > parsed.results.count ? [] : parsed.unlogged
    }
    private var mergedList: [WorkoutLogParser.Result] {
        refreshMemo()
        return parseMemo.value
    }
    /// Disciplines the athlete said but gave no numbers for. Named out loud below the receipt —
    /// "45 min upper body then went for a run" used to log the lift and drop the run without a word.
    private var unloggedMentions: [WorkoutType] {
        refreshMemo()
        return parseMemo.unlogged
    }

    /// One receipt card per workout in the text — "lifted, then ran 4 miles" is two. A card the
    /// athlete edited by hand shows its edit; the rest show the parse, with shared time contexts
    /// staggered so the chain reads in the order it happened.
    private struct Card {
        /// Position in the parsed list — the key every per-card override is filed under
        /// (`cardEdits`, `durationPicks`, `dismissedCards`), and stable while the text is. NOT the
        /// position on screen: removing a card leaves the others' keys exactly where they were.
        var index: Int
        var result: WorkoutLogParser.Result
        var date: Date
        var edited: Bool
    }

    private var cards: [Card] {
        let list = mergedList
        // Dates are stacked across the FULL list: the chain's time order is a property of the
        // sentence, so removing the middle card must not slide the others' clocks.
        let stacked = WorkoutLogParser.stackedDates(for: list)
        return list.indices.compactMap { i in
            guard !dismissedCards.contains(i) else { return nil }
            guard let e = cardEdits[i] else {
                var r = list[i]
                // A tapped duration chip fills the one gap the words left. It can only ever ADD the
                // missing number — anything the athlete actually said (or the coach later read)
                // still wins, so this can't quietly overwrite a fact.
                if r.durationS == nil, let picked = durationPicks[i] { r.durationS = picked }
                return Card(index: i, result: r, date: stacked[i], edited: false)
            }
            var r = WorkoutLogParser.Result()
            r.type = e.type
            r.indoor = e.indoor
            r.durationS = e.durationS > 0 ? e.durationS : nil
            r.distanceM = e.distanceM > 0 ? e.distanceM : nil
            r.effort = e.effort
            r.exercises = e.exercises.map { .init(name: $0.name, sets: $0.sets, reps: $0.reps, weightKg: $0.weightKg) }
            return Card(index: i, result: r, date: e.date, edited: true)
        }
    }

    private var isEmptyParse: Bool { mergedList.allSatisfy(\.isEmpty) && cardEdits.isEmpty }

    private var distanceUnit: DistanceUnit { DistanceUnit.auto.resolved() }

    private func isBike(_ r: WorkoutLogParser.Result) -> Bool {
        [.ride, .mountainBikeRide, .gravelRide, .eBikeRide].contains(r.type)
    }

    /// A sport and a duration make a loggable workout. Distance is a nudge, never a blocker —
    /// "walked the dog for 30 min" and "ran for 40 minutes" are real logs exactly as said.
    private func cardSaveable(_ r: WorkoutLogParser.Result) -> Bool {
        r.type != nil && (r.durationS ?? 0) > 0
    }

    /// Every card must be complete — the hints on an incomplete card say what's missing.
    /// `allSatisfy` is vacuously true on an empty list, so the card count is checked explicitly —
    /// the dismiss control can't empty the receipt today, but a button that looks live and does
    /// nothing is not a failure mode worth leaving to a UI rule.
    private var canSave: Bool {
        !isEmptyParse && !cards.isEmpty && cards.allSatisfy { cardSaveable($0.result) }
    }

    /// The receipt's plan line — computed with the same matcher that will credit on save.
    private func creditSession(_ card: Card) -> PlannedSession? {
        guard cardSaveable(card.result), let t = card.result.type, let d = card.result.durationS else { return nil }
        return PlanCoaching.creditCandidate(type: t, distanceM: card.result.distanceM ?? 0,
                                            durationS: d, on: card.date,
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
                            if !unloggedMentions.isEmpty { unloggedLine }
                            if !dismissedCards.isEmpty { undoRemovedLine }
                            editHint
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
            // The per-card editor: the full manual form, nested so the OTHER cards survive.
            // Save returns the values into the card; nothing writes until Log confirms them all.
            .sheet(item: $editingCard) { target in
                LogWorkoutView(prefill: target.prefill) { edited in
                    cardEdits[target.id] = edited
                }
            }
            .onChange(of: voice.transcript) { _, spoken in
                guard !spoken.isEmpty else { return }
                draft = voiceBase.isEmpty ? spoken : voiceBase + " " + spoken
            }
            .onChange(of: draft) {
                aiFailed = false
                cardEdits = [:]        // the words changed — they're the source of truth again
                durationPicks = [:]    // …and a chip tapped for the old sentence means nothing now
                dismissedCards = []    // …nor does a card removed from a receipt that no longer exists
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
                voice.stopIfRecording()   // covers the mid-start permission window too
            }
        }
        .overlay {
            if celebrating {
                // The beat IS the exit: the drawn circle+check plays over the composer, then
                // dismisses it — a logged workout earns the same completion moment a tracked one does.
                CompletionCelebration(title: celebrationTitle) { dismiss() }
                    .transition(.opacity)
            }
        }
    }

    /// The completion beat's headline — honest "logged" (a past workout recorded), by sport when
    /// there's one card, counted when the sentence held several.
    private var celebrationTitle: String {
        if cards.count > 1 { return "\(cards.count) workouts logged" }
        return (cards.first?.result.type?.title).map { "\($0) logged" } ?? "Workout logged"
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
    /// while writing — and while DICTATING the field becomes a live transcript (tail always
    /// visible), the mic becomes a voice-reactive meter, and the ring breathes with the voice.
    private var composer: some View {
        let fieldShape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return HStack(alignment: .bottom, spacing: Theme.Space.sm) {
            if dictating {
                LiveTranscriptView(text: dictationDemo ? Self.demoTranscript : draft)
                    .padding(.leading, 4)
                    .padding(.vertical, 8)
            } else {
                TextField("Ran 5 easy miles this morning…", text: $draft, axis: .vertical)
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1...5)
                    .focused($composing)
                    .padding(.leading, 4)
                    .padding(.vertical, 8)
            }
            if voice.isSupported || dictationDemo {
                micButton
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 6)
        .background(fieldShape.fill(Theme.surface))
        .overlay {
            if composerGlow, !dictationDemo {
                // Leaf view: keeps the 45 Hz `voice.level` read out of this page's body.
                DictationGlowStroke(shape: fieldShape, voice: voice,
                                    restingOpacity: draft.isEmpty && !dictating ? 0.65 : 1)
            } else if composerGlow {
                // --dictation-demo: fixed level, no live transcriber to read.
                fieldShape
                    .stroke(LinearGradient(colors: Theme.iridescent,
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.5)
                    .opacity(reduceMotion ? 1 : 0.55 + 0.45 * 0.8)
            } else {
                fieldShape.stroke(Theme.hairline)
            }
        }
        .shadow(color: (Theme.iridescent.first ?? .clear).opacity(composerGlow ? 0.35 : 0),
                radius: composerGlow ? 9 : 0, y: 2)
        .animation(Motion.reversible, value: composerGlow)
        .animation(Motion.reversible, value: draft.isEmpty)
        .animation(Motion.standard, value: dictating)
    }

    private var composerGlow: Bool { composing || !draft.isEmpty || dictating }
    private var dictating: Bool { voice.isRecording || dictationDemo }

    /// `--dictation-demo`: renders the recording-state composer with a fixed level so the
    /// dictation design can be screenshot-verified (the Simulator can't be spoken to).
    private var dictationDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--dictation-demo")
        #else
        false
        #endif
    }

    private static let demoTranscript =
        "Ran 6 easy miles this morning, felt strong on the hills and finished with four strides"

    /// Debounced server read — fires only when the grammar's receipt is plainly thinner than the
    /// text ("worked up to 225 on bench for 3…"), never while dictating, and pins its result to
    /// the exact text it read. `force` is the failed-state retry tap.
    private func scheduleCoachRead(force: Bool = false) {
        aiTask?.cancel()
        let snapshot = draft
        let text = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        if aiResult != nil, aiReadText != snapshot { aiResult = nil }   // stale read — text moved on
        // Hand edits freeze the ladder: a late-landing read must never overwrite what the
        // athlete just fixed by hand. Editing the text again unfreezes it.
        guard cardEdits.isEmpty else { return }
        guard !text.isEmpty, !voice.isRecording else { return }
        guard force || aiReadText != snapshot else { return }
        aiGeneration += 1
        let gen = aiGeneration
        aiTask = Task {
            if !force {
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled, gen == aiGeneration else { return }
                // The richer-than-grammar gate runs AFTER the debounce, once per settled
                // sentence. It used to run synchronously on every keystroke — a second full
                // parseMulti (hundreds of uncached regex compiles) per character, on the main
                // thread, before the debounce could help (audit 2026-08-11).
                let grammar = WorkoutLogParser.parseMulti(text, weightUnit: .default(), distanceUnit: distanceUnit)
                guard WorkoutLogParser.looksRicher(text, than: grammar) else { return }
            }
            guard !Task.isCancelled, gen == aiGeneration else { return }
            aiReading = true
            let outcome = await WorkoutParseService().parse(text: text, weightUnit: .default(),
                                                            distanceUnit: distanceUnit)
            guard gen == aiGeneration else { return }   // superseded — the newer task owns the UI
            aiReading = false
            guard !Task.isCancelled, draft == snapshot else { return }
            switch outcome {
            case .parsed(let list):
                guard cardEdits.isEmpty else { return }   // edited mid-flight — their fix wins
                // The coach's read can change the CARD LIST (that's its whole point), and the
                // per-card overrides are keyed by INDEX into the old list — a removed card #1 or
                // a duration chip on old card #0 would silently attach to a different workout in
                // the new list (audit 2026-08-11). Same reset the text-change path does.
                durationPicks = [:]
                dismissedCards = []
                editingCard = nil
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
            ZStack {
                Circle().fill(dictating ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.clear))
                if dictationDemo {
                    VoiceLevelBars(level: 0.7, tint: Theme.background)
                } else if dictating {
                    MicLevelBars(voice: voice, tint: Theme.background)
                } else {
                    Image(systemName: "mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(width: 34, height: 34)
            .animation(Motion.standard, value: dictating)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictating ? "Stop dictation" : "Dictate workout")
    }

    /// Teaching by doing: each example is tappable and fills the field, so the first receipt the
    /// athlete ever sees is one the grammar is guaranteed to read perfectly.
    /// The blank slate. An athlete with history gets their own repeats first — logging the same
    /// gym session or the same evening loop is most of what manual logging IS, and retyping it
    /// every time was the whole cost. Examples fill the rest (and stand alone on day one), because
    /// they're also what teaches the grammar.
    private var examples: some View {
        let repeats = repeatChips
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if !repeats.isEmpty {
                Text("Log it again")
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                ForEach(repeats, id: \.self) { exampleChip($0) }
            }
            Text(repeats.isEmpty ? "Try one" : "Or say anything")
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.top, repeats.isEmpty ? 0 : Theme.Space.sm)
            ForEach(Array(Self.teachingExamples.prefix(repeats.isEmpty ? 3 : 1)), id: \.self) { exampleChip($0) }
        }
        .padding(.top, Theme.Space.xs)
    }

    private static let teachingExamples = [
        "Ran 5 easy miles this morning",
        "Bench pressed 185 for 10 with 5 sets",
        "45 min lift, then ran 4 miles at 9:23 pace",
    ]

    /// The athlete's recent sessions as sentences this parser reads perfectly (`repeatPhrase`) —
    /// the most recent of each SPORT, newest first. One per sport, not per phrase: deduping on the
    /// wording alone offered "Ran 4.5 miles in 35 minutes" directly above "…in 40 minutes", which
    /// spends the whole list on one workout the athlete can retype in three characters anyway.
    private var repeatChips: [String] {
        var seen = Set<WorkoutType>()
        var out: [String] = []
        for workout in recentWorkouts {
            guard !seen.contains(workout.type),
                  let phrase = WorkoutLogParser.repeatPhrase(
                    type: workout.type, durationS: workout.durationS,
                    distanceM: workout.gps?.distanceM ?? 0, distanceUnit: distanceUnit) else { continue }
            seen.insert(workout.type)
            out.append(phrase)
            if out.count == 3 { break }
        }
        return out
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

    // MARK: Receipt cards — one per workout; tap a card to adjust that workout in the full form

    private var receipts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // Keyed by the card's own index, not its position: removing one must not renumber the
            // rest under SwiftUI (their edits and duration picks are filed under those keys).
            ForEach(cards, id: \.index) { card in
                receiptCard(card)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(reduceMotion ? nil : Motion.standard, value: dismissedCards)
    }

    /// Names the review step out loud — the receipt is editable before it logs, which a card that
    /// only looks tappable doesn't make obvious on its own.
    private var editHint: some View {
        Label("Tap a card to fix any detail before you log", systemImage: "hand.tap")
            .font(.rounded(Theme.FontSize.caption, weight: .medium))
            .foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Theme.Space.xxs)
    }

    /// Removing a card is one tap, so putting it back has to be one too — otherwise the only way
    /// back from a mis-tap is retyping the sentence.
    private var undoRemovedLine: some View {
        let n = dismissedCards.count
        return Button {
            Haptics.light()
            withAnimation(reduceMotion ? nil : Motion.standard) { dismissedCards = [] }
        } label: {
            Label("\(n) workout\(n == 1 ? "" : "s") removed · Undo", systemImage: "arrow.uturn.backward")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The honesty line: a sport named without any numbers is deliberately left off the receipt
    /// (a bare mention must never mint a card), but it can't just vanish — "45 min upper body then
    /// went for a run" logged the lift and dropped the run without a word.
    private var unloggedLine: some View {
        let names = unloggedMentions.map { $0.title.lowercased() }
        let list = ListFormatter.localizedString(byJoining: names)
        return Label("Heard \(list) too — say how long and it gets its own card",
                     systemImage: "plus.circle")
            .font(.rounded(Theme.FontSize.caption, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The card is a tappable surface rather than a `Button` so the controls INSIDE it (the quick
    /// duration chips, the Edit pill) can be real buttons — nested buttons never receive their own
    /// taps. Tapping anywhere else still opens the editor, and VoiceOver reads the receipt line by
    /// line instead of collapsing the whole thing into one label it can't inspect.
    private func receiptCard(_ card: Card) -> some View {
        let index = card.index
        let r = card.result
        return VStack(alignment: .leading, spacing: 0) {
            sportRow(card)
                .padding(.bottom, Theme.Space.sm)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                .padding(.bottom, Theme.Space.sm)

            VStack(spacing: 10) {
                metricRow("Duration", r.durationS.map { Formatters.duration(s: $0) })
                if r.type?.tracksDistance ?? false {
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

            // The one gap worth closing in place. Everything else routes to the editor; a missing
            // duration is so common (and so cheap to answer) that it gets answered right here.
            // The row stays put once tapped — keyed on what the WORDS said, not on the filled card
            // — so a mis-tapped 20m can be corrected to 45m instead of vanishing on contact.
            if needsDurationChips(card) {
                QuickDurationRow(selected: durationPicks[index]) { picked in
                    if voice.isRecording { voice.stop() }   // a live mic would rewrite the sentence under them
                    durationPicks[index] = picked
                }
                .padding(.top, Theme.Space.md)
            }

            if let hint = missingHint(r) {
                Text(hint)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, Theme.Space.sm)
            }

            if let credit = creditSession(card) {
                creditLine(credit, for: card)
                    .padding(.top, Theme.Space.md)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { openEditor(card) }
    }

    /// Whether this card offers the one-tap durations: it has a sport, the sentence never said how
    /// long, and the athlete hasn't taken the card into the full editor (where they own every field).
    private func needsDurationChips(_ card: Card) -> Bool {
        guard card.result.type != nil, cardEdits[card.index] == nil else { return false }
        let list = mergedList
        guard card.index < list.count else { return false }
        return (list[card.index].durationS ?? 0) <= 0
    }

    /// Open the full form on this card. Editing freezes the words: a mic still streaming would
    /// rewrite the draft (and wipe card edits) while the athlete is inside the form.
    private func openEditor(_ card: Card) {
        Haptics.light()
        if voice.isRecording { voice.stop() }
        editingCard = EditingCard(id: card.index, prefill: prefill(for: card))
    }

    /// Take a card off the receipt. Offered only while more than one stands: with a single card
    /// "remove it" is just Cancel, and keeping the control off the common case keeps the receipt
    /// calm — it also means the list can never be emptied, so there's always something to log.
    private func dismissCard(_ card: Card) {
        Haptics.light()
        if voice.isRecording { voice.stop() }
        withAnimation(reduceMotion ? nil : Motion.standard) {
            _ = dismissedCards.insert(card.index)
        }
    }

    /// What the card's editor opens holding — the card as it currently reads.
    private func prefill(for card: Card) -> LogWorkoutPrefill {
        let r = card.result
        return LogWorkoutPrefill(
            type: r.type ?? .run,
            date: card.date,
            // 0, not a friendly 45 minutes: the editor must open holding what the athlete actually
            // said. Pre-filling a duration nobody uttered meant a Save tap could file three
            // quarters of an hour of work that never happened — and the form's own Save stays
            // disabled at 0, so the gap is impossible to miss (its chip row fills it in one tap).
            durationS: r.durationS ?? 0,
            distanceM: r.distanceM ?? 0,
            indoor: r.indoor,
            effort: r.effort,
            exercises: r.exercises.map { .init(name: $0.name, sets: $0.sets, reps: $0.reps, weightKg: $0.weightKg) })
    }

    private func sportRow(_ card: Card) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: card.result.type?.systemImage ?? "questionmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.background))
            VStack(alignment: .leading, spacing: 1) {
                Text(card.result.type?.title ?? "Choose a sport")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(whenLine(card.date))
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            // A real pill AND a real button — it looked tappable but was decoration inside the
            // card's own button, so VoiceOver had no way to reach the editor at all.
            Button { openEditor(card) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .bold))
                    Text("Edit").font(.rounded(Theme.FontSize.caption, weight: .bold))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.background))
                .overlay(Capsule().stroke(Theme.hairline))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Adjust this \(card.result.type?.title.lowercased() ?? "workout")")
            // Only while several cards stand: one sentence can split into a workout the athlete
            // never meant, and rewriting the text was the only way to get rid of it.
            if cards.count > 1 {
                Button { dismissCard(card) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this \(card.result.type?.title.lowercased() ?? "workout") from the receipt")
            }
        }
    }

    private func whenLine(_ date: Date) -> String {
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
        if r.type == nil { return "Which sport? Tap the card to set it." }
        if r.durationS == nil { return "How long was it? Say “45 minutes”, or tap to fill it in." }
        if r.type?.tracksDistance ?? false, (r.distanceM ?? 0) <= 0 { return "Add the distance if you know it — say “5 miles”, or tap Edit." }
        return nil
    }

    /// The plan line wears the iridescent check — logging this IS today's progress.
    private func creditLine(_ session: PlannedSession, for card: Card) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .frame(width: 18, height: 18)
                .background(Circle().fill(LinearGradient(colors: Theme.iridescent,
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text("Checks off \(creditDayWord(session, cardDate: card.date)) planned \(sessionLabel(session))")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func creditDayWord(_ session: PlannedSession, cardDate: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(session.date, inSameDayAs: cardDate) {
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

    /// What's standing between this receipt and a logged workout, in the order save checks. A
    /// greyed-out button with the reason buried in a card the athlete may have scrolled past is a
    /// dead end — the button itself now says the missing word.
    private var blockingHint: String? {
        guard !isEmptyParse else { return nil }
        if cards.contains(where: { $0.result.type == nil }) { return "Pick a sport to log it" }
        if cards.contains(where: { ($0.result.durationS ?? 0) <= 0 }) { return "Add how long to log it" }
        return nil
    }

    private var confirmBar: some View {
        VStack(spacing: Theme.Space.sm) {
            OversizedButton(title: blockingHint
                            ?? (cards.count > 1 ? "Log \(cards.count) workouts" : "Log workout"),
                            systemImage: canSave ? "checkmark" : nil) { save() }
                .opacity(canSave ? 1 : 0.35)
                .disabled(!canSave)
            // The manual path for a blank slate — with cards on screen, tapping a card IS the
            // adjust flow, so no second button competes with it.
            if isEmptyParse {
                Button {
                    adjust()
                } label: {
                    Text("Log it manually")
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
        let cards = cards
        // `!celebrating` = the one-save latch: the beat overlay covers the button a frame later,
        // but a touch already in flight could re-enter (audit 2026-08-11).
        guard canSave, !cards.isEmpty, !celebrating else { return }
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
            let r = card.result
            guard let type = r.type, let dur = r.durationS else {
                // `canSave` should have caught this, but an early return that leaves rows inserted
                // hands the next unrelated `context.save()` anywhere in the app a phantom workout
                // to commit. Undo the partial batch before bailing.
                workouts.forEach { context.delete($0) }
                return
            }
            let inputs = r.exercises.map { ex in
                LogWorkoutBuilder.ExerciseInput(
                    name: ex.name,
                    sets: Array(repeating: LogWorkoutBuilder.SetInput(reps: ex.reps, weightKg: ex.weightKg),
                                count: ex.sets))
            }
            let w = LogWorkoutBuilder.make(type: type, date: card.date, durationS: dur,
                                           distanceM: r.distanceM ?? 0, indoor: r.indoor,
                                           effort: r.effort, note: "",
                                           exercises: inputs, resolveExercise: cachedRef)
            w.calories = CalorieEstimator.kcal(for: w, bodyMassKg: profiles.first?.bodyMassKg)
            // A logged workout is a post like any tracked one: it takes the athlete's default
            // visibility (their own last explicit choice). Community builds only — solo stays private.
            if CommunityAccess.enabled, let p = profiles.first {
                w.privacy = SocialPrivacy.defaultVisibility(p)
            }
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
            // A logged workout is a real workout — so it earns records, reaches Apple Health, and
            // counts in the funnel exactly like a tracked one. It did none of that: log your
            // longest-ever run by hand and the record book never heard about it (the history
            // backfill is one-shot behind a version flag, so nothing rescued it later) and Health
            // never saw it either.
            RecordsBook.record(w, in: context)
            services.analytics.log(.workoutCompleted(type: w.type.rawValue))
            if w.durationS >= 60 || (w.gps?.distanceM ?? 0) > 0 {
                let saved = w
                Task { await services.health.save(saved) }
            }
        }
        AppReview.recordWorkoutSaved()   // a kept workout, same as a tracked save
        AwardsBook.syncSoon()
        // Crown it: the completion beat draws over the composer, then dismisses. (It fires its own
        // celebration haptic, so no success tick here.) Drop the keyboard first so nothing slides
        // out from under the overlay mid-beat.
        composing = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { celebrating = true }
    }

    private func exerciseRef(named name: String) -> Exercise {
        // Shorthand-aware: "bench press"/"squats" find the library rows instead of minting
        // duplicate customs beside them.
        if let found = ExerciseNameMatch.find(name, in: library) { return found }
        let e = Exercise()
        e.name = name
        e.isCustom = true
        context.insert(e)
        return e
    }

    /// The empty-state manual path: sheet-swap to the full form in normal save mode.
    private func adjust() {
        let prefill = LogWorkoutPrefill(type: .run, date: Date(), durationS: 45 * 60, distanceM: 0,
                                        indoor: false, effort: nil, exercises: [])
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
