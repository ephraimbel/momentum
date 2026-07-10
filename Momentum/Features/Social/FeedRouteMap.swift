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

    static func image(post: UUID, coordinates: [CLLocationCoordinate2D],
                      style: MapStyleOption, scheme: ColorScheme, size: CGSize) async -> UIImage? {
        let key = "\(post.uuidString)|\(style.rawValue)|\(scheme == .dark ? "d" : "l")"
        if let hit = cache[key] { return hit }
        return await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
            guard !inFlight.contains(key) else { return }   // join the in-flight render
            inFlight.insert(key)
            Task {
                let data = await RouteSnapshotter.snapshot(coordinates: coordinates, size: size,
                                                           styleURI: style.styleURI(for: scheme))
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

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.surface
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
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: "\(item.id)-\(colorScheme == .dark)") {
            guard let coords = item.routeCoordinates, coords.count > 1 else { return }
            image = await FeedRouteSnapshots.image(post: item.id, coordinates: coords,
                                                   style: item.mapStyle, scheme: colorScheme,
                                                   size: CGSize(width: 420, height: height + 40))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // the post card carries the description
    }
}
