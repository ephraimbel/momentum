import SwiftUI
import CoreLocation
import UIKit

/// Cached static route images for feed posts. Every route post used to spin up a LIVE Mapbox
/// render engine (style download + tile fetch + layer build) inside a scrolling feed — several
/// engines at once is why Community took seconds to populate and stuttered on scroll. Each post's
/// map now renders ONCE per (post, style, appearance) via the shared `RouteSnapshotter`, is cached
/// for the app's lifetime, and scrolls as a plain image.
@MainActor
enum FeedRouteSnapshots {
    private static var cache: [String: UIImage] = [:]
    private static var waiters: [String: [CheckedContinuation<UIImage?, Never>]] = [:]
    private static var inFlight: Set<String> = []

    /// At most this many live render engines at once — a fast scroll through the feed otherwise
    /// bursts dozens of style/tile fetches and rate-limits the whole page into silhouettes.
    private static let maxConcurrentRenders = 4
    private static var active = 0

    static func image(post: UUID, coordinates: [CLLocationCoordinate2D],
                      style: MapStyleOption, scheme: ColorScheme, size: CGSize,
                      urgent: Bool = false) async -> UIImage? {
        let key = "\(post.uuidString)|\(style.rawValue)|\(scheme == .dark ? "d" : "l")"
        if let hit = cache[key] { return hit }
        return await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
            guard !inFlight.contains(key) else { return }   // join the in-flight render
            inFlight.insert(key)
            Task {
                // The reading view's hero map is the ONE the athlete is actively looking at — it
                // must not queue behind a cold-launch backlog (feed cells + the snapshot healer can
                // hold the gate for minutes on a fresh install, which read as "the post is broken").
                if !urgent {
                    while active >= maxConcurrentRenders { try? await Task.sleep(for: .milliseconds(120)) }
                }
                active += 1
                let data = await RouteSnapshotter.snapshot(coordinates: coordinates, size: size,
                                                           styleURI: style.styleURI(for: scheme))
                active -= 1
                let image = data.flatMap(UIImage.init(data:))
                if let image { cache[key] = image }
                (waiters.removeValue(forKey: key) ?? []).forEach { $0.resume(returning: image) }
                inFlight.remove(key)
            }
        }
    }
}

/// The feed post's route media: an instant route-silhouette placeholder, crossfading to the cached
/// map snapshot when it lands. Never a live map engine.
struct FeedRouteMap: View {
    let item: FeedItem
    var height: CGFloat = 200
    /// True in the post reading view: its map takes the render fast lane and never gives up while
    /// on screen (a feed cell politely queues and stops after a few tries).
    var urgent = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    var body: some View {
        // The media is an OVERLAY of a fixed-size clear box, so the image can never participate in
        // layout: a `scaledToFill` image reports its scaled (oversized) width up the tree, which made
        // the reading view's whole column wider than the screen the instant the map landed — every
        // header/stat shifted half off-screen (user report 2026-07-15). The box is the layout; the
        // image just paints inside it and clips.
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Theme.surface)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                } else if let coords = item.routeCoordinates, coords.count > 1 {
                    // The route's shape, instantly — the page never looks stalled while tiles land.
                    RouteSilhouette(coords: coords)
                        .stroke(Theme.route.opacity(0.7),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .padding(Theme.Space.xl)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: "\(item.id)-\(colorScheme == .dark)") {
            #if DEBUG
            // UI tests keep the instant silhouette: XCUITest's accessibility snapshot realizes
            // EVERY lazy feed row at once, and a hundred queued Mapbox render engines starve the
            // main thread until queries time out. Real scrolling only ever realizes a handful.
            if ProcessInfo.processInfo.arguments.contains("--ui-test-social") { return }
            #endif
            guard let coords = item.routeCoordinates, coords.count > 1 else { return }
            // Failed renders retry with backoff — a transient tile hiccup must not leave the card
            // a silhouette for the rest of the session. The urgent (reading-view) map retries for
            // as long as it's on screen: giving up after 3 while a cold-launch backlog drained left
            // the post's hero permanently blank (user report 2026-07-15).
            var attempt = 0
            while !Task.isCancelled, urgent || attempt < 3 {
                if let rendered = await FeedRouteSnapshots.image(
                    post: item.id, coordinates: coords, style: item.mapStyle, scheme: colorScheme,
                    size: CGSize(width: 420, height: height + 40), urgent: urgent) {
                    image = rendered
                    return
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(Double(attempt) * 2, 6)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // the post card carries the description
    }
}
