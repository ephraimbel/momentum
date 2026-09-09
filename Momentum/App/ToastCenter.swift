import SwiftUI
import Observation
import SwiftData
import UserNotifications

/// A transient, glanceable confirmation — the receipt-capsule grammar ("Marathon logged · 26.2 mi")
/// promoted from WorkoutRunner's one-off into the app's single toast voice (enterprise pass
/// 2026-08-15). Toasts *confirm*; they never ask. Anything needing a decision goes through coach
/// cards or sheets, and the durable record always lives in the bell inbox — a missed toast loses
/// nothing.
struct AppToast: Identifiable, Equatable {
    /// Where a tap lands. `.none` just dismisses.
    enum Route: Equatable {
        case none
        case tab(AppTab)
        /// Progress, landed on a segment (the raw display word, e.g. "Health").
        case progressSegment(String)
        /// Any notification destination (notification pass 2026-09-06): the same route a push or
        /// an inbox row carries, so a coaching toast opens the exact session it is about.
        case deepLink(NotificationRoute)
    }

    let id: UUID
    var icon: String
    var line: String
    var route: Route
    var notificationID: UUID?

    init(icon: String, line: String, route: Route = .none, notificationID: UUID? = nil) {
        id = UUID()
        self.icon = icon
        self.line = line
        self.route = route
        self.notificationID = notificationID
    }
}

/// The queue: one capsule at a time, arrival order, identical lines deduped (re-running the same
/// coaching decision must not stutter the capsule). Full-screen covers `hold` promotion — a toast
/// must never play invisibly under a cover and expire unseen; it waits for the screen instead.
@MainActor @Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var current: AppToast?
    @ObservationIgnored private var queue: [AppToast] = []
    @ObservationIgnored private var holders: Set<String> = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored var nextCoachingToast: (() -> AppToast?)?
    @ObservationIgnored private var coachingRequested = false
    @ObservationIgnored private var coachingWake: Task<Void, Never>?

    func requestCoaching(delay: Double = 1.2) {
        coachingRequested = true
        coachingWake?.cancel()
        coachingWake = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.coachingWake = nil
            self?.promoteIfIdle()
        }
    }

    func cancelCoaching() {
        coachingWake?.cancel(); coachingWake = nil; coachingRequested = false
        if current?.notificationID != nil { dismissCurrent() }
    }

    /// How long a toast holds the screen (WorkoutRunner's receipt timing — kept app-wide).
    static let dwell: Double = 3.2

    private static var coachingDwell: Double {
#if DEBUG
        // The gesture test must dismiss explicitly, not accidentally pass via the timer.
        // Simulator accessibility queries can consume the entire normal five-second dwell.
        if ProcessInfo.processInfo.arguments.contains("--coach-dismiss-demo") { return 60 }
#endif
        return 5
    }

    /// Enqueue a toast. `delay` lets a caller land it after a moment that's still animating;
    /// `front` puts it ahead of anything waiting (the save receipt leads the coaching line).
    func show(icon: String, line: String, route: AppToast.Route = .none,
              delay: Double = 0, front: Bool = false, notificationID: UUID? = nil) {
        guard delay > 0 else { enqueue(AppToast(icon: icon, line: line, route: route, notificationID: notificationID), front: front); return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.enqueue(AppToast(icon: icon, line: line, route: route, notificationID: notificationID), front: front)
        }
    }

    /// Pause promotion while `token`'s cover owns the screen; `release` resumes and drains.
    func hold(_ token: String) { holders.insert(token) }
    func release(_ token: String) {
        holders.remove(token)
        promoteIfIdle(afterGap: true)
    }

    /// A tap (or a test) ends the current toast immediately; the next follows after the exit.
    func dismissCurrent() {
        pump?.cancel()
        pump = nil
        withAnimation(.easeIn(duration: 0.2)) { current = nil }
        promoteIfIdle(afterGap: true)
    }

    private func enqueue(_ toast: AppToast, front: Bool) {
        guard current?.line != toast.line,
              !queue.contains(where: { $0.line == toast.line }) else { return }
        if front { queue.insert(toast, at: 0) } else { queue.append(toast) }
        promoteIfIdle()
    }

    private func promoteIfIdle(afterGap: Bool = false) {
        guard pump == nil, current == nil, holders.isEmpty, (!queue.isEmpty || (coachingRequested && coachingWake == nil)) else { return }
        pump = Task { @MainActor [weak self] in
            if afterGap { try? await Task.sleep(for: .seconds(0.35)) }
            guard let self, !Task.isCancelled else { return }
            guard self.current == nil, self.holders.isEmpty else {
                self.pump = nil
                return
            }
            let next: AppToast?
            if !self.queue.isEmpty { next = self.queue.removeFirst() }
            else if self.coachingRequested && self.coachingWake == nil {
                self.coachingRequested = false
                next = self.nextCoachingToast?()
            } else { next = nil }
            guard let next else { self.pump = nil; return }
            withAnimation(.easeOut(duration: 0.3)) { self.current = next }
            try? await Task.sleep(for: .seconds(next.notificationID == nil ? Self.dwell : Self.coachingDwell))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { self.current = nil }
            self.pump = nil
            self.promoteIfIdle(afterGap: true)
        }
    }
}

