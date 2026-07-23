import SwiftUI
import WatchKit

/// On-wrist live cardio (PRD §4.10), rebuilt on the patterns the best wrist trainers share:
/// a **3-2-1 countdown** with per-tick haptics (Apple Workout / Strava), then a crown-scrollable
/// vertical pager of session pages — **Metrics · Zones · Map · Controls** (Apple's watchOS 10
/// Workout idiom, with Garmin/COROS's zone gauge and auto-lap splits) — and a celebratory
/// **summary** when the workout ends (Runna's finish moment). Numbers come from
/// `WatchCardioModel`; the clock ticks via `TimelineView`. Real HR/distance/GPS need a physical
/// Watch — on the sim use `--watch-demo` for a synthetic session.
struct WatchCardioView: View {
    let type: WorkoutType
    @Environment(\.dismiss) private var dismiss
    @State private var model: WatchCardioModel?
    @State private var phase: SessionPhase = .countdown
    @State private var page: LivePage = .metrics
    @State private var ending = false

    var body: some View {
        Group {
            switch phase {
            case .countdown:
                CountdownView { phase = .starting }
            case .starting:
                ProgressView()
                    .task {
                        // Publish the model before the (possibly long) start so teardown on
                        // disappear always has something to end — no orphan sessions.
                        let m = WatchCardioModel(type: type)
                        model = m
                        await m.start()
                        guard !Task.isCancelled else { return }
                        phase = .live
                    }
            case .live:
                if let model {
                    if model.failed { unavailable } else { live(model) }
                }
            case .summary:
                if let model {
                    WatchSummaryView(model: model) { dismiss() }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)   // Apple Workout style: the session owns the screen
        .onAppear(perform: applyLaunchPage)
        .onDisappear {
            // Safety net for every exit that isn't the End button (failure Close, any pop):
            // end() is idempotent, so the normal Done path makes this a no-op.
            let m = model
            Task { await m?.end() }
        }
    }

    // MARK: Live pager — crown/swipe between session pages, Metrics first

    private func live(_ model: WatchCardioModel) -> some View {
        TabView(selection: $page) {
            MetricsPage(model: model).tag(LivePage.metrics)
            ZonesPage(model: model).tag(LivePage.zones)
            MapPage(model: model).tag(LivePage.map)
            ControlsPage(model: model, onEnd: endWorkout).tag(LivePage.controls)
        }
        .tabViewStyle(.verticalPage)
        .disabled(ending)   // finishWorkout() can take a beat — no taps into a closing session
    }

    private func endWorkout() {
        guard !ending, let model else { return }
        ending = true
        Task {
            await model.end()
            WKInterfaceDevice.current().play(.success)
            withAnimation(.smooth(duration: 0.4)) { phase = .summary }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 6) {
            Image(systemName: "heart.slash").font(.title2).foregroundStyle(WatchTheme.inkSecondary)
            Text("Health access needed").font(.headline).multilineTextAlignment(.center)
            Text("Allow workout access to track on your wrist.")
                .font(.caption2).foregroundStyle(WatchTheme.inkSecondary).multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 4)
        }
    }

    /// DEBUG: `--watch-page=metrics|zones|map|controls` skips the countdown and opens that page —
    /// deterministic screenshots on the sim (taps/crown are unreliable there).
    private func applyLaunchPage() {
        #if DEBUG
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--watch-page=") })
        else { return }
        let raw = String(arg.dropFirst("--watch-page=".count))
        if raw == "summary" {
            let m = WatchCardioModel(type: type)
            m.seedDemoSummary()
            model = m
            phase = .summary
            return
        }
        guard let target = LivePage(rawValue: raw) else { return }
        page = target
        if phase == .countdown { phase = .starting }
        #endif
    }
}

enum SessionPhase { case countdown, starting, live, summary }

enum LivePage: String, Hashable { case metrics, zones, map, controls }

// MARK: - Countdown (Apple Workout / Strava): 3 · 2 · 1 with a haptic per tick, GO in iridescence

private struct CountdownView: View {
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count = 3
    @State private var ringProgress = 0.0
    @State private var landed = false

    var body: some View {
        ZStack {
            WatchTheme.bg.ignoresSafeArea()
            Circle()
                .stroke(WatchTheme.surface, lineWidth: 6)
                .padding(14)
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(WatchTheme.iridescentAngular, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(14)
            Group {
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 86, weight: .black, design: .rounded)).monospacedDigit()
                        .foregroundStyle(WatchTheme.ink)
                } else {
                    Text("GO")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .foregroundStyle(WatchTheme.iridescent)
                }
            }
            .id(count)
            .scaleEffect(landed || reduceMotion ? 1 : 1.35)
            .opacity(landed ? 1 : 0)
            // The morning's number sees the athlete off — the whole story in one chip.
            if let r = WatchSyncStore.shared.todayReadiness {
                VStack {
                    Spacer()
                    Text("\(bandWord(r.band).uppercased()) · \(r.score)")
                        .font(.system(size: 11, weight: .bold)).tracking(0.8).monospacedDigit()
                        .foregroundStyle(WatchTheme.inkSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(WatchTheme.surface))
                        .padding(.bottom, 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDone)   // impatient? tap to start now
        .task(run)
    }

    @Sendable private func run() async {
        for n in stride(from: 3, through: 0, by: -1) {
            count = n
            landed = false
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { landed = true }
            WKInterfaceDevice.current().play(n > 0 ? .directionUp : .start)
            // The ring FILLS toward GO — the start moment lands on a complete iridescent circle.
            withAnimation(.linear(duration: n > 0 ? 0.95 : 0.3)) {
                ringProgress = n > 0 ? Double(4 - n) / 3 : 1
            }
            try? await Task.sleep(for: .seconds(n > 0 ? 1.0 : 0.55))
            if Task.isCancelled { return }
        }
        onDone()
    }
}
