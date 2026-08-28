import SwiftUI

/// The hero's non-generic vocabulary — shared value types and the two control shapes callers
/// compose their chrome and pills from.
enum ProfileHeroStyle {
    struct Chip: Identifiable, Hashable {
        let id: String
        let text: String
        /// Lavender-tinted: reserved for the thing that is *happening* (the goal race).
        var accent: Bool = false
    }
    struct FollowLine {
        let followers: Int
        let following: Int
        let action: () -> Void
    }
    /// The PFP straddling the cover edge. 76, walked down from 104 → 88 → 76 (owner, 2026-08-26):
    /// at 104 the photo dwarfed the name it belongs to, and against the shorter cover band 88 read
    /// oversized again. It still straddles the edge; it just stopped being the loudest thing here.
    static let avatarSize: CGFloat = 84

    /// The hero's own side margin — a notch wider than the house 16 because everything up here
    /// either floats over full-bleed media or sits above the edge-to-edge grid, and at 16 the
    /// glass chrome read as falling off the page (owner call 2026-08-26). One token for the
    /// chrome, the PFP, the identity column and the pills, so nothing up here is inset differently
    /// from anything else.
    static let gutter: CGFloat = Theme.Space.md + Theme.Space.xs


    /// The glass circle every control over media uses (Today's map chrome, the share editor).
    static func chromeButton(_ systemImage: String, size: CGFloat = 16) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: size, weight: .semibold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44).momentumGlass(in: Circle())
    }

    /// A hero action pill. `.glass` is the quiet pair (Edit · Share, Following); `.ink` is the
    /// page's one primary action (Follow) — filled ink, never lavender, per the CTA rule.
    enum PillStyle { case glass, ink }

    static func pill(_ title: String, style: PillStyle = .glass) -> some View {
        Text(title)
            .font(.rounded(Theme.FontSize.body, weight: .semibold))
            .foregroundStyle(style == .ink ? .white : Theme.ink)
            .frame(maxWidth: .infinity).frame(height: 44)
            // Glass pass 2026-08-27: the ink pill wears the raised material (fixed-dark, so the
            // label is white in both modes); the glass pair stays glass over the media cover.
            .modifier(InkRaiseIf(enabled: style == .ink))
            .modifier(GlassIf(enabled: style == .glass))
            .contentShape(Capsule())
    }

    private struct InkRaiseIf: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.raised(Capsule(), tone: .ink) } else { content }
        }
    }

    private struct GlassIf: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.momentumGlass() } else { content }
        }
    }
}

/// The profile's top bar: leading · centre · trailing in one fixed geometry. The three slots are
/// laid out as a ZStack so the centre control is truly centred on the screen regardless of what
/// the side slots hold — an HStack with Spacers would nudge it whenever the leading and trailing
/// widths differed, which is exactly the flicker this exists to remove. Every slot is 44pt; every
/// caller passes a `ProfileHeroStyle.chromeButton` or an equal-sized placeholder.
struct ProfileTopBar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var center: () -> Center
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            center()
            HStack {
                leading()
                Spacer(minLength: 0)
                trailing()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, ProfileHeroStyle.gutter)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.background)
    }
}

/// The block above every profile grid — yours and any athlete's — in ONE layout so the two pages
/// are twins by construction, not by hand-copying. Instagram's structure (owner call 2026-08-27,
/// replacing the cover-photo hero):
///
///   plain top bar: leading chrome · trailing chrome (no cover, nothing under the status bar)
///   PFP on the left, ringed when they trained in the last 24h · the trio beside it
///   name + seal · @handle · location · bio · followers line
///   chips · action pills
///
/// The trio sits BESIDE the photo the way Instagram's posts/followers/following does, and it
/// works here where it did not before because the photo is 84pt and the row has the whole
/// column: three cells over ~260pt is comfortable, whereas the old 104pt photo plus gutters left
/// ~80pt per cell and the labels crowded. The cover photo is gone entirely — the page is the
/// canvas from the first pixel, which is what lets the grid sit high.
///
/// The caller supplies the chrome, the avatar and the pills; the hero owns every measurement,
/// so a spacing fix lands on both pages at once.
struct ProfileHero<Chrome: View, Avatar: View, Pills: View>: View {
    typealias Chip = ProfileHeroStyle.Chip
    typealias FollowLine = ProfileHeroStyle.FollowLine

    var ringed: Bool
    var trio: [(value: String, label: String)]
    var name: String
    var isPro: Bool
    var handle: String
    var location: String?
    var bio: String
    var followLine: FollowLine?
    var chips: [Chip]
    @ViewBuilder var chrome: () -> Chrome
    @ViewBuilder var avatar: () -> Avatar
    @ViewBuilder var pills: () -> Pills

