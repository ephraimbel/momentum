import WidgetKit
import SwiftUI

/// momentum on the watch face — the complication set. Two widgets, one voice:
///
///  · **Readiness** (circular · corner · inline): the morning's one honest number as a ring.
///    Ink on every ordinary day; the ring renders iridescent ONLY at Primed — the earned-accent
///    rule, visible from the wrist raise.
///  · **Today** (rectangular — the Smart Stack card): today's planned session, straight from the
///    plan the phone synced. No plan → a quiet brand line, never a fake prescription.
///
/// Data arrives via the app-group defaults the watch app writes when a WatchConnectivity context
/// lands (`WatchSyncStore`); the app reloads timelines on every push, so the face tracks the
/// phone within moments. This extension reads ONLY the defaults — no sessions, no HealthKit.
@main
struct MomentumWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        ReadinessComplication()
        TodaySessionComplication()
    }
}

// MARK: - Shared data (app-group defaults; keys written by WatchSyncStore)

struct WatchFaceData {
    static let appGroup = "group.com.ephraimbel.momentum.app"

    var readinessScore: Int?
    var readinessBand: String
    var sessionTitle: String?
    var sessionDetail: String?

    static func load(now: Date = Date()) -> WatchFaceData {
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        let today = f.string(from: now)

        var data = WatchFaceData(readinessScore: nil, readinessBand: "",
                                 sessionTitle: nil, sessionDetail: nil)
        // Same-day values only — yesterday's readiness on the face would be a quiet lie.
        if d.string(forKey: "sync.readiness.dayKey") == today,
           let score = d.object(forKey: "sync.readiness.score") as? Int {
            data.readinessScore = score
            data.readinessBand = d.string(forKey: "sync.readiness.band") ?? ""
        }
        if d.string(forKey: "sync.session.dayKey") == today {
            data.sessionTitle = d.string(forKey: "sync.session.title")
            data.sessionDetail = d.string(forKey: "sync.session.detail")
        }
        return data
    }

    static let placeholder = WatchFaceData(readinessScore: 87, readinessBand: "primed",
                                           sessionTitle: "Long run", sessionDetail: "6 mi · ~11:56 /mi")
}

struct FaceEntry: TimelineEntry {
    let date: Date
    let data: WatchFaceData
}

struct FaceProvider: TimelineProvider {
    func placeholder(in context: Context) -> FaceEntry {
        FaceEntry(date: .now, data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FaceEntry) -> Void) {
        completion(FaceEntry(date: .now, data: context.isPreview ? .placeholder : .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FaceEntry>) -> Void) {
        // One entry now, one just past local midnight (stale readiness must clear itself even if
        // no push arrives overnight); the watch app reloads timelines on every synced context.
        let now = Date()
        var entries = [FaceEntry(date: now, data: .load())]
        let cal = Calendar.current
        if let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) {
            entries.append(FaceEntry(date: midnight.addingTimeInterval(60),
                                     data: .load(now: midnight.addingTimeInterval(60))))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 30))))
    }
}

// MARK: - Watch-face palette (self-contained — extensions don't share app target sources)

private enum FaceInk {
    static let ink = Color.white
    static let dim = Color.white.opacity(0.55)
    static let track = Color.white.opacity(0.16)
    static let accent = Color(red: 0.72, green: 0.75, blue: 1.0)
    static var iridescent: AngularGradient {
        AngularGradient(colors: [
            Color(red: 0.72, green: 0.75, blue: 1.0),
            Color(red: 0.80, green: 0.70, blue: 1.0),
            Color(red: 0.78, green: 0.94, blue: 0.88),
            Color(red: 0.72, green: 0.75, blue: 1.0),
        ], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
    }
}

// MARK: - Readiness (circular · corner · inline)

struct ReadinessComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "momentum.readiness", provider: FaceProvider()) { entry in
            ReadinessFaceView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Readiness")
        .description("Today's readiness — the ring goes iridescent when you're primed.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

struct ReadinessFaceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FaceEntry

    private var score: Int? { entry.data.readinessScore }
    private var primed: Bool { entry.data.readinessBand == "primed" }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let score {
                Text("Readiness \(score) · \(entry.data.readinessBand.capitalized)")
            } else {
                Text("momentum")
            }
        case .accessoryCorner:
            cornerView
        default:
            circularView
        }
    }

    private var circularView: some View {
        ZStack {
            Circle().stroke(FaceInk.track, lineWidth: 4.5)
            if let score {
                Circle()
                    .trim(from: 0, to: max(0.02, Double(score) / 100))
                    .stroke(primed ? AnyShapeStyle(FaceInk.iridescent) : AnyShapeStyle(FaceInk.ink),
                            style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(FaceInk.ink)
            } else {
                Image(systemName: "figure.run")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FaceInk.dim)
            }
        }
        .accessibilityLabel("Readiness")
        .accessibilityValue(score.map { "\($0) out of 100" } ?? "Not available")
    }

    private var cornerView: some View {
        Text(score.map(String.init) ?? "—")
            .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(FaceInk.ink)
            .widgetCurvesContent()
            .widgetLabel {
                if let score {
                    Gauge(value: Double(score), in: 0...100) { Text("Readiness") }
                        .tint(primed ? Gradient(colors: [
                            Color(red: 0.72, green: 0.75, blue: 1.0),
                            Color(red: 0.78, green: 0.94, blue: 0.88),
                        ]) : Gradient(colors: [.white.opacity(0.85), .white]))
                } else {
                    Text("momentum")
                }
            }
    }
}

// MARK: - Today's session (rectangular — the Smart Stack card)

struct TodaySessionComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "momentum.today", provider: FaceProvider()) { entry in
            TodaySessionFaceView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Today's Plan")
        .description("What your plan asks of you today.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct TodaySessionFaceView: View {
    let entry: FaceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title = entry.data.sessionTitle {
                Text("TODAY'S PLAN")
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(FaceInk.accent)
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(FaceInk.ink)
                if let detail = entry.data.sessionDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(FaceInk.dim)
                }
            } else if let score = entry.data.readinessScore {
                Text("READINESS")
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(FaceInk.accent)
                Text("\(score) · \(entry.data.readinessBand.capitalized)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(FaceInk.ink)
                Text("Open momentum to start")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FaceInk.dim)
            } else {
                Text("momentum")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(FaceInk.ink)
                Text("keep moving.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FaceInk.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
