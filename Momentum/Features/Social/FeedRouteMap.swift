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

    /// Circuit breaker (2026-07-29): on a cold Mapbox cache (fresh install) a whole burst of
    /// renders can fail together — and a wall of retrying tiles then spawns engine after engine
    /// until their event traffic starves the main thread (observed as the community grid frozen
    /// mid-entrance). After a run of consecutive failures the snapshotter goes quiet for a beat:
    /// callers get instant nils, their retry loops wind down, and the next wave tries against a
    /// warmer cache. Any success closes the breaker.
    private static var consecutiveFailures = 0
    private static var quietUntil: Date?

    /// `routeWidth` is per-surface (in the snapshot's point space): the default 3 reads ~2.6pt on a
    /// full-width feed/reading card — Strava-thin; the profile grid renders a smaller image into a
    /// smaller tile and passes a proportionally larger width. Part of the cache key: the same post
    /// rendered for two surfaces must not collide.
    static func image(post: UUID, coordinates: [CLLocationCoordinate2D],
                      style: MapStyleOption, scheme: ColorScheme, size: CGSize,
                      urgent: Bool = false, routeWidth: CGFloat = 3,
                      endpointDiameter: CGFloat? = nil,
                      insets: UIEdgeInsets = UIEdgeInsets(top: 26, left: 26, bottom: 26, right: 26)) async -> UIImage? {
        // nil = no start/finish marks, which is what a GRID tile wants (owner call 2026-07-30);
        // full views opt in. It's part of the cache key for the same reason `routeWidth` is: the
        // wall and the pager render the same post differently and must not share an image.
        // `size` is part of the key too: the profile COVER renders the same post wide and short
        // (the whole run in a 2:1 band) while the grid renders it 3:4. Without the size in the key
        // whichever landed first was served to both, and the cover got a portrait image to crop.
        let key = "\(post.uuidString)|\(style.rawValue)|\(scheme == .dark ? "d" : "l")|w\(Int(routeWidth * 10))|e\(endpointDiameter.map { Int($0) } ?? 0)|s\(Int(size.width))x\(Int(size.height))|i\(Int(insets.top))-\(Int(insets.left))-\(Int(insets.bottom))-\(Int(insets.right))"
        if let hit = cache[key] { return hit }
        if let quietUntil, Date() < quietUntil { return nil }   // breaker open — no new engines
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
                                                           styleURI: style.styleURI(for: scheme),
                                                           insets: insets,
                                                           routeWidth: routeWidth,
                                                           endpointDiameter: endpointDiameter)
                active -= 1
                let image = data.flatMap(UIImage.init(data:))
                if let image {
                    cache[key] = image
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    // 10 / 15s (was 6 / 30s): the tighter first cut also silenced sessions where
                    // renders were merely SLOW — a run of timeouts parked the whole wall on
                    // silhouettes for half a minute at a time. The breaker's job is only to stop
                    // an engine-spawn spiral, so trip late and recover fast.
                    if consecutiveFailures >= 10 {
                        quietUntil = Date().addingTimeInterval(15)
                        consecutiveFailures = 0
                    }
                }
                (waiters.removeValue(forKey: key) ?? []).forEach { $0.resume(returning: image) }
                inFlight.remove(key)
            }
        }
    }
}


// (The `FeedRouteMap` view deleted 2026-07-30 — only the dormant card-feed used it.
// `FeedRouteSnapshots` above stays: the wall, pager, and athlete grids all render through it.)
