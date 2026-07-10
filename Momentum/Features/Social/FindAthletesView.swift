import SwiftUI

/// Find athletes (docs/SOCIAL-LAYER.md) — search the community by name, username, or @handle and
/// follow from the results. Two sources merge: the badged Momentum community resolves instantly and
/// locally; real, discoverable athletes come back from the backend when signed in (nothing for
/// guests/offline — the community results are the floor, so search never feels dead). Opened from
/// the Community header's magnifier and the Following empty state's "Find athletes".
struct FindAthletesView: View {
    /// Called with the chosen athlete's handle; the presenter dismisses and routes to the profile.
    var onOpen: (String) -> Void

    @Environment(FollowStore.self) private var follows
    @Environment(RemoteFeedStore.self) private var remoteFeed
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var remoteHits: [CommunityAthlete] = []
    @FocusState private var searching: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if trimmedQuery.isEmpty {
                            sectionLabel("SUGGESTED")
                            ForEach(suggested) { row($0) }
                        } else if results.isEmpty {
                            emptyResults
                        } else {
                            ForEach(results) { row($0) }
                        }
                    }
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.bottom, Theme.Space.xxl)
                }
            }
            .background(Theme.background)
            .navigationTitle("Find athletes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            // Debounced remote search — local results render instantly on every keystroke.
            .task(id: trimmedQuery) {
                let q = trimmedQuery
                guard q.count >= 2 else { remoteHits = []; return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                remoteHits = await remoteFeed.search(q)
            }
            .onAppear {
                searching = true
                #if DEBUG
                // --find-query <term>: pre-fill the search (deterministic sim verification of the
                // results list; host-keyboard injection into the sim is unreliable).
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "--find-query"), args.indices.contains(i + 1) {
                    query = args[i + 1]
                }
                #endif
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
    }

    /// (index, lowercased name, lowercased handle) — built once; keystrokes scan strings, never
    /// copy full athlete structs (their posts carry whole route polylines).
    private static let searchIndex: [(Int, String, String)] = CommunityDirectory.all().enumerated()
        .map { ($0.offset, $0.element.name.lowercased(), $0.element.handle.lowercased()) }

    /// Local community matches (name or handle), instantly; real athletes merge in behind them.
    private var results: [CommunityAthlete] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        let all = CommunityDirectory.all()
        let local = Self.searchIndex.lazy
            .filter { $0.1.contains(q) || $0.2.contains(q) }
            .prefix(30)
            .map { all[$0.0] }
        let localHandles = Set(local.map(\.handle))
        return Array(local) + remoteHits.filter { !localHandles.contains($0.handle) }
    }

    /// The hand-curated featured athletes lead the empty-query state — a warm start, not a void.
    private var suggested: [CommunityAthlete] { Array(CommunityDirectory.all().prefix(12)) }

    private var searchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            TextField("Search by name or @handle", text: $query)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searching)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.hairline))
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
            .foregroundStyle(Theme.inkTertiary)
            .padding(.bottom, Theme.Space.xs)
    }

    private func row(_ athlete: CommunityAthlete) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Button { onOpen(athlete.handle) } label: {
                HStack(spacing: Theme.Space.sm) {
                    AvatarView(photo: athlete.avatarData, name: athlete.name, size: 42)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(athlete.name)
                            .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(subtitle(athlete))
                            .font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(athlete.name)'s profile")
            followButton(athlete)
        }
        .padding(.vertical, Theme.Space.sm + 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private func subtitle(_ athlete: CommunityAthlete) -> String {
        var parts = ["@\(athlete.handle)"]
        if let loc = athlete.location { parts.append(loc) }
        return parts.joined(separator: " · ")
    }

    private func followButton(_ athlete: CommunityAthlete) -> some View {
        let isFollowing = follows.isFollowing(athlete.handle)
        return Button {
            follows.toggle(athlete.handle); Haptics.light()
        } label: {
            Text(isFollowing ? "Following" : "Follow")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(isFollowing ? Theme.ink : Theme.background)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 6)
                .background(Capsule().fill(isFollowing ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(Theme.ink)))
                .overlay(Capsule().stroke(isFollowing ? Theme.hairline : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFollowing ? "Unfollow \(athlete.name)" : "Follow \(athlete.name)")
    }

    private var emptyResults: some View {
        VStack(spacing: Theme.Space.sm) {
            Text("No athletes found")
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("Try their @handle, or check the spelling of their name.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xxl)
    }
}

#Preview {
    FindAthletesView { _ in }
        .environment(FollowStore())
        .environment(RemoteFeedStore())
}
