import SwiftUI
import SwiftData

/// Comments on a post (docs/SOCIAL-LAYER.md). Shows seeded community comments + the user's own, with
/// a compose bar (light moderation on send) and per-comment report/block. Presented as a sheet from
/// the feed.
struct PostCommentsView: View {
    let item: FeedItem
    @Environment(CommentStore.self) private var comments
    @Environment(ModerationStore.self) private var moderation
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var draft = ""
    @FocusState private var composing: Bool
    /// The tapped commenter — pushed within this sheet's own NavigationStack. Commenters are real
    /// directory athletes, so their name/avatar routes to their profile like anywhere else.
    @State private var shownAthlete: CommunityAthlete?

    private var profile: UserProfile? { profiles.first }

    /// Comments, moderation-filtered, oldest → newest. Seeds join ONLY on badged community posts —
    /// a real athlete's thread is exactly what was actually written (pulled + the viewer's own);
    /// fabricated comments on a real person's post crossed the honesty line (caught 2026-07-30).
    private var visible: [Comment] {
        let seeded = item.isCommunity
            ? CommunityComments.seed(for: item.id, postDate: item.date, reactions: item.baseReactions,
                                     type: item.type, authorHandle: item.authorHandle)
            : []
        return (seeded + comments.comments(for: item.id))
            .filter(moderation.isVisible)
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        postHeader
                        Divider().overlay(Theme.hairline)
                        if visible.isEmpty {
                            Text("No comments yet. Say something kind.")
                                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                                .padding(.top, Theme.Space.sm)
                        } else {
                            ForEach(visible) { row($0) }
                        }
                    }
                    .padding(Theme.Space.lg)
                }
                composer
            }
            .background(Theme.background)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(item: $shownAthlete) { AthleteProfileView(athlete: $0) }
            .onAppear { comments.pullRemote(for: item.id) }   // merge the server thread (no-op offline)
        }
    }

    private var postHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
            Text("\(item.authorName) · \(item.statLine)")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func row(_ comment: Comment) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            // Commenter identity routes to their profile (basic social contract) — commenters are
            // real directory athletes, so the tap resolves for every seeded comment.
            Button {
                if comment.isCommunity, let h = comment.authorHandle,
                   let athlete = CommunityDirectory.athlete(handle: h) { shownAthlete = athlete }
            } label: {
                AvatarView(photo: comment.isCommunity ? nil : profile?.avatarData, name: comment.authorName, size: 30,
                           imageName: comment.isCommunity ? comment.authorHandle.flatMap { CommunityAvatars.assetName(forHandle: $0) } : nil,
                           preset: comment.isCommunity ? comment.authorHandle.flatMap { CommunityAvatars.preset(forHandle: $0) } : nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(comment.authorName)'s profile")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.authorName).font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .onTapGesture {
                            if comment.isCommunity, let h = comment.authorHandle,
                               let athlete = CommunityDirectory.athlete(handle: h) { shownAthlete = athlete }
                        }
                    Text(comment.date.formatted(.relative(presentation: .named)))
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
                Text(comment.text).font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button { moderation.reportComment(comment.id, reason: .other); Haptics.success() } label: { Label("Report", systemImage: "flag") }
            if comment.isCommunity, let h = comment.authorHandle {
                Button(role: .destructive) { moderation.block(h); Haptics.medium() } label: {
                    Label("Block \(comment.authorName)", systemImage: "hand.raised")
                }
            } else {
                Button(role: .destructive) { comments.delete(comment); Haptics.medium() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: Theme.Space.sm) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .lineLimit(1...4)
                .focused($composing)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                .raised(Capsule())
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    .foregroundStyle(canSend ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.inkTertiary))
            }
            .disabled(!canSend)
            .accessibilityLabel("Post comment")
        }
        .padding(Theme.Space.md)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let name = FeedAssembler.displayName(profile)
        let handle = profile.flatMap { $0.handle.isEmpty ? nil : $0.handle }
        if comments.add(draft, to: item.id, authorName: name, authorHandle: handle) != nil {
            draft = ""; composing = false; Haptics.light()
        }
    }
}
