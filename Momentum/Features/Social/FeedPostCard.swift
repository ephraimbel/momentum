import SwiftUI

/// A feed post in the share-card language (PRD §7.11). Banner = route silhouette (cardio with a
/// public route) or a discipline glyph; below it the author, title/caption, and stat line. Community
/// items carry a clear "Momentum community" badge (honest labeling).
struct FeedPostCard: View {
    let item: FeedItem
    @Environment(ReactionStore.self) private var reactions
    @Environment(ModerationStore.self) private var moderation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingReport = false

    var body: some View {
        VStack(spacing: 0) {
            banner.frame(height: 150).frame(maxWidth: .infinity).clipped()
            details
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.authorName), \(item.type.title)")
        .accessibilityValue("\(item.title). \(item.statLine)\(item.isCommunity ? ". Momentum community" : "")")
        .contextMenu { moderationMenu }
        .confirmationDialog("Report this post?", isPresented: $confirmingReport, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.rawValue) { moderation.report(item.id); Haptics.success() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll review it and hide it from your feed.")
        }
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

    @ViewBuilder
    private var banner: some View {
        if let route = item.routeNorm, route.count > 1 {
            ZStack {
                Theme.background
                NormalizedPath(points: route)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(Theme.Space.lg)
            }
        } else {
            ZStack {
                LinearGradient(colors: Theme.iridescent.map { $0.opacity(0.25) },
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: item.type.systemImage)
                    .font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.ink.opacity(0.85))
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            authorRow
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                if let caption = item.caption {
                    Text(caption).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Theme.Space.sm) {
                Text(item.statLine).font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                if let pr = item.prBadge { PRBadge(text: pr) }
                Spacer(minLength: 0)
                respectButton
            }
        }
        .padding(Theme.Space.md)
    }

    /// The single iridescent "respect" reaction (PRD §10 social-lite — no kudos-spam, one warm signal).
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

    private var authorRow: some View {
        HStack(spacing: Theme.Space.sm) {
            IridescentOrb(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.authorName).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if item.isCommunity { communityBadge }
                }
                Text(subtitle).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        var parts = [item.date.formatted(.relative(presentation: .named))]
        if let handle = item.authorHandle { parts.insert("@\(handle)", at: 0) }
        if let loc = item.location { parts.append(loc) }
        return parts.joined(separator: " · ")
    }

    private var communityBadge: some View {
        Text("Momentum")
            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.4)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(IridescentMaterial()).opacity(0.55))
            .overlay(Capsule().stroke(Theme.hairline))
            .accessibilityLabel("Momentum community")
    }
}

/// A normalized (0…1) point path scaled into the available rect.
struct NormalizedPath: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        func map(_ pt: CGPoint) -> CGPoint { CGPoint(x: rect.minX + pt.x * rect.width, y: rect.minY + pt.y * rect.height) }
        p.move(to: map(first))
        for pt in points.dropFirst() { p.addLine(to: map(pt)) }
        return p
    }
}
