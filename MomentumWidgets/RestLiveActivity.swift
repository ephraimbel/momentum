import WidgetKit
import SwiftUI
import ActivityKit

/// The widget bundle for the `MomentumWidgets` extension. Today it hosts just the rest-timer Live
/// Activity; home-screen widgets can join here later.
@main
struct MomentumWidgetsBundle: WidgetBundle {
    var body: some Widget { RestLiveActivity() }
}

/// The strength rest-timer Live Activity — a glanceable countdown on the lock screen and in the
/// Dynamic Island, so you can rest with the phone down and not miss the next set. The countdown is
/// native (`Text(timerInterval:)`), so it animates without the app pushing per-second updates.
struct RestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            lockScreen(context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Rest", systemImage: "timer")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context).font(.title2.weight(.bold).monospacedDigit())
                        .frame(maxWidth: 64, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.exerciseName)
                        .font(.headline).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill")
            } compactTrailing: {
                countdown(context).monospacedDigit().frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }

    /// Lock-screen / banner presentation — clean and monochrome, exercise + sets on the left, the
    /// big countdown on the right.
    private func lockScreen(_ context: ActivityViewContext<RestActivityAttributes>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("REST").font(.caption2.weight(.bold)).tracking(1.6).foregroundStyle(.secondary)
                Text(context.attributes.exerciseName)
                    .font(.headline).lineLimit(1)
                Text("\(context.state.setsDone) sets done")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 12)
            countdown(context)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func countdown(_ context: ActivityViewContext<RestActivityAttributes>) -> some View {
        Text(timerInterval: context.state.startedAt...context.state.endsAt,
             countsDown: true, showsHours: false)
            .multilineTextAlignment(.trailing)
    }
}
