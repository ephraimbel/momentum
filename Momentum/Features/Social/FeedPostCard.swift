import SwiftUI
import UIKit

/// One post in the feed — a Substack-style editorial row, not a boxed card (PRD §7.11): author byline,
/// a bold headline, the workout's numbers as a subtitle, optional photo/route media, a caption
/// excerpt, and a quiet reaction footer, separated by a hairline. Reads like a feed of athletes
/// posting their workouts. Community posts carry a clear "Momentum community" badge.
struct FeedPostCard: View {
    let item: FeedItem
    /// Where tapping the author byline navigates (nil = not tappable, e.g. on a profile's own list).
    var navValue: WorldView.WorldRoute? = nil
    @Environment(ReactionStore.self) private var reactions
    @Environment(ModerationStore.self) private var moderation
    @Environment(CommentStore.self) private var comments
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingReport = false
    @State private var showingComments = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            authorRow
            Text(item.title)
                .font(.display(21, weight: .bold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.sm) {
                Text(item.statLine).font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .monospacedDigit().foregroundStyle(Theme.inkSecondary)
                if let pr = item.prBadge { PRBadge(text: pr) }
            }
            media
            if let caption = item.caption {
                Text(caption).font(.rounded(Theme.FontSize.body, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.vertical, Theme.Space.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .contentShape(Rectangle())
        .contextMenu { moderationMenu }
        .confirmationDialog("Report this post?", isPresented: $confirmingReport, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.rawValue) { moderation.report(item.id); Haptics.success() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("We'll review it and hide it from your feed.") }
    }

    // MARK: Byline

    private var authorRow: some View {
        HStack(spacing: Theme.Space.sm) {
            // Tapping the author (avatar + name) opens their profile — the standard social pattern, and
            // it avoids the whole-card-as-NavigationLink conflict with the embedded live map.
            if let navValue {
                NavigationLink(value: navValue) {
                    authorIdentity
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.authorName)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feed-author")
                .accessibilityHint("Open profile")
            } else {
                authorIdentity
            }
            Spacer(minLength: 0)
            Image(systemName: item.type.systemImage).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var authorIdentity: some View {
        HStack(spacing: Theme.Space.sm) {
            AvatarView(photo: item.avatarData, name: item.authorName, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.authorName).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if item.isCommunity { communityBadge }
                }
                Text(byline).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var byline: String {
        var parts = [item.date.formatted(.relative(presentation: .named))]
        if let handle = item.authorHandle { parts.insert("@\(handle)", at: 0) }
        if let loc = item.location { parts.append(loc) }
        return parts.joined(separator: " · ")
    }

    // MARK: Media (photo > route silhouette > none)

    @ViewBuilder
    private var media: some View {
        if let data = item.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: 220).clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        } else if let coords = item.routeCoordinates, coords.count > 1 {
            // The actual map behind the route trace; the basemap varies per post (Strava-style).
            RouteMapView(coordinates: coords, style: item.mapStyle, interactive: false)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .allowsHitTesting(false)   // never steal the feed's scroll
        }
    }

    // MARK: Footer (reaction)

    private var footer: some View {
        HStack(spacing: Theme.Space.lg) {
            respectButton
            commentButton
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .sheet(isPresented: $showingComments) { PostCommentsView(item: item) }
    }

    private var commentButton: some View {
        Button { showingComments = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                if commentCount > 0 {
                    Text("\(commentCount)").font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .monospacedDigit().foregroundStyle(Theme.inkTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Comments")
        .accessibilityValue("\(commentCount)")
    }

    /// Visible comment count = seeded community + the user's own, minus moderation-hidden.
    private var commentCount: Int {
        (CommunityComments.seed(for: item.id) + comments.comments(for: item.id))
            .filter(moderation.isVisible).count
    }

    private var respectButton: some View {
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
        .accessibilityLabel(reacted ? "Respected" : "Respect")
        .accessibilityValue("\(reactions.count(for: item))")
    }

    @ViewBuilder
    private var moderationMenu: some View {
        Button { confirmingReport = true } label: { Label("Report post", systemImage: "flag") }
        if item.isCommunity, let handle = item.authorHandle {
            Button(role: .destructive) { moderation.block(handle); Haptics.medium() } label: {
                Label("Block \(item.authorName)", systemImage: "hand.raised")
            }
        }
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
