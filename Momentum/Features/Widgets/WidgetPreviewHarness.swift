#if DEBUG
import SwiftUI
import SwiftData

/// `--widget-preview`: renders the Home Screen widget's every state at true widget sizes inside
/// the app, so the design can be screenshot-verified on the simulator (the widget gallery can't be
/// driven by simctl). The live card uses the exact snapshot `WidgetBridge` would publish from the
/// seeded data; the canned cards pin the done / rest / fresh-install states.
struct WidgetPreviewHarness: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var live: WidgetSnapshot?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                row("LIVE — from seeded data") {
                    card(live, .small)
                }
                card(live, .medium)
                row("DONE") { card(doneSample, .small) }
                card(doneSample, .medium)
                row("REST DAY") { card(restSample, .small) }
                row("FRESH INSTALL") { card(nil, .small) }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.90))
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }.padding()
        }
        .onAppear {
            let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
            let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
            live = WidgetBridge.build(profile: profile, workouts: workouts)
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    /// True widget metrics: small 158×158, medium 338×158, 16pt content padding, container corners.
    private func card(_ snapshot: WidgetSnapshot?, _ layout: TodayWidgetContent.Layout) -> some View {
        TodayWidgetContent(snapshot: snapshot, layout: layout)
            .padding(16)
            .frame(width: layout == .small ? 158 : 338, height: 158)
            .background(WidgetInk.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }

    private var doneSample: WidgetSnapshot {
        var s = WidgetSnapshot.preview
        s.sessionDone = true
        s.streak = 4
        s.week = s.week.map { day in
            var d = day
            if d.isToday { d.state = .done }
            return d
        }
        return s
    }

    private var restSample: WidgetSnapshot {
        var s = WidgetSnapshot.preview
        s.sessionTitle = nil
        s.sessionHero = nil
        s.sessionDetail = nil
        s.sessionDone = false
        s.week = s.week.map { day in
            var d = day
            if d.isToday { d.state = .rest }
            return d
        }
        return s
    }
}
#endif
