import WidgetKit
import SwiftUI
import ActivityKit

/// The live-cardio Live Activity — a glanceable readout of an in-progress run, ride, or walk on the
/// lock screen and in the Dynamic Island (PRD §23). The elapsed clock ticks natively
/// (`Text(timerInterval:)`) so it animates without per-second pushes; when paused it shows the
/// frozen, pre-formatted elapsed instead. Monochrome by design — the only color is a thin route-tinted
/// goal bar (the earned-progress accent).
struct CardioLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CardioActivityAttributes.self) { context in
            lockScreen(context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.title, systemImage: context.attributes.symbol)
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    clock(context).font(.title2.weight(.bold).monospacedDigit())
                        .frame(maxWidth: 92, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        metric(context.state.distanceText, "Distance")
                        Spacer()
                        if context.state.paused {
                            Label("Paused", systemImage: "pause.fill")
                                .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        metric(context.state.paceText, context.state.paceLabel)
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbol)
            } compactTrailing: {
                clock(context).monospacedDigit().frame(maxWidth: 54)
            } minimal: {
                Image(systemName: context.attributes.symbol)
            }
        }
    }

    /// Lock-screen / banner presentation — discipline + distance on the left, the big clock on the
    /// right, a thin goal bar underneath when a goal is set.
    private func lockScreen(_ context: ActivityViewContext<CardioActivityAttributes>) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(context.attributes.title.uppercased(), systemImage: context.attributes.symbol)
                        .font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        valueLabel(context.state.distanceText, "Distance")
                        valueLabel(context.state.paceText, context.state.paceLabel)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 0) {
                    if context.state.paused {
                        Text("PAUSED").font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                    }
                    clock(context)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
            if let fraction = context.state.goalFraction {
                ProgressView(value: fraction)
                    .tint(Color(red: 0.62, green: 0.55, blue: 0.95))   // route accent — earned progress
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// The elapsed clock: native count-up while running, frozen pre-formatted text when paused.
    @ViewBuilder
    private func clock(_ context: ActivityViewContext<CardioActivityAttributes>) -> some View {
        if context.state.paused {
            Text(context.state.elapsedText)
        } else {
            Text(timerInterval: context.state.timerStart...context.state.timerStart.addingTimeInterval(86_400),
                 countsDown: false, showsHours: true)
                .multilineTextAlignment(.trailing)
        }
    }

    private func valueLabel(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.headline.monospacedDigit())
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit())
            Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
        }
    }
}
