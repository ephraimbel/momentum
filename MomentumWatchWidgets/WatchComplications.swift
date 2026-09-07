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
        SleepComplication()
    }
}

// MARK: - Shared data (app-group defaults; keys written by WatchSyncStore)

struct WatchFaceData {
    static let appGroup = "group.com.ephraimbel.momentum.app"

    var readinessScore: Int?
    var readinessBand: String
    var sessionTitle: String?
    var sessionDetail: String?
    /// From the phone-built health snapshot (2026-09-06), today's only.
    var sleepH: Double?
    var sleepNeedH: Double?
    var sleepBand: String?
    var hrv: Int?
    var hrvTrend: String?
    var restingHR: Int?
    var restingHRTrend: String?
    var strain: Int?
    var strainBand: String?

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
        if let raw = d.data(forKey: "sync.health.snapshot"),
           let snapshot = WristHealthSnapshot.decode(raw), snapshot.dayKey == today {
            if let s = snapshot.sleep { data.sleepH = s.asleepH; data.sleepNeedH = s.needH; data.sleepBand = s.band }
            data.hrv = snapshot.hrv.map { Int($0.value.rounded()) }
            data.hrvTrend = snapshot.hrv?.trend
            data.restingHR = snapshot.restingHR.map { Int($0.value.rounded()) }
            data.restingHRTrend = snapshot.restingHR?.trend
            data.strain = snapshot.strain?.score
            data.strainBand = snapshot.strain?.band
            // A face without the readiness-only keys still gets the ring from the snapshot.
            if data.readinessScore == nil, let r = snapshot.readiness {
                data.readinessScore = r.score
                data.readinessBand = r.band
            }
        }
        return data
    }

    static let placeholder = WatchFaceData(readinessScore: 87, readinessBand: "primed",
                                           sessionTitle: "Long run", sessionDetail: "6 mi · ~11:56 /mi",
                                           sleepH: 7.7, sleepNeedH: 7.5, sleepBand: "Good",
                                           hrv: 52, hrvTrend: "up", restingHR: 51, restingHRTrend: "steady",
                                           strain: 34, strainBand: "Light")
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

// MARK: - Sleep (2026-09-06) — last night on the face: the ring is hours against the athlete's
// own need, the rectangle adds HRV and resting heart rate against their norms.

struct SleepComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "momentum.sleep", provider: FaceProvider()) { entry in
            SleepFaceView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Sleep & Vitals")
        .description("Last night against your own need, with HRV and resting heart rate.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SleepFaceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FaceEntry

    private static let sleepTint = Color(red: 0.66, green: 0.70, blue: 1.0)
    private static let good = Color(red: 0.62, green: 0.90, blue: 0.78)
    private static let bad = Color(red: 1.0, green: 0.42, blue: 0.52)

    private var hours: String? { entry.data.sleepH.map(Self.clock) }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let hours {
                Text([("Sleep \(hours)"), entry.data.hrv.map { "HRV \($0)" }].compactMap { $0 }.joined(separator: " · "))
            } else {
                Text("momentum")
            }
        case .accessoryRectangular:
            rectangularView
        default:
            circularView
        }
    }

    private var circularView: some View {
        ZStack {
            Circle().stroke(FaceInk.track, lineWidth: 4.5)
            if let h = entry.data.sleepH, let need = entry.data.sleepNeedH, need > 0 {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, h / need)))
                    .stroke(Self.sleepTint, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Self.clock(h))
                    .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(FaceInk.ink)
                    .minimumScaleFactor(0.7)
            } else {
                Image(systemName: "moon.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FaceInk.dim)
            }
        }
        .accessibilityLabel("Sleep")
        .accessibilityValue(entry.data.sleepH.map { Self.spoken($0) } ?? "Not available")
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let h = entry.data.sleepH {
                Text("SLEEP")
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(Self.sleepTint)
                HStack(spacing: 4) {
                    Text(Self.spokenShort(h))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(FaceInk.ink)
                    if let band = entry.data.sleepBand {
                        Text("· \(band)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(FaceInk.dim)
                    }
                }
                HStack(spacing: 6) {
                    if let hrv = entry.data.hrv { vital("HRV \(hrv)", trend: entry.data.hrvTrend, higherIsBetter: true) }
                    if let rhr = entry.data.restingHR { vital("RHR \(rhr)", trend: entry.data.restingHRTrend, higherIsBetter: false) }
                }
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(FaceInk.dim)
            } else {
                Text("momentum")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(FaceInk.ink)
                Text("Last night arrives with your iPhone.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FaceInk.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func vital(_ text: String, trend: String?, higherIsBetter: Bool) -> some View {
        HStack(spacing: 1) {
            Text(text)
            if trend == "up" || trend == "down" {
                let good = (trend == "up") == higherIsBetter
                Image(systemName: trend == "up" ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(good ? Self.good : Self.bad)
            }
        }
    }

    private static func clock(_ h: Double) -> String {
        let total = Int((h * 60).rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
    private static func spokenShort(_ h: Double) -> String {
        let total = Int((h * 60).rounded())
        return "\(total / 60)h \(String(format: "%02d", total % 60))m"
    }
    private static func spoken(_ h: Double) -> String {
        let total = Int((h * 60).rounded())
        return "\(total / 60) hours \(total % 60) minutes"
    }
}
