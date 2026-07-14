import WidgetKit
import SwiftUI
import ActivityKit

/// The live-cardio Live Activity — a glanceable readout of an in-progress run, ride, or walk on the
/// lock screen and in the Dynamic Island (PRD §23). The elapsed clock ticks natively
/// (`Text(timerInterval:)`) so it animates without per-second pushes; when paused it shows the
/// frozen, pre-formatted elapsed instead.
///
/// Design: the card is the app's warm charcoal with white ink and the brand faces (Space Grotesk
/// numerals, Inter labels — bundled in this extension). The route so far draws as a small white
/// trace with a green start dot and violet tip; a guided run's current step replaces the discipline
/// label so the lock screen tracks the plan. The only color is earned: route dots + the thin goal bar.
struct CardioLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CardioActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Ink.canvas)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.stepText?.uppercased() ?? context.attributes.title.uppercased(),
                          systemImage: context.attributes.symbol)
                        .font(.custom("Inter-Bold", size: 11)).tracking(1.2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    clock(context)
                        .font(.custom("SpaceGrotesk-Bold", size: 22)).monospacedDigit()
                        .frame(maxWidth: 92, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .lastTextBaseline) {
                        metric(context.state.distanceText, "Distance")
                        Spacer()
                        if context.state.paused { chip("PAUSED") }
                        else if context.state.gpsLost { chip("GPS LOST") }
                        Spacer()
                        metric(context.state.paceText, context.state.paceLabel)
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbol)
            } compactTrailing: {
                clock(context)
                    .font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                    .frame(maxWidth: 54)
            } minimal: {
                Image(systemName: context.attributes.symbol)
            }
            .keylineTint(Ink.accent)
        }
    }

    /// The app's palette, hand-carried: the widget extension can't see `Theme`, and a Live Activity
    /// renders on the lock screen where the card must hold its own look in both system appearances.
    private enum Ink {
        static let canvas = Color(red: 30 / 255, green: 29 / 255, blue: 27 / 255)   // warm charcoal
        static let primary = Color.white
        static let secondary = Color.white.opacity(0.60)
        static let accent = Color(red: 0.62, green: 0.55, blue: 0.95)               // route violet
        static let start = Color(red: 0.20, green: 0.78, blue: 0.35)                // start-dot green
    }

    // MARK: Lock screen

    /// Discipline (or guided step) up top, the big native clock with distance/pace beneath, the
    /// route so far on the right, and a thin goal bar underneath when a goal is set.
    private func lockScreen(_ context: ActivityViewContext<CardioActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(context.state.stepText?.uppercased() ?? context.attributes.title.uppercased(),
                      systemImage: context.attributes.symbol)
                    .font(.custom("Inter-Bold", size: 11)).tracking(1.6)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if context.state.paused { chip("PAUSED") }
                else if context.state.gpsLost { chip("GPS LOST") }
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    clock(context)
                        .font(.custom("SpaceGrotesk-Bold", size: 36)).monospacedDigit()
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    HStack(alignment: .top, spacing: 22) {
                        lockMetric(context.state.distanceText, "Distance")
                        lockMetric(context.state.paceText, context.state.paceLabel)
                    }
                }
                Spacer(minLength: 0)
                if let route = context.state.route {
                    routeThumb(route)
                }
            }
            if let fraction = context.state.goalFraction {
                ProgressView(value: fraction)
                    .tint(Ink.accent)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// The route so far — the run's shape, not a map. White trace, green start, violet tip (the
    /// live-progress accent, same as in the app).
    private func routeThumb(_ route: [Double]) -> some View {
        Canvas { ctx, size in
            let inset = 5.0
            let points = stride(from: 0, to: route.count - 1, by: 2).map {
                CGPoint(x: inset + route[$0] * (size.width - 2 * inset),
                        y: inset + route[$0 + 1] * (size.height - 2 * inset))
            }
            guard points.count > 1, let first = points.first, let last = points.last else { return }
            var path = Path()
            path.addLines(points)
            ctx.stroke(path, with: .color(Ink.primary.opacity(0.92)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: first.x - 3, y: first.y - 3, width: 6, height: 6)),
                     with: .color(Ink.start))
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                     with: .color(Ink.accent))
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)   // decorative — the numbers carry the information
    }

    /// A quiet status chip ("PAUSED", "GPS LOST") — monochrome, never alarming (no-shame rule).
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.custom("Inter-Bold", size: 10)).tracking(1.2)
            .foregroundStyle(Ink.primary.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.12)))
            .lineLimit(1).fixedSize()
    }

    /// The elapsed clock: native count-up while running, frozen pre-formatted text when paused.
    @ViewBuilder
    private func clock(_ context: ActivityViewContext<CardioActivityAttributes>) -> some View {
        if context.state.paused {
            Text(context.state.elapsedText)
        } else {
            Text(timerInterval: context.state.timerStart...context.state.timerStart.addingTimeInterval(86_400),
                 countsDown: false, showsHours: true)
        }
    }

    /// A stacked value-over-label column. Both lines are single-line and fixed — the pair reads as
    /// one unit and can never wrap mid-word when the clock or route thumb squeezes the row.
    private func lockMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.custom("SpaceGrotesk-Medium", size: 17)).monospacedDigit()
                .foregroundStyle(Ink.primary)
                .lineLimit(1).fixedSize()
            Text(label.uppercased())
                .font(.custom("Inter-SemiBold", size: 10)).tracking(0.8)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1).fixedSize()
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.custom("SpaceGrotesk-Medium", size: 17)).monospacedDigit()
            Text(label.uppercased())
                .font(.custom("Inter-SemiBold", size: 10)).tracking(0.8)
                .foregroundStyle(.secondary)
        }
    }
}
