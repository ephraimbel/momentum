import SwiftUI

/// The reading view for a single post (docs/SOCIAL-LAYER.md) — the Substack "open the article" moment.
/// Full-bleed media, a big headline, the byline, the complete caption in a comfortable reading column,
/// the optional **Momentum read** (public AI narration), the full metric strip, and engagement. Opened
/// by tapping a post's content in the feed; the byline still routes to the profile.
struct PostDetailView: View {
    let item: FeedItem
    /// True when this view is PUSHED inside an existing NavigationStack (the athlete-profile grid)
    /// rather than presented as a cover. A pushed view must never carry its own NavigationStack —
    /// nesting stacks is unsupported and rendered the reading view clipped/cut off — and the outer
    /// stack's back button already handles dismissal, so the Done button is hidden too.
    var isPushed = false
    @Environment(ReactionStore.self) private var reactions
    @Environment(ModerationStore.self) private var moderation
    @Environment(CommentStore.self) private var comments
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var showingComments = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                byline
                Text(item.title)
                    .font(.display(30, weight: .black)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let pr = item.prBadge { PRBadge(text: pr) }
                // Reading view shows the WHOLE photo (fit, not cropped), taller than the feed band.
                // Its route map takes the render fast lane (urgent) — this is the one map the athlete
                // is actively looking at, so it must never sit behind the feed's render backlog.
                FeedMediaView(item: item, height: 360, photoContentMode: .fit, urgentRoute: true)
                StatGrid(cells: item.metrics.map { .init(value: $0.value, label: $0.label) },
                         valueSize: 20, leading: true)
                    .padding(.vertical, Theme.Space.sm)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                if let caption = item.caption {
                    Text(caption)
                        .font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.ink)
                        .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                }
                if let read = item.aiRead { momentumRead(read) }
                footer
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isPushed {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
        .sheet(isPresented: $showingComments) { PostCommentsView(item: item) }
    }

    // MARK: Byline

    private var byline: some View {
        HStack(spacing: Theme.Space.sm) {
            AvatarView(photo: item.avatarData, name: item.authorName, size: 44, imageName: item.communityAvatarAsset)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.authorName).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if item.isCommunity { communityBadge }
                }
                Text(metaLine).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var metaLine: String {
        var parts = [item.date.formatted(.relative(presentation: .named))]
        if let handle = item.authorHandle { parts.insert("@\(handle)", at: 0) }
        if let loc = item.location { parts.append(loc) }
        return parts.joined(separator: " · ")
    }

    // MARK: Momentum read (AI narration — monochrome; iridescence is reserved for progress)

    private func momentumRead(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "sparkles")
                Text("MOMENTUM READ").tracking(1.5)
            }
            .font(.rounded(Theme.FontSize.label, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            Text(text)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    // MARK: Engagement

    private var footer: some View {
        let reacted = reactions.hasReacted(item.id)
        return HStack(spacing: Theme.Space.xl) {
            Button { reactions.toggle(item.id); Haptics.light() } label: {
                HStack(spacing: 6) {
                    Image(systemName: reacted ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(reacted ? Theme.like : Theme.inkSecondary)
                        .scaleEffect(reacted && !reduceMotion ? 1.12 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: reacted)
                    Text("\(reactions.count(for: item))").font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                        .foregroundStyle(reacted ? Theme.ink : Theme.inkSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reacted ? "Liked" : "Like")
            Button { showingComments = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                    Text("\(commentCount)").font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Comments")
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Space.xs)
    }

    private var commentCount: Int {
        (CommunityComments.seed(for: item.id, postDate: item.date, reactions: item.baseReactions,
                                type: item.type, authorHandle: item.authorHandle)
            + comments.comments(for: item.id))
            .filter(moderation.isVisible).count
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
