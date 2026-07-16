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
            // The chat's primary act is typing: focus the composer on EVERY open, once the cover's
            // transition settles (focusing mid-presentation drops the focus on the floor). The
            // keyboard rises with the field already glowing above it — no extra tap to start talking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { inputFocused = true }
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

    /// A calm, premium landing the first time in — orb, a question, and starting prompts.
    /// Scrollable with a viewport-tracking min height: centered when there's room, and when the
    /// keyboard rises the fixed-height hero compresses by SCROLLING instead of shoving the composer
    /// under the keyboard (the transcript state gets this for free from its own ScrollView).
    private func welcomeHero(_ vm: CoachChatViewModel) -> some View {
        GeometryReader { geo in
            ScrollView {
                heroContent(vm)
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func heroContent(_ vm: CoachChatViewModel) -> some View {
        VStack(spacing: Theme.Space.lg) {
            BrandMark(size: 88)
            VStack(spacing: Theme.Space.sm) {
                Text("How can I help?")
                    .font(.display(28, weight: .black))
                    .foregroundStyle(Theme.ink)
                Text(messages.first?.text ?? "Ask me anything about your training.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Space.lg)
            VStack(spacing: Theme.Space.sm) {
                ForEach(vm.suggestions, id: \.self) { s in
                    Button { attemptSend(vm, s) } label: {
                        Text(s)
                            .font(.rounded(Theme.FontSize.caption, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
                            .background {
                                Capsule().fill(IridescentMaterial()).opacity(0.22)
                                Capsule().stroke(Theme.hairline)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            // The quiet disclosure — full capability surface + ground rules, one tap away.
            Button { showCapabilities = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.system(size: 11, weight: .semibold))
                    Text("What your coach can do")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold))
                }
                .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.xs)
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
                    if messages.count > 1, !vm.followUps.isEmpty, !vm.isResponding {
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
            .onChange(of: messages.count) { scrollToEnd(proxy, vm) }
            .onChange(of: vm.isResponding) { scrollToEnd(proxy, vm) }
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
            ForEach(vm.followUps, id: \.self) { text in
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
            else if !vm.followUps.isEmpty { proxy.scrollTo("followups", anchor: .bottom) }
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
                TextField("Ask your coach…", text: $vm.input, axis: .vertical)
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
                    .background(fieldShape.fill(Theme.surface))
                    .overlay {
                        // The field wakes up under your fingers: hairline at rest, a soft iridescent
                        // ring while typing. Static (no pulsing) — Reduce Motion safe by design.
                        if glowActive {
                            fieldShape
                                .stroke(LinearGradient(colors: Theme.iridescent,
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        lineWidth: 1.5)
                                .opacity(vm.input.isEmpty ? 0.65 : 1)
                        } else {
                            fieldShape.stroke(Theme.hairline)
                        }
                    }
                    .shadow(color: (Theme.iridescent.first ?? .clear).opacity(glowActive ? 0.35 : 0),
                            radius: glowActive ? 9 : 0, y: 2)
                    .animation(Motion.reversible, value: glowActive)
                    .animation(Motion.reversible, value: vm.input.isEmpty)
                    .onSubmit { attemptSend(vm) }
                sendButton(vm)
            }
        }
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

    private var glowActive: Bool { inputFocused || !(vm?.input.isEmpty ?? true) }

    /// The coach is a Pro feature. Free athletes can OPEN it and read (greeting, capabilities, starter
    /// chips), but SENDING is the gate ("see it, paywall on send") — a free send opens the paywall
    /// instead of hitting the network or the offline responder. Every user-initiated send routes here.
    private func attemptSend(_ vm: CoachChatViewModel, _ text: String? = nil) {
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
