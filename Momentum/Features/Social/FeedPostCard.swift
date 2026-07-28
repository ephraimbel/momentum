import SwiftUI
import UIKit

/// One post in the feed — a Substack-style editorial row, not a boxed card (PRD §7.11): a quiet
/// author byline, a bold headline, the workout's numbers as a Strava-style metric strip, optional
/// photo/route/muscle media, a caption excerpt, and a restrained reaction footer, separated by a
/// hairline. Lean by design — whitespace and one hairline carry the structure, no chrome. Community
/// posts carry a clear "Momentum community" badge.
struct FeedPostCard: View {
    let item: FeedItem
    /// Set by feed contexts (Community) to make a community byline tap open the author's profile.
    /// nil in profile contexts — you're already on that person's page, so the byline stays inert.
    var onOpenAuthor: ((String) -> Void)? = nil
    @Environment(ReactionStore.self) private var reactions
    @Environment(ModerationStore.self) private var moderation
    @Environment(CommentStore.self) private var comments
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingReport = false
    @State private var showingComments = false
    @State private var showingDetail = false

    var body: some View {
        // Media-first (docs/COMMUNITY-FEED-REDESIGN.md): who → what → THE IMAGE → the numbers →
        // the actions → the words. The old order led with a headline and put media fourth, which
        // reads as an article; leading with the image reads as a feed.
        VStack(alignment: .leading, spacing: 0) {
            header
            // Tapping the media or the numbers opens the reading view; the byline, the ⋯ menu and
            // the action row all keep their own targets.
            Button { showingDetail = true } label: {
                VStack(alignment: .leading, spacing: 0) {
                    media
                    statStrip
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.top, Theme.Space.md)
                    if let pr = item.prBadge {
                        PRBadge(text: pr)
                            .padding(.horizontal, Theme.Space.md)
                            .padding(.top, Theme.Space.sm)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("post-body")
            actionRow
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.md)
            caption
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.xs)
        }
        // Whitespace is the separator now — the hairline between posts went with the redesign.
        // Density is what makes a feed read as a feed.
        .padding(.bottom, 36)
        .contextMenu { moderationMenu }
        // Full-screen, not a sheet — the sheet's card presentation clipped the reading view on
        // device (user report 2026-07-10); the post now opens as a clean full-page view. The cover
        // supplies the NavigationStack (for the Done toolbar) — the detail view itself is stack-less
        // so the profile grid can PUSH it without nesting stacks (which clipped it, 2026-07-15).
        .fullScreenCover(isPresented: $showingDetail) { NavigationStack { PostDetailView(item: item) } }
        .confirmationDialog("Report this post?", isPresented: $confirmingReport, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.rawValue) { moderation.reportPost(item.id, reason: reason); Haptics.success() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("We'll review it and hide it from your feed.") }
    }

    // MARK: Header (who · when, then what)

