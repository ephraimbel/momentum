import WidgetKit
import SwiftUI

/// The Home Screen widget: today's session, the streak, and the week ribbon — the plan at a glance,
/// in the brand's monochrome with iridescence only where it's earned. The app writes a
/// display-ready `WidgetSnapshot` into the shared App Group; this side just renders it and rolls
/// the timeline at midnight so yesterday's session never masquerades as today's.
struct TodayWidget: Widget {
    static let kind = "TodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TodayProvider()) { entry in
            TodayWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's session, your streak, and your week at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        // The gallery preview: real data when it exists, the branded sample otherwise.
        completion(TodayEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        var entries = [TodayEntry(date: now, snapshot: WidgetSnapshot.load())]
        // A second entry at midnight re-renders with the same snapshot, whose day-stamp check
        // then flips it to the neutral "open for today" state — stale sessions never linger.
        if let midnight = Calendar.current.date(byAdding: .day, value: 1,
                                                to: Calendar.current.startOfDay(for: now)) {
            entries.append(TodayEntry(date: midnight, snapshot: WidgetSnapshot.load()))
            completion(Timeline(entries: entries, policy: .after(midnight)))
        } else {
            completion(Timeline(entries: entries, policy: .atEnd))
        }
    }
}

private struct TodayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        TodayWidgetContent(snapshot: entry.snapshot,
                           layout: family == .systemMedium ? .medium : .small)
            .containerBackground(for: .widget) { WidgetInk.canvas }
            .widgetURL(URL(string: "momentum://today"))
    }
}