/// The capsule at the root — attached once in `RootView`, over the tab shell. Surface fill,
/// hairline stroke, the icon carrying the claim: identical to the "Logged" receipt this design
/// standardizes, so every confirmation in the app speaks with one voice.
struct ToastHost: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    private var center: ToastCenter { .shared }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if scenePhase == .active, let toast = center.current {
                capsule(toast)
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            if scenePhase != .active { center.hold("app-inactive") }
            CoachSurface.configure(in: context)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                CoachSurface.configure(in: context)
                center.release("app-inactive")
            } else {
                center.hold("app-inactive")
                if phase == .background { CoachSurface.backgrounded() }
            }
        }
    }

    private func record(_ toast: AppToast, opened: Bool) {
        guard let id = toast.notificationID else { return }
        if opened {
            CoachMessageLifecycle.record(id, action: .opened, in: context, source: "toast")
        } else if !CoachSurface.displayed(id, in: context) {
            center.dismissCurrent()
        }
    }

    private func capsule(_ toast: AppToast) -> some View {
        HStack(spacing: 7) {
            Image(systemName: toast.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(toast.line)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(toast.notificationID == nil ? 1 : 2).minimumScaleFactor(0.85)
            if toast.route != .none {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            if toast.notificationID != nil {
                Button { dismiss(toast) } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Dismiss coaching message")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .raised(Capsule())
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
        .onAppear { record(toast, opened: false) }
        .onTapGesture { record(toast, opened: true); act(on: toast) }
        .accessibilityAction(named: "Dismiss") { dismiss(toast) }
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -20 || abs(value.translation.width) > 40 { dismiss(toast) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.line)
        .accessibilityAddTraits(toast.route == .none ? .isStaticText : .isButton)
        .accessibilityIdentifier("app-toast")
    }

    private func dismiss(_ toast: AppToast) {
        if let id = toast.notificationID {
            CoachMessageLifecycle.record(id, action: .dismissed, in: context, source: "toast")
        }
        center.dismissCurrent()
    }

    /// A tapped toast lands somewhere useful — recovery decisions open the Health hub (the "why"
    /// lives there), plan reshapes open the Plan board (the sessions carry their rationale).
    private func act(on toast: AppToast) {
        switch toast.route {
        case .none:
            break
        case .tab(let tab):
            router.pendingTab = tab
        case .progressSegment(let segment):
            router.pendingTab = .progress
            router.pendingProgressSegment = segment
        case .deepLink(let route):
            router.pendingNotificationRoute = route
        }
        center.dismissCurrent()
    }
}
