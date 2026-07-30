import SwiftUI
import SwiftData

/// The AI coach chat (PRD §4.7). A calm, on-brand conversation: the coach speaks from the left with
/// a small iridescent orb, the athlete from the right; suggested prompts when fresh; a typing beat
/// while it replies. The thread persists across launches (`ChatMessage`); replies are grounded in
/// the athlete's real data via `CoachResponder`.
struct CoachChatView: View {
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(PaywallController.self) private var paywall
    @Environment(CoachPresenter.self) private var presenter
    @Environment(Services.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \ChatMessage.createdAt, order: .forward) private var messages: [ChatMessage]
    // Live memory notes so the memory card updates the instant one is forgotten.
    @Query private var allNotes: [MemoryNote]
    @State private var vm: CoachChatViewModel?
    @State private var showCapabilities = false
    @State private var confirmClear = false
    @State private var nearBottom = true
    @FocusState private var inputFocused: Bool
    // Dictation (the shared premium-voice stack — same experience as the log + fuel composers):
    // words stream into the field live, the mic meters the actual voice, review then send.
    @State private var voice = VoiceTranscriber()
    @State private var voiceBase = ""

    /// Active notes, pinned first, capped for the card.
    private var activeNotes: [(id: UUID, text: String, pinned: Bool)] {
        let active = allNotes.filter(\.isActive)
        return (active.filter(\.pinned) + active.filter { !$0.pinned })
            .prefix(10).map { ($0.id, $0.text, $0.pinned) }
    }