    /// Two rows above the media: the byline, then the workout's name. The title belongs HERE, not
    /// down with the caption — a workout's name is what it *is*, not commentary on it (Strava).
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            authorRow
            Text(item.title)
                .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
    }

    // In profile contexts the byline isn't a navigation target (you're already on that person's
    // page). In the Community feed, `onOpenAuthor` makes any handled byline — badged community
    // or real network athlete — open that athlete; callers pass nil for the viewer's own posts.
    private var authorRow: some View {
        HStack(spacing: Theme.Space.sm) {
            if let onOpenAuthor, let handle = item.authorHandle {
                Button { onOpenAuthor(handle) } label: { authorIdentity }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View \(item.authorName)'s profile")
            } else {
                authorIdentity
            }
            Spacer(minLength: 0)
            // Moderation is promoted out of a long-press-only context menu into a real, visible
            // control — a reporting path nobody can find doesn't satisfy App Store 1.2.
            Menu { moderationMenu } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Post options")
        }
    }

    private var authorIdentity: some View {
        HStack(spacing: Theme.Space.sm) {
            AvatarView(photo: item.avatarData, name: item.authorName, size: 36, imageName: item.communityAvatarAsset)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.authorName).font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).layoutPriority(1)
                    // The one thing that may sit beside a name: the Pro checkmark (X-style,
                    // brand violet). Real paying athletes only — never seeded content.
                    if item.isPro {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.purple)
                            .accessibilityLabel("Verified Pro")
                    }
                    // The time rides up here with the name (Instagram) — down in the sub-byline it
                    // was competing with the handle and the community label for one line, and lost
                    // ("3 minutes ag…").
                    Text("· \(item.date.formatted(.relative(presentation: .named)))")
                        .font(.rounded(15, weight: .regular)).foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
                if !byline.isEmpty {
                    Text(byline).font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// The sub-byline: identity and provenance only — the timestamp moved up to the name row.
    private var byline: String {
        var parts: [String] = []
        // Honest labeling of seeded content leads here — the name row belongs to the athlete (and
        // their Pro checkmark), but sample posts stay unmissably marked.
        if item.isCommunity { parts.append("Momentum community") }
        if let handle = item.authorHandle { parts.append("@\(handle)") }
        if let loc = item.location { parts.append(loc) }
        return parts.joined(separator: " · ")
    }

    // MARK: Metric strip (Strava-style)

    @ViewBuilder
    private var statStrip: some View {
        let cells = item.metrics.map { StatGrid.Cell(value: $0.value, label: $0.label) }
        if !cells.isEmpty {
            StatGrid(cells: cells, valueSize: 17, leading: true)
        }
    }

    // MARK: Caption

    @ViewBuilder
    private var caption: some View {
        if let caption = item.caption {
            // Instagram's run-on caption: handle in the ink weight, then the text, one block.
            (Text(item.authorHandle.map { "\($0) " } ?? "")
                .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink)
             + Text(caption)
                .font(.rounded(15, weight: .regular)).foregroundStyle(Theme.inkSecondary))
                .lineSpacing(3)
                .lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Media — the hero (photo > muscle map > route map > stat plate)

    /// Full-bleed, square-cornered, one 4:5 frame for every post. The ratio is fixed on purpose:
    /// mixed heights are what make a feed look broken, and a uniform frame is the thing that makes
    /// Instagram's read so clean. `hero` also switches the no-media fallback to the stat plate.
    private var media: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    FeedMediaView(item: item, height: geo.size.height, hero: true)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .clipped()
    }

    // MARK: Actions — like · comment, then share on the far right

    /// The split is Substack's and it's meaningful: the left cluster is *engagement* (this stays
    /// here), the right is *distribution* (this leaves). Repost deliberately absent — see the
    /// redesign doc §4: `posts_read` RLS means resharing a friends-only run exposes it to an
    /// audience it was never visible to, which with GPS maps attached is a safety bug.
    private var actionRow: some View {
        HStack(spacing: Theme.Space.lg) {
            respectButton
            commentButton
            Spacer(minLength: 0)
            shareButton
        }
        .sheet(isPresented: $showingComments) { PostCommentsView(item: item) }
    }

    private var shareButton: some View {
        ShareLink(item: shareText) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share")
    }

    /// Plain text for now. The real share is the existing share-card renderer (the designated
    /// growth loop) — wiring that in is P2 work, not part of the card's layout.
    private var shareText: String {
        [item.authorName, item.title, item.statLine].filter { !$0.isEmpty }.joined(separator: " · ")
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
        (CommunityComments.seed(for: item.id, postDate: item.date, reactions: item.baseReactions,
                                type: item.type, authorHandle: item.authorHandle)
            + comments.comments(for: item.id))
            .filter(moderation.isVisible).count
    }

    private var respectButton: some View {
        let reacted = reactions.hasReacted(item.id)
        return Button {
            reactions.toggle(item.id); Haptics.light()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: reacted ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(reacted ? Theme.like : Theme.inkTertiary)
                    .scaleEffect(reacted && !reduceMotion ? 1.12 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: reacted)
                Text("\(reactions.count(for: item))")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                    .foregroundStyle(reacted ? Theme.ink : Theme.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reacted ? "Liked" : "Like")
        .accessibilityValue("\(reactions.count(for: item))")
    }

    @ViewBuilder
    private var moderationMenu: some View {
        Button { confirmingReport = true } label: { Label("Report post", systemImage: "flag") }
        // Block any *other* athlete — a badged community author or a real network athlete — but never
        // the viewer's own posts, whose byline is inert (callers pass `onOpenAuthor == nil` for those).
        if let handle = item.authorHandle, item.isCommunity || onOpenAuthor != nil {
            Button(role: .destructive) { moderation.block(handle); Haptics.medium() } label: {
                Label("Block \(item.authorName)", systemImage: "hand.raised")
            }
        }
    }

}
