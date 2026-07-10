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

    private var profile: UserProfile? { profiles.first }

    /// Seeded + user comments, moderation-filtered, oldest → newest.
    private var visible: [Comment] {
        (CommunityComments.seed(for: item.id) + comments.comments(for: item.id))
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
                            Text("No comments yet — say something kind.")
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
            AvatarView(photo: comment.isCommunity ? nil : profile?.avatarData, name: comment.authorName, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.authorName).font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
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
                .background(Capsule().fill(Theme.surface)).overlay(Capsule().stroke(Theme.hairline))
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