    /// Before the athlete has said anything, show a centered welcome rather than a lone greeting bubble.
    private var isFresh: Bool { !messages.contains { $0.role == .user } }

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    if isFresh {
                        welcomeHero(vm)
                    } else {
                        transcript(vm)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The composer is bottom chrome, not content: it hugs the screen edge (glass runs under
            // the home indicator — no dead gap), the transcript scrolls beneath it, and the keyboard
            // pushes it up as one piece.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let vm { footer(vm) }
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)   // immersive — the chat owns the screen
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onClose() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: Theme.Space.xs) {
                        BrandMark(size: 22)
                        Text("Coach").font(.rounded(Theme.FontSize.body, weight: .bold))
                            .foregroundStyle(Theme.ink)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: Theme.Space.xs) {
                        Button { showCapabilities = true } label: { Image(systemName: "info.circle") }
                            .accessibilityLabel("What your coach can do")
                        Button { confirmClear = true } label: { Image(systemName: "arrow.counterclockwise") }
                            .disabled(isFresh)
                            .accessibilityLabel("Clear conversation")
                    }
                }
            }
            .sheet(isPresented: $showCapabilities) { CoachCapabilitiesSheet() }
            // The coach itself is a fullScreenCover — RootView's app-level paywall cover cannot
            // present on top of it (same limitation CardioSaveView documents), so the "paywall on
            // send" gate needs its own host here or a free athlete's Send does nothing at all.
            .fullScreenCover(item: Binding(
                get: { paywall.presentedFeature },
                set: { paywall.presentedFeature = $0 })) { feature in
                PaywallView(feature: feature)
            }
            // Clearing wipes the whole thread — receipts, undo snapshots, everything. Confirm first.
            .confirmationDialog("Clear this conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear everything", role: .destructive) { vm?.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your coach's memory of you is kept — only the messages go.")
            }
        }
        // Build the view model SYNCHRONOUSLY on appear (not in the async .task below): the first
        // paint needs it, and a .task-created vm leaves the body rendering Color.clear until the task
        // runs — a visible blank flash when the chat opens (worst on a cold-launch/deep-link open).
        .onAppear {
            if vm == nil { vm = CoachChatViewModel(context: context, health: services.health) }
        }
        .task {
            if vm == nil { vm = CoachChatViewModel(context: context, health: services.health) }
            // Contextual entry ("ask about this workout") pre-types the input and pins the workout
            // the debrief should ground in; the athlete still sends.
            if let workoutID = presenter.consumeContextWorkout() { vm?.focusWorkoutID = workoutID }
            if let prefill = presenter.consumePrefill(), vm?.input.isEmpty == true {
                vm?.input = prefill
            }
            // The chat's primary act is typing, so the composer focuses on open once the cover's
            // transition settles (focusing mid-presentation drops the focus on the floor) — EXCEPT
            // on a fresh thread (2026-07-30): the keyboard buried the landing's starter card on
            // first contact, exactly the moment it should be read. The glowing field is the
            // invitation to type; one tap accepts it.
            if !isFresh {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { inputFocused = true }
            }
            #if DEBUG
            // --coach-typing: land mid-keystroke (focused field + draft text) so the composer's
            // typing glow can be screenshot-verified deterministically.
            if ProcessInfo.processInfo.arguments.contains("--coach-typing") {
                vm?.input = "Can I move my long run to Sunday?"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { inputFocused = true }
            }
            // --coach-info: open the capabilities sheet; the rest auto-send a message so each card
            // (explainer, week recap, memory, remember) can be screenshot-verified deterministically.
            if ProcessInfo.processInfo.arguments.contains("--coach-info") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showCapabilities = true }
            }
            let autoSends: [(flag: String, text: String)] = [
                ("--coach-explain", "Why is my plan built this way?"),
                ("--coach-week", "How was my week?"),
                ("--coach-remember", "Remember that I hate treadmills"),
                ("--coach-memory", "What do you know about me?"),
                ("--coach-predict", "What could I race right now?"),
                ("--coach-zones", "What are my zones?"),
                ("--coach-today", "Brief me on today"),
                ("--coach-adjust", "Change my plan"),                 // the adjust menu card
                ("--coach-race", "I want to run a marathon"),         // race flow: inline date picker
                ("--coach-goal", "Change my goal"),                   // goal picker card
            ]
            for send in autoSends where ProcessInfo.processInfo.arguments.contains(send.flag) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { vm?.send(send.text) }
            }
            // --coach-ask <question>: auto-send any question — verifies every offline Q&A branch
            // (schedule, fueling, readiness, feasibility, knowledge) without a bespoke flag each.
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--coach-ask"),
               ProcessInfo.processInfo.arguments.indices.contains(i + 1) {
                let question = ProcessInfo.processInfo.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { vm?.send(question) }
            }
            #endif
        }
    }

    /// A calm, premium landing the first time in (redesigned 2026-07-30): a personal two-line
    /// greeting in the upper third — the coach proves it knows the athlete and today's session —
    /// and the starters docked above the composer as ONE hairline-separated card (the house row
    /// grammar; the old centered capsule stack was the app's last 2024-era surface). Scrollable
    /// with a viewport-tracking min height: when the keyboard rises the hero compresses by
    /// SCROLLING instead of shoving the composer under the keyboard.
    private func welcomeHero(_ vm: CoachChatViewModel) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: Theme.Space.xl)
                    VStack(spacing: Theme.Space.lg) {
                        BrandMark(size: 72)
                        VStack(spacing: Theme.Space.xs) {
                            Text(vm.heroTitle)
                                .font(.display(28, weight: .black))
                                .foregroundStyle(Theme.ink)
                            Text(vm.heroSubline)
                                .font(.rounded(Theme.FontSize.body, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        starterList(vm)
                            .padding(.top, Theme.Space.lg)
                    }
                    Spacer(minLength: Theme.Space.xl)
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// The conversation starters as individual quiet pills (owner calls 2026-07-30: one big card
    /// read too heavy, bare lines too little — each question wears its OWN soft capsule): tiny
    /// glyph + question on a surface capsule with a hairline, centered. The capability disclosure
    /// closes the column one register quieter, bare by design.
    private func starterList(_ vm: CoachChatViewModel) -> some View {
        VStack(spacing: Theme.Space.sm + 2) {
            ForEach(vm.suggestions, id: \.self) { s in
                Button { attemptSend(vm, s) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: Self.starterGlyph(s))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                        Text(s)
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().stroke(Theme.hairline))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Button { showCapabilities = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("What your coach can do")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold))
                }
                .foregroundStyle(Theme.inkTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.xs)
        }
        .multilineTextAlignment(.center)
    }

    /// One glyph per known starter — `computeSuggestions` mints from a fixed set, so this map is
    /// exhaustive today; the bubble is the safe default for any future addition.
    private static func starterGlyph(_ s: String) -> String {
        switch s {
        case "Brief me on today": "sun.max"
        case "How did my last workout go?": "figure.run"
        case "How should I run my race?": "flag.checkered"
        case "How's my recovery looking?": "waveform.path.ecg"
        case "What should I eat before my long run?": "fork.knife"
        case "What could I race right now?": "stopwatch"
        case "How am I doing?": "chart.line.uptrend.xyaxis"
        case "Why is my plan built this way?": "calendar"
        case "How was my week?": "chart.bar"
        default: "bubble.left"
        }
    }

    private func transcript(_ vm: CoachChatViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        // Quiet day separators — a proactive seed from Monday shouldn't read as "just now".
                        if index == 0 || !Calendar.current.isDate(msg.createdAt, inSameDayAs: messages[index - 1].createdAt) {
                            dayDivider(msg.createdAt)
                        }
                        bubble(msg)
                            .id(msg.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if vm.isResponding && !vm.isStreamingReply {
                        typingIndicator
                            .id("typing")
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                    }
                    if messages.count <= 1 { suggestionChips(vm).padding(.top, Theme.Space.sm) }
                    // Follow-ups: the conversation offers its own next question.
                    if messages.count > 1, !vm.followUps(last: messages.last).isEmpty, !vm.isResponding {
                        followUpChips(vm)
                            .id("followups")
                            .transition(.opacity)
                    }
                }
                .padding(Theme.Space.lg)
                // New turns land with one calm entrance; the thinking beat fades in and out.
                .animation(reduceMotion ? nil : Motion.standard, value: messages.count)
                .animation(reduceMotion ? nil : Motion.standard, value: vm.isResponding)
            }
            .defaultScrollAnchor(.bottom)   // a chat opens at the newest turn, not the top
            .scrollDismissesKeyboard(.interactively)
            // A quiet way back down when reading history (chat-app standard).
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 160
            } action: { _, atBottom in
                nearBottom = atBottom
            }
            .overlay(alignment: .bottomTrailing) {
                if !nearBottom {
                    Button {
                        Haptics.light()
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36)
                            .momentumGlass(in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, Theme.Space.md)
                    .padding(.bottom, Theme.Space.sm)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .accessibilityLabel("Jump to latest message")
                }
            }
            .animation(reduceMotion ? nil : Motion.standard, value: nearBottom)
            // Respect the reader's place: force the jump only when they're already at the bottom
            // or the new message is their own send — completing a reply while they've scrolled up
            // to re-read must not yank them back down (the streaming handler below already
            // honors `nearBottom`; these two were the yank).
            .onChange(of: messages.count) {
                if nearBottom || messages.last?.role == .user { scrollToEnd(proxy, vm) }
            }
            .onChange(of: vm.isResponding) {
                if nearBottom { scrollToEnd(proxy, vm) }
            }
            .onChange(of: inputFocused) { _, focused in if focused { scrollToEnd(proxy, vm) } }
            // Streaming: follow the reply as it grows (unanimated — deltas land many times a second).
            .onChange(of: messages.last?.text) {
                if let last = messages.last, last.role == .coach, nearBottom {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// Small trailing chips under the latest reply — tap to keep the thread moving.
    private func followUpChips(_ vm: CoachChatViewModel) -> some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(vm.followUps(last: messages.last), id: \.self) { text in
                Button { attemptSend(vm, text) } label: {
                    Text(text)
                        .font(.rounded(Theme.FontSize.label, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, Theme.Space.sm).padding(.vertical, 7)
                        .background(Capsule().stroke(Theme.hairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 34)   // aligned with the coach bubble, past the avatar column
    }

    /// "Today" / "Yesterday" / "Monday, Jul 6" — centered, whisper-quiet.
    private func dayDivider(_ date: Date) -> some View {
        let label: String = Calendar.current.isDateInToday(date) ? "Today"
            : Calendar.current.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return Text(label)
            .font(.rounded(Theme.FontSize.label, weight: .semibold))
            .foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ vm: CoachChatViewModel) {
        withAnimation(.easeOut(duration: 0.25)) {
            if vm.isResponding { proxy.scrollTo("typing", anchor: .bottom) }
            else if !vm.followUps(last: messages.last).isEmpty { proxy.scrollTo("followups", anchor: .bottom) }
            else { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == .coach {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                BrandMark(size: 26)
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(msg.text)
                        .font(.rounded(Theme.FontSize.body, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Theme.Space.md)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
                        .contextMenu { copyButton(msg.text) }
                    if let vm, let payload = msg.card {
                        CoachCardView(
                            message: msg,
                            payload: payload,
                            previewLines: vm.previewLines(for: payload),
                            feasibility: vm.feasibilityPreview(for: payload),
                            sections: vm.sections(for: payload.kind),
                            memoryNotes: payload.kind == .memory ? activeNotes : [],
                            onApply: { vm.applyCard(on: msg, paywall: paywall, presenter: presenter) },
                            onDecline: { vm.declineCard(on: msg) },
                            onPickSeverity: { vm.completeInjuryCard(on: msg, severity: $0, paywall: paywall, presenter: presenter) },
                            // Slot pickers fill the card in place (free); Apply stays the Pro gate.
                            onFill: { vm.fillCard(on: msg, with: $0) },
                            // Menu rows send like typed messages — the same Pro-gated send path.
                            onSendOption: { attemptSend(vm, $0) },
                            onNavigate: { vm.applyCard(on: msg, paywall: paywall, presenter: presenter) },
                            onUndo: { vm.undoCard(on: msg) },
                            onForget: { vm.forgetNote(id: $0) })
                    }
                }
                Spacer(minLength: Theme.Space.xl)
            }
        } else {
            HStack {
                Spacer(minLength: Theme.Space.xl)
                Text(msg.text)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Space.md)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
                    .contextMenu { copyButton(msg.text) }
            }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button { UIPasteboard.general.string = text } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            BrandMark(size: 26)
            TypingDots()
                .padding(Theme.Space.md)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            Spacer(minLength: Theme.Space.xl)
        }
    }

    private func suggestionChips(_ vm: CoachChatViewModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ForEach(vm.suggestions, id: \.self) { s in
                Button { attemptSend(vm, s) } label: {
                    Text(s)
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
                        .background {
                            Capsule().fill(IridescentMaterial()).opacity(0.25)
                            Capsule().stroke(Theme.hairline)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Composer (bottom chrome — glass to the screen edge, no dead gap)

    private func footer(_ vm: CoachChatViewModel) -> some View {
        @Bindable var vm = vm
        let fieldShape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return VStack(spacing: Theme.Space.xs) {
            CoachDisclaimer(alignment: .center)
            HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                // The pill holds field + mic together (the fuel/log composer grammar) — while
                // dictating the field becomes a live transcript with the newest words in view.
                HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                    if voice.isRecording {
                        LiveTranscriptView(text: vm.input, placeholder: "Ask your coach…")
                            .padding(.vertical, 10)
                    } else {
                        TextField("Ask your coach…", text: $vm.input, axis: .vertical)
                            .font(.rounded(Theme.FontSize.body, weight: .medium))
                            .lineLimit(1...4)
                            .focused($inputFocused)
                            .padding(.vertical, 10)
                            .onSubmit { attemptSend(vm) }
                    }
                    if voice.isSupported {
                        micButton(vm)
                            .padding(.vertical, 5)
                    }
                }
                .padding(.horizontal, Theme.Space.md)
                .background(fieldShape.fill(Theme.surface))
                .overlay {
                    // The field wakes up under your fingers: hairline at rest, a soft iridescent
                    // ring while typing — and while dictating the ring breathes WITH the voice.
                    // Never self-pulsing; Reduce Motion keeps it static by design.
                    if glowActive {
                        // Leaf view: keeps the 45 Hz `voice.level` read out of the chat's body —
                        // the whole transcript re-rendered per audio buffer while dictating.
                        DictationGlowStroke(shape: fieldShape, voice: voice,
                                            restingOpacity: vm.input.isEmpty ? 0.65 : 1)
                    } else {
                        fieldShape.stroke(Theme.hairline)
                    }
                }
                .shadow(color: (Theme.iridescent.first ?? .clear).opacity(glowActive ? 0.35 : 0),
                        radius: glowActive ? 9 : 0, y: 2)
                .animation(Motion.reversible, value: glowActive)
                .animation(Motion.reversible, value: vm.input.isEmpty)
                .animation(Motion.standard, value: voice.isRecording)
                sendButton(vm)
            }
        }
        // Dictation streams into the same field as typing — everything downstream is identical.
        .onChange(of: voice.transcript) { _, spoken in
            guard !spoken.isEmpty else { return }
            vm.input = voiceBase.isEmpty ? spoken : voiceBase + " " + spoken
        }
        .alert("Microphone access needed", isPresented: Bindable(voice).showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Turn on Microphone and Speech Recognition for momentum to hear you.")
        }
        .onDisappear { if voice.isRecording { voice.stop() } }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.xs)
        .background {
            // No chrome slab: the composer sits on the chat's own canvas (the field is the only
            // visible element) — the ChatGPT read. Solid behind every footer element so nothing
            // bleeds through the disclaimer; the dissolve strip lives ABOVE the content, and the
            // color runs under the home indicator so there's never a seam.
            VStack(spacing: 0) {
                LinearGradient(colors: [Theme.background.opacity(0), Theme.background],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                Theme.background
            }
            .padding(.top, -24)
            // .container ONLY: run the color under the home indicator, but keep respecting the
            // KEYBOARD safe-area region — the default (.all) opts this subtree out of SwiftUI's
            // keyboard avoidance, which left the composer buried under the keyboard on device.
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    private var glowActive: Bool { inputFocused || !(vm?.input.isEmpty ?? true) || voice.isRecording }

    /// Tap to talk, tap to stop — the shared premium-dictation meter (level bars riding the
    /// athlete's actual voice) in the coach's pill.
    private func micButton(_ vm: CoachChatViewModel) -> some View {
        Button {
            if !voice.isRecording { voiceBase = vm.input.trimmingCharacters(in: .whitespacesAndNewlines) }
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
            .frame(width: 30, height: 30)
            .animation(Motion.standard, value: voice.isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate to your coach")
    }

    /// The coach is a Pro feature. Free athletes can OPEN it and read (greeting, capabilities, starter
    /// chips), but SENDING is the gate ("see it, paywall on send") — a free send opens the paywall
    /// instead of hitting the network or the offline responder. Every user-initiated send routes here.
    private func attemptSend(_ vm: CoachChatViewModel, _ text: String? = nil) {
        if voice.isRecording { voice.stop() }   // review's over — the send freezes the words
        voiceBase = ""
        guard paywall.isEntitled(to: .aiCoach) else { paywall.present(for: .aiCoach); return }
        vm.send(text)
    }

    private func sendButton(_ vm: CoachChatViewModel) -> some View {
        Button { attemptSend(vm) } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 40, height: 40)
                .background(Circle().fill(vm.canSend ? Theme.ink : Theme.inkTertiary))
                .scaleEffect(vm.canSend ? 1 : 0.92)
                .animation(reduceMotion ? nil : Motion.lively, value: vm.canSend)
        }
        .disabled(!vm.canSend)
        .accessibilityLabel("Send")
    }
}

/// Three dots riding a gentle wave — the coach is thinking. A real sine wave (each dot lifts and
/// brightens in sequence) rather than a synchronized pulse; Reduce Motion renders them static.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots { _ in (opacity: 0.6, lift: 0) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    dots { i in
                        // 1.2 s cycle, each dot trailing the last by a beat; only the crest lifts.
                        let wave = sin((t * 2 * .pi / 1.2) - Double(i) * 0.9)
                        return (opacity: 0.35 + 0.55 * (0.5 + 0.5 * wave),
                                lift: -2.5 * max(0, wave))
                    }
                }
            }
        }
        .accessibilityLabel("Coach is typing")
    }

    private func dots(_ style: @escaping (Int) -> (opacity: Double, lift: Double)) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                let s = style(i)
                Circle().fill(Theme.inkTertiary).frame(width: 7, height: 7)
                    .opacity(s.opacity)
                    .offset(y: s.lift)
            }
        }
    }
}
