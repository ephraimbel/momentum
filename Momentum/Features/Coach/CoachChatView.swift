import SwiftUI
import SwiftData

/// The AI coach chat (PRD §4.7). A calm, on-brand conversation: the coach speaks from the left with
/// a small iridescent orb, the athlete from the right; suggested prompts when fresh; a typing beat
/// while it replies. Replies are grounded in the athlete's real data via `CoachResponder`.
struct CoachChatView: View {
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @State private var vm: CoachChatViewModel?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let vm {
                    transcript(vm)
                    inputBar(vm)
                } else {
                    Spacer()
                }
            }
            .background(Theme.background)
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { onClose() }.fontWeight(.semibold)
                }
            }
        }
        .task { if vm == nil { vm = CoachChatViewModel(context: context) } }
    }

    private func transcript(_ vm: CoachChatViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(vm.messages) { msg in
                        bubble(msg).id(msg.id)
                    }
                    if vm.isResponding { typingIndicator.id("typing") }
                    if vm.messages.count <= 1 { suggestionChips(vm).padding(.top, Theme.Space.sm) }
                }
                .padding(Theme.Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.messages.count) { scrollToEnd(proxy, vm) }
            .onChange(of: vm.isResponding) { scrollToEnd(proxy, vm) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ vm: CoachChatViewModel) {
        withAnimation(.easeOut(duration: 0.25)) {
            if vm.isResponding { proxy.scrollTo("typing", anchor: .bottom) }
            else { proxy.scrollTo(vm.messages.last?.id, anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: CoachChatViewModel.Message) -> some View {
        if msg.role == .coach {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                IridescentOrb(size: 26, glow: false)
                Text(msg.text)
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Space.md)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
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
            }
        }
    }

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            IridescentOrb(size: 26, glow: false)
            TypingDots()
                .padding(Theme.Space.md)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            Spacer(minLength: Theme.Space.xl)
        }
    }

    private func suggestionChips(_ vm: CoachChatViewModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ForEach(vm.suggestions, id: \.self) { s in
                Button { vm.send(s) } label: {
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

    private func inputBar(_ vm: CoachChatViewModel) -> some View {
        @Bindable var vm = vm
        return HStack(spacing: Theme.Space.sm) {
            TextField("Ask your coach…", text: $vm.input, axis: .vertical)
                .font(.rounded(Theme.FontSize.body, weight: .medium))
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.hairline))
                .onSubmit { vm.send() }
            Button { vm.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(vm.canSend ? Theme.ink : Theme.inkTertiary))
            }
            .disabled(!vm.canSend)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.ultraThinMaterial)
    }
}

/// Three softly pulsing dots — the coach is thinking.
private struct TypingDots: View {
    @State private var phase = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.inkTertiary).frame(width: 7, height: 7)
                    .opacity(reduceMotion ? 0.6 : (0.35 + 0.65 * pulse(i)))
            }
        }
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 1 } } }
        .accessibilityLabel("Coach is typing")
    }
    private func pulse(_ i: Int) -> Double {
        let shifted = (phase + Double(i) * 0.25).truncatingRemainder(dividingBy: 1)
        return 0.5 - 0.5 * cos(shifted * 2 * .pi)
    }
}
