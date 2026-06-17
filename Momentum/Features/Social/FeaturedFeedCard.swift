import SwiftUI
import UIKit

/// The feed's lead story — a full-bleed hero treatment of the top post (Substack's featured article).
/// Used only for posts with strong imagery (a photo or a route map); text-and-muscle posts stay as
/// editorial rows. Gives the feed a magazine rhythm without changing the card language beneath it.
struct FeaturedFeedCard: View {
    let item: FeedItem
    var navValue: WorldView.WorldRoute? = nil
    @Environment(ReactionStore.self) private var reactions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingDetail = false

    /// Only photo / route posts make good full-bleed heroes.
    static func canFeature(_ item: FeedItem) -> Bool {
        if item.photoData != nil { return true }
        if let c = item.routeCoordinates, c.count > 1 { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            byline
            Button { showingDetail = true } label: {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    hero
                    statStrip
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            footer
        }
        .padding(.vertical, Theme.Space.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .sheet(isPresented: $showingDetail) { PostDetailView(item: item) }
    }

    // MARK: Byline

    private var byline: some View {
        let identity = HStack(spacing: Theme.Space.sm) {
            AvatarView(photo: item.avatarData, name: item.authorName, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.authorName).font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if item.isCommunity { communityBadge }
                }
                Text(metaLine).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("FEATURED").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
        return Group {
            if let navValue {
                NavigationLink(value: navValue) { identity }.buttonStyle(.plain)
            } else { identity }
        }
    }

    private var metaLine: String {
        var parts = [item.date.formatted(.relative(presentation: .named))]
        if let handle = item.authorHandle { parts.insert("@\(handle)", at: 0) }
        if let loc = item.location { parts.append(loc) }
        return parts.joined(separator: " · ")
    }

    // MARK: Hero media + overlaid headline

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            media
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                if let pr = item.prBadge { PRBadge(text: pr) }
                Text(item.title)
                    .font(.display(28, weight: .black)).foregroundStyle(.white)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            }
            .padding(Theme.Space.md)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var media: some View {
        if let data = item.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: 300).clipped()
        } else if let coords = item.routeCoordinates, coords.count > 1 {
            RouteMapView(coordinates: coords, style: item.mapStyle, interactive: false)
                .frame(height: 300)
        } else {
            Rectangle().fill(Theme.surface)
        }
    }

    // MARK: Metric strip + footer

    @ViewBuilder
    private var statStrip: some View {
        let cells = item.metrics.map { StatGrid.Cell(value: $0.value, label: $0.label) }
        if !cells.isEmpty {
            StatGrid(cells: cells, valueSize: 17, leading: true).padding(.top, 2)
        }
    }

    private var footer: some View {
        let reacted = reactions.hasReacted(item.id)
        return Button {
            reactions.toggle(item.id); Haptics.light()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: reacted ? "bolt.fill" : "bolt")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(reacted ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.inkTertiary))
                    .scaleEffect(reacted && !reduceMotion ? 1.12 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: reacted)
                Text("\(reactions.count(for: item))")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                    .foregroundStyle(reacted ? Theme.ink : Theme.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .accessibilityLabel(reacted ? "Respected" : "Respect")
    }

    private var communityBadge: some View {
        Text("Momentum")
            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.4).foregroundStyle(Theme.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(IridescentMaterial()).opacity(0.55))
            .overlay(Capsule().stroke(Theme.hairline))
            .accessibilityLabel("Momentum community")
    }
}
