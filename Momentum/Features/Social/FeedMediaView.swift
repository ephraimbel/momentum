import SwiftUI
import UIKit

/// The media block for a feed post — photo > muscle map > route map > timed-discipline card. Shared by
/// the editorial row and the reading view so they render identically. Always non-interactive (never
/// steals the feed's scroll).
struct FeedMediaView: View {
    let item: FeedItem
    /// Applied to photo and route media; the muscle/timed cards keep their natural heights.
    var height: CGFloat = 200

    @ViewBuilder
    var body: some View {
        if !item.photosData.isEmpty {
            // >1 photo pages horizontally — the pager needs hit testing, so a multi-photo block
            // swallows taps (swipe to browse); the surrounding card still opens from title/stats.
            PhotoCarousel(photosData: item.photosData, height: height)
        } else if item.type.isStrengthStyle, let muscles = item.muscles, !muscles.isEmpty {
            // The lift counterpart to the route map: the body, with worked muscles glowing iridescent.
            muscleMedia(muscles)
        } else if item.routeCoordinates?.count ?? 0 > 1 {
            // A cached STATIC snapshot of the route on its basemap — a live map engine per post is
            // what made Community slow to populate and heavy to scroll.
            FeedRouteMap(item: item, height: height)
        } else if item.type.isTimed {
            // Timed sports (pool swim, erg, yoga…) have no route or muscle map — a discipline card
            // gives the post a visual anchor so the feed reads consistently, not text-only.
            timedMedia
        }
    }

    /// Stopwatch-sport media — the sport's glyph as a faint watermark with a quiet label, monochrome
    /// (no earned-iridescence — there's no progress to mark here, just identity).
    private var timedMedia: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            Image(systemName: item.type.systemImage)
                .font(.system(size: 130, weight: .regular))
                .foregroundStyle(Theme.inkTertiary.opacity(0.10))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: 34)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: item.type.systemImage)
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                Text(item.type.title.uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(Theme.Space.md)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .allowsHitTesting(false)
    }

    /// Strength media — front/back body on a faint card, worked muscles lit, with a small caption of
    /// the top muscles so the post reads at a glance like a route map shows the route. The body figures
    /// are narrow, so they're centered in the card (not pinned left) and the summary capsule floats in
    /// the bottom-leading corner as an overlay.
    private func muscleMedia(_ muscles: [MuscleGroup: Double]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            MuscleMapView(activation: muscles)
                .padding(.vertical, Theme.Space.md)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 220)
        .overlay(alignment: .bottomLeading) {
            Text(workedSummary(muscles))
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.3)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.background.opacity(0.7)))
                .overlay(Capsule().stroke(Theme.hairline))
                .padding(Theme.Space.sm)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .allowsHitTesting(false)
    }

    /// "Chest · Shoulders · Triceps" — the most-worked muscles, for the media caption + a11y.
    private func workedSummary(_ muscles: [MuscleGroup: Double]) -> String {
        muscles.filter { $0.value > 0 }.sorted { $0.value > $1.value }
            .prefix(3).map { $0.key.displayName }.joined(separator: " · ")
    }
}
