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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var profiles: [UserProfile]

    @State private var draft = ""
    @FocusState private var composing: Bool
    /// The tapped commenter — pushed within this sheet's own NavigationStack. Commenters are real
    /// directory athletes, so their name/avatar routes to their profile like anywhere else.
    @State private var shownAthlete: CommunityAthlete?
    /// The comment just posted, so the list can scroll to it. On a thread with a screen of seeded
    /// comments, a new comment lands below the fold: the athlete typed, the field cleared, and
    /// nothing they could see changed — which reads exactly like a send that failed.
    @State private var justPosted: UUID?
    /// The comment awaiting a report reason. Posts get a reason picker; comments used to file
    /// everything as "Something else", which tells review nothing (fixed 2026-08-29).
    @State private var reporting: Comment?

    private var profile: UserProfile? { profiles.first }

    /// The seeded half, computed ONCE per post (non-observed box). `CommunityComments.seed` walks
    /// the follow graph and runs a draw per comment, and `visible` re-evaluates on every keystroke
    /// in the composer — the same reason `CommunityPager` memoizes its rail count.
    private final class ThreadMemo {
        var id: UUID?
        var comments: [Comment] = []
    }
    @State private var memo = ThreadMemo()

    /// Comments, moderation-filtered, oldest → newest. Seeds join ONLY on badged community posts —
    /// a real athlete's thread is exactly what was actually written (pulled + the viewer's own);
    /// fabricated comments on a real person's post crossed the honesty line (caught 2026-07-30).
    private var visible: [Comment] {
        if memo.id != item.id {
            memo.id = item.id
            memo.comments = item.isCommunity ? CommunityComments.seed(for: item) : []
        }
        return (memo.comments + comments.comments(for: item.id))
            .filter(moderation.isVisible)
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                            postHeader
                            Divider().overlay(Theme.hairline)
                            let rows = visible
                            if rows.isEmpty {
                                Text("No comments yet. Be the first.")
                                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                                    .padding(.top, Theme.Space.sm)
                            } else {
                                // Singular when there is one. A "1 comments" header is the same small
                                // lie as a count that disagrees with the list under it.
                                Text(rows.count == 1 ? "1 comment" : "\(rows.count) comments")
                                    .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .contentTransition(.numericText())
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: rows.count)
                                    .accessibilityIdentifier("comment-count")
                                ForEach(rows) {
                                    row($0)
                                        .id($0.id)
                                        .transition(.opacity.combined(with: .offset(y: 5)))
                                }
                            }
                        }
                        .padding(Theme.Space.lg)
                    }
                    // The comment you just wrote is brought into view — see `justPosted`.
                    .onChange(of: justPosted) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                composer
            }
            .background(Theme.background)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(item: $shownAthlete) { AthleteProfileView(athlete: $0) }
            .confirmationDialog("Report this comment?", isPresented: reportingBinding, titleVisibility: .visible) {
                ForEach(ReportReason.allCases) { reason in
                    Button(reason.rawValue) {
                        if let target = reporting { moderation.reportComment(target.id, reason: reason) }
                        reporting = nil
                        Haptics.success()
                        ToastCenter.shared.show(icon: "flag", line: "Reported. It's hidden from you.")
                    }
                }
                Button("Cancel", role: .cancel) { reporting = nil }
            } message: {
                Text("We'll review it and hide it from you.")
            }
            .onAppear {
                comments.pullRemote(for: item.id)   // merge the server thread (no-op offline)
                // Whatever was typed and not sent last time — see `CommentStore.drafts`.
                if draft.isEmpty { draft = comments.draft(for: item.id) }
            }
            // Dismissing the sheet used to throw an unsent comment away. Keep it.
            .onDisappear { comments.setDraft(draft, for: item.id) }
        }
        // Sparse threads should feel intentional instead of like an empty full-screen page. The
        // athlete can pull to full height as the conversation grows, exactly like a premium social
        // sheet, while the composer remains attached to the keyboard-safe bottom edge.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(Theme.background)
    }

    private var reportingBinding: Binding<Bool> {
        Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } })
    }

    private var postHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
            Text("\(item.authorName) · \(item.statLine)")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        commenterName(comment)
                        commentTimestamp(comment)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        commenterName(comment)
                        commentTimestamp(comment)
                    }
                }
                Text(comment.text).font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button { reporting = comment } label: { Label("Report", systemImage: "flag") }
            if comment.isCommunity, let h = comment.authorHandle {
                Button(role: .destructive) {
                    // Blocking here now also unfollows and drops them from the ring row and the
                    // follow list (`ModerationStore.follows`) — it used to hide their posts only.
                    moderation.block(h)
                    Haptics.medium()
                    ToastCenter.shared.show(icon: "hand.raised", line: "Blocked \(comment.authorName).")
                } label: {
                    Label("Block \(comment.authorName)", systemImage: "hand.raised")
                }
            } else {
                Button(role: .destructive) { comments.delete(comment); Haptics.medium() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func commenterName(_ comment: Comment) -> some View {
        Text(comment.authorName)
            .font(.rounded(Theme.FontSize.caption, weight: .bold))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .onTapGesture {
                if comment.isCommunity, let h = comment.authorHandle,
                   let athlete = CommunityDirectory.athlete(handle: h) { shownAthlete = athlete }
            }
    }

    private func commentTimestamp(_ comment: Comment) -> some View {
        Text(comment.date.formatted(.relative(presentation: .named)))
            .font(.rounded(Theme.FontSize.label, weight: .medium))
            // Tertiary dark ink is 3.96:1 on the warm-charcoal canvas; these are small words, so
            // secondary ink keeps them above the common 4.5:1 readability target.
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
    }

    private var composer: some View {
        HStack(spacing: Theme.Space.sm) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .lineLimit(1...4)
                .focused($composing)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                .raised(Capsule())
                .accessibilityIdentifier("comment-field")
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
        // The draft is cleared ONLY on a comment that was actually added. Clearing it either way
        // would throw away text the athlete typed with nothing to show for it.
        let posted = withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            comments.add(draft, to: item.id, authorName: name, authorHandle: handle)
        }
        guard let posted else { return }
        draft = ""
        comments.setDraft("", for: item.id)     // it was sent; there is nothing left to restore
        composing = false
        justPosted = posted.id
        Haptics.light()
    }
}