    private var avatarSize: CGFloat { ProfileHeroStyle.avatarSize }
    private var gutter: CGFloat { ProfileHeroStyle.gutter }
    /// The one step between every row of the identity column — 12.
    private var rowSpacing: CGFloat { Theme.Space.sm + Theme.Space.xs }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The caller's bar. ProfileScreen passes EmptyView here and hosts `ProfileTopBar` as a
            // safe-area inset instead, so its bar is pinned and shared across the Profile ↔
            // Community flip; AthleteProfileView (a push with no second face) draws its back/more
            // pair here.
            chrome()

            // Photo left, ledger right — Instagram's row. `.center` alignment so the trio's
            // numbers sit on the photo's midline rather than hanging off its bottom edge.
            HStack(alignment: .center, spacing: Theme.Space.md) {
                ringedAvatar
                trioRow
            }
            .padding(.horizontal, gutter)
            .padding(.top, Theme.Space.xs)

            // One column, one rhythm below the photo row.
            VStack(alignment: .leading, spacing: rowSpacing) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    nameRow
                    handleRow
                }
                if !bio.isEmpty {
                    Text(bio)
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let followLine { followRow(followLine) }
                if !chips.isEmpty {
                    FlowLayout(spacing: Theme.Space.sm) {
                        ForEach(chips) { chipView($0) }
                    }
                }
                HStack(spacing: Theme.Space.sm) { pills() }
            }
            .padding(.horizontal, gutter)
            .padding(.top, rowSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: PFP + trio

    private var ringedAvatar: some View {
        // `PresenceRing` is the ONE ring definition (owner call 2026-08-27): quiet ink normally,
        // an animated iridescent sweep once they have posted. Shared with the community home's
        // face row so a person's ring looks identical wherever you meet them.
        PresenceRing(active: ringed) { avatar() }
            .accessibilityLabel(ringed ? "\(name), trained today" : name)
    }

    /// The ledger, on its own full-width row: three equal cells split by hairlines, the way the
    /// trio was laid out before the hero was rebuilt. Cells are equal thirds of the whole column
    /// rather than of whatever the PFP left over, so the labels never crowd their neighbours and
    /// the last one never reaches the screen edge.
    /// Three equal cells beside the photo — value over a small tracked label, Instagram's
    /// posts/followers/following grammar. Text scales rather than clips at large Dynamic Type.
    private var trioRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(trio.enumerated()), id: \.offset) { _, cell in
                VStack(spacing: 2) {
                    Text(cell.value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(cell.label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Name · handle · follows

    private var nameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(name).font(.display(Theme.FontSize.title, weight: .black)).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            if isPro {
                // The Verified-Pro seal — the SAME purple checkmark every feed byline shows
                // (owner call 2026-08-25: never a "PRO" pill next to a name).
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.purple)
                    .accessibilityLabel("Verified Pro")
            }
        }
    }

    @ViewBuilder private var handleRow: some View {
        if !handle.isEmpty || location != nil {
            HStack(spacing: 6) {
                if !handle.isEmpty {
                    Text("@\(handle)")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                if let location {
                    if !handle.isEmpty {
                        Circle().fill(Theme.inkTertiary).frame(width: 2.5, height: 2.5)
                    }
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    private func followRow(_ line: FollowLine) -> some View {
        Button(action: line.action) {
            HStack(spacing: 5) {
                Text("\(line.followers)").font(.rounded(Theme.FontSize.body, weight: .bold))
                    .monospacedDigit().foregroundStyle(Theme.ink)
                Text("Followers").font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                Circle().fill(Theme.inkTertiary).frame(width: 2.5, height: 2.5)
                Text("\(line.following)").font(.rounded(Theme.FontSize.body, weight: .bold))
                    .monospacedDigit().foregroundStyle(Theme.ink)
                Text("Following").font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.followers) followers, \(line.following) following")
    }

    // MARK: Chips

    private func chipView(_ chip: Chip) -> some View {
        Text(chip.text)
            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
            .foregroundStyle(chip.accent ? Theme.purpleDeep : Theme.inkSecondary)
            .padding(.horizontal, Theme.Space.md - 2).padding(.vertical, Theme.Space.chipV)
            .modifier(ChipSurface(accent: chip.accent))
    }
}

/// Hero chips: the accent chip keeps its lavender tint; plain chips wear the raised material.
private struct ChipSurface: ViewModifier {
    let accent: Bool
    func body(content: Content) -> some View {
        if accent {
            content.background(Capsule().fill(Theme.purpleTint))
                .overlay(Capsule().stroke(Theme.purple.opacity(0.25), lineWidth: 1))
        } else {
            content.raised(Capsule())
        }
    }
}
