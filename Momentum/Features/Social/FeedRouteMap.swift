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
    /// **Bounded, least-recently-used** (2026-08-29 responsiveness pass). This was a plain
    /// dictionary that only ever grew. A wall tile is rendered at `pixelRatio 2`, so 300×400 pt is
    /// a 600×800 bitmap — 1.9 MB once drawn — and a full-bleed pager page is 6.4 MB. Browsing a
    /// few hundred route posts therefore held hundreds of megabytes of pixels that nothing could
    /// ever release: the app would be jetsammed before the athlete got bored of scrolling.
    ///
    /// An explicit LRU rather than `NSCache` on purpose. `NSCache`'s limits are documented as
    /// advisory, so nothing could be *pinned* by a test, and under pressure it can drop the whole
    /// cache including the tiles currently on screen. This evicts the oldest first, keeps an exact
    /// byte budget, and purges deliberately on a real memory warning.
    private static var cache: [String: UIImage] = [:]
    /// When each key was last read, as a monotonic tick. A read is the hottest thing here — every
    /// realized tile does a SYNCHRONOUS lookup on its first body pass — so recency has to be O(1)
    /// to record. This used to be a `[String]` in touch order, and `touch` scanned it with
    /// `lastIndex(of:)`: up to 160 string comparisons per tile per body pass, tens of thousands of
    /// them per scroll. Eviction pays the linear scan instead, and eviction happens once per
    /// admitted image at worst (2026-08-29).
    private static var used: [String: Int] = [:]
    private static var tick = 0
    private static var bytes = 0
    /// ~40 wall tiles or ~12 full-bleed pages resident at once — several screenfuls in both
    /// directions, which is as far back as a scroll ever snaps.
    static let byteBudget = 80 * 1_048_576
    static let entryBudget = 160

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
        // The appearance pairing every other map in the app makes: the two DEFAULT styles
        // (Realistic, Light) fall back to Dark at night, and a deliberately-picked style renders as
        // chosen. `styleURI(for:)` ignores its scheme argument — the scheme was already in the cache
        // key here, so the wall re-rendered per appearance and got the identical light basemap back:
        // a dark-mode community wall was a mosaic of glaring white maps (the same bug the History
        // map card had, 2026-08-28). `uriStyle(for:)` is the accessor that actually pairs.
        let key = cacheKey(post: post, style: style, scheme: scheme, size: size,
                           routeWidth: routeWidth, endpointDiameter: endpointDiameter, insets: insets)
        let resolved = style.uriStyle(for: scheme)
        #if DEBUG
        if cache[key] != nil { hits += 1 } else { misses += 1 }
        #endif
        if let hit = touch(key) { return hit }
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
                                                           styleURI: resolved.styleURI,
                                                           insets: insets,
                                                           routeWidth: routeWidth,
                                                           endpointDiameter: endpointDiameter)
                active -= 1
                let image = data.flatMap(UIImage.init(data:))
                if let image {
                    store(image, key: key)
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

    /// The image for this exact (post, style, appearance, size, stroke) **if it is already in
    /// hand** — no `await`, no suspension.
    ///
    /// Why this exists: `LazyVGrid` throws a cell's `@State` away when it scrolls off, so coming
    /// back to a tile whose snapshot rendered minutes ago restarted at `snapshot == nil`. Even
    /// with a warm cache the read went through an `async` hop, so the tile drew a grey silhouette
    /// for one frame and then crossfaded the map in — a visible pop-in on every scroll-back, on a
    /// wall the athlete scrolls up and down constantly. A view can read this synchronously in its
    /// first `body` pass and draw the finished map on frame one.
    static func cachedImage(post: UUID, style: MapStyleOption, scheme: ColorScheme, size: CGSize,
                            routeWidth: CGFloat = 3, endpointDiameter: CGFloat? = nil,
                            insets: UIEdgeInsets = UIEdgeInsets(top: 26, left: 26, bottom: 26, right: 26)) -> UIImage? {
        touch(cacheKey(post: post, style: style, scheme: scheme, size: size,
                       routeWidth: routeWidth, endpointDiameter: endpointDiameter, insets: insets))
    }

    /// The one place the key is built, so `image` and `cachedImage` can never drift apart —
    /// a mismatched key would silently mean "always a miss", i.e. re-render every appearance.
    ///
    /// `size` is part of it because the profile COVER renders the same post wide and short (the
    /// whole run in a 2:1 band) while the grid renders it 3:4; without it, whichever landed first
    /// was served to both. `routeWidth` likewise (a small tile wants a proportionally thicker
    /// trace), and `endpointDiameter` because grids carry no start/finish marks and full views do.
    /// The style is the RESOLVED one: the two default styles (Realistic, Light) pair to Dark at
    /// night the way every other map in the app does.
    private static func cacheKey(post: UUID, style: MapStyleOption, scheme: ColorScheme,
                                 size: CGSize, routeWidth: CGFloat, endpointDiameter: CGFloat?,
                                 insets: UIEdgeInsets) -> String {
        let resolved = style.uriStyle(for: scheme)
        return "\(post.uuidString)|\(resolved.rawValue)|\(scheme == .dark ? "d" : "l")|w\(Int(routeWidth * 10))|e\(endpointDiameter.map { Int($0) } ?? 0)|s\(Int(size.width))x\(Int(size.height))|i\(Int(insets.top))-\(Int(insets.left))-\(Int(insets.bottom))-\(Int(insets.right))"
    }

    /// A read that also records recency — the LRU half of the cache.
    private static func touch(_ key: String) -> UIImage? {
        guard let hit = cache[key] else { return nil }
        tick &+= 1
        used[key] = tick
        return hit
    }

    /// Cost is the DECODED bitmap, not the PNG: `RouteSnapshotter` renders at `pixelRatio 2`, so
    /// a 300×400 request is a 600×800 image and 1.9 MB of pixels once drawn. Costing it by data
    /// length would have let the cache hold ten times its budget.
    private static func store(_ image: UIImage, key: String) {
        observeMemoryWarningsIfNeeded()
        guard cache[key] == nil else { _ = touch(key); return }
        cache[key] = image
        tick &+= 1
        used[key] = tick
        bytes += decodedBytes(image)
        while (bytes > byteBudget || cache.count > entryBudget), cache.count > 1 {
            guard let stalest = used.min(by: { $0.value < $1.value })?.key else { break }
            used[stalest] = nil
            if let gone = cache.removeValue(forKey: stalest) { bytes -= decodedBytes(gone) }
        }
    }

    private static func decodedBytes(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    /// How many images are resident — never above `entryBudget`, whatever the browse depth.
    static var residentCount: Int { cache.count }
    /// Their decoded footprint in bytes — never above `byteBudget` beyond the one entry the cache
    /// always keeps (a single image larger than the whole budget is still better held than
    /// re-rendered on every frame).
    static var residentBytes: Int { bytes }

    /// Registered on the first admitted image rather than at launch, so a session that never
    /// opens a social surface never installs it.
    private static var observingMemory = false
    private static func observeMemoryWarningsIfNeeded() {
        guard !observingMemory else { return }
        observingMemory = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { purge() }
            }
    }

    /// A real memory warning: drop everything but do NOT tear down the tiles on screen — they
    /// re-request on their next `body` pass and re-render, which is the right trade when the
    /// system is asking. Wired by the app; safe to call at any time.
    static func purge() {
        cache.removeAll()
        used.removeAll()
        bytes = 0
    }

    #if DEBUG
    private static var hits = 0
    private static var misses = 0
    /// Live cache stats for the perf pass.
    static func perfLine() -> String {
        String(format: "SNAPCACHE resident=%d hits=%d misses=%d decoded=%.1fMB",
               cache.count, hits, misses, Double(bytes) / 1_048_576)
    }
    /// Test hook — a fresh cache so a hit-rate assertion isn't reading another suite's leftovers.
    static func resetForTesting() {
        purge()
        hits = 0
        misses = 0
    }
    /// Test hook — admit an image the way a finished render would, so the cache's hit/eviction
    /// behaviour is pinnable without spinning up Mapbox in a unit test.
    static func storeForTesting(_ image: UIImage, post: UUID, style: MapStyleOption,
                                scheme: ColorScheme, size: CGSize, routeWidth: CGFloat = 3,
                                endpointDiameter: CGFloat? = nil,
                                insets: UIEdgeInsets = UIEdgeInsets(top: 26, left: 26, bottom: 26, right: 26)) {
        store(image, key: cacheKey(post: post, style: style, scheme: scheme, size: size,
                                   routeWidth: routeWidth, endpointDiameter: endpointDiameter,
                                   insets: insets))
    }
    static var hitCount: Int { hits }
    static var missCount: Int { misses }
    #endif
}


// (The `FeedRouteMap` view deleted 2026-07-30 — only the dormant card-feed used it.
// `FeedRouteSnapshots` above stays: the wall, pager, and athlete grids all render through it.)
