import SwiftUI
import SwiftData

/// The athlete's dedicated Profile tab (docs/SOCIAL-LAYER.md) — the public projection of who they
/// are, now a first-class destination rather than a push off Progress. Identity → headline counts →
/// lifetime body-of-work (discipline mix, consistency grid, trophy case) → recent shared activities,
/// with Edit + privacy and Settings in the header. Visiting another athlete reuses the same body via
/// `AthleteProfileView`.
struct ProfileScreen: View {
    /// When pushed (e.g. tapping your own post in World) we show a back chevron; as a tab root we don't.
    var showsBackButton: Bool = false
    /// Set when presented as a sheet (Today's avatar) — the screen hides the navigation bar, so an
    /// outer toolbar "Done" can never render; the close affordance must live in this header.
    var onClose: (() -> Void)? = nil

    @Query private var profiles: [UserProfile]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    /// PR shelf — tiles whose workout holds a current record carry the earned iridescent mark.
    @Query private var records: [PersonalRecord]
    @Environment(PaywallController.self) private var paywall
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    // Shared across BOTH live ProfileScreen instances (the Profile tab root and the Today-avatar
    // push) so the Grid/Highlights face never diverges between entry points — per-instance
    // @State meant picking Highlights on the tab, then opening via Today, showed Grid again.
    @AppStorage("com.momentum.profile.gridTab") private var gridTabRaw = ProfileGridTab.grid.rawValue
    private var gridTab: Binding<ProfileGridTab> {
        Binding(get: { ProfileGridTab(rawValue: gridTabRaw) ?? .grid },
                set: { gridTabRaw = $0.rawValue })
    }
    @State private var immersive: ImmersiveStart?
    #if DEBUG
    // --share-card: open the share composer on the latest workout for sim verification.
    @State private var debugSharing = ProcessInfo.processInfo.arguments.contains("--share-card")
    // --analytics-lab: preview the Pro Trends analytics section in isolation for sim verification.
    @State private var debugAnalytics = ProcessInfo.processInfo.arguments.contains("--analytics-lab")
    #endif

    private var profile: UserProfile? { profiles.first }

    // Cached per data change — as computed vars these walked every workout (and its sets) on every
    // property access, and the body touches them repeatedly. The fallback keeps the first frame
    // correct before the refresh task lands.
    @State private var cachedStats: ProfileStats?
    @State private var cachedHighlights: ProfileHighlights?
    /// Memo for the PRE-task fallback: the first body pass reads `stats`/`highlights` five times
    /// across the header, grid, and highlights sections — each access re-walked the full history
    /// before `refreshAggregates()` landed, all on the main actor before the first frame. A plain
    /// reference box (fields not observed), so filling it mid-body is invisible to SwiftUI.
    private final class FallbackMemo {
        var count = -1
        var stats: ProfileStats?
        var highlights: ProfileHighlights?
    }
    @State private var memo = FallbackMemo()
    private var stats: ProfileStats {
        if let cachedStats { return cachedStats }
        if memo.count != workouts.count { memo.count = workouts.count; memo.stats = nil; memo.highlights = nil }
        if let s = memo.stats { return s }
        let s = ProfileStats(workouts: workouts, plan: profile?.plan)
        memo.stats = s
        return s
    }
    private var highlights: ProfileHighlights {
        if let cachedHighlights { return cachedHighlights }
        if memo.count != workouts.count { memo.count = workouts.count; memo.stats = nil; memo.highlights = nil }
        if let h = memo.highlights { return h }
        let h = ProfileHighlights(stats: stats, workouts: workouts,
                                  weightUnit: weightUnit, distanceUnit: distanceUnit)
        memo.highlights = h
        return h
    }

    @State private var aggregatedForCount = -1   // matches the count the caches were built for

    private func refreshAggregates() {
        let fresh = ProfileStats(workouts: workouts, plan: profile?.plan)
        cachedStats = fresh
        cachedHighlights = ProfileHighlights(stats: fresh, workouts: workouts,
                                             weightUnit: weightUnit, distanceUnit: distanceUnit)
    }
    private var weightUnit: WeightUnit { WeightUnit(rawValue: profile?.weightUnit ?? "kg") ?? .kg }
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto }

    /// A tapped tile/highlight to open the immersive pager on (Identifiable for `.fullScreenCover(item:)`).
    private struct ImmersiveStart: Identifiable { let id: UUID }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            // The Grid / Highlights toggle scrolls WITH the content — no `pinnedViews`, so it rides
            // just above the grid and moves off-screen as you scroll (user preference 2026-07-22),
            // rather than sticking under the profile header as a mini-header.
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                Group {
                    identity
                    if let profile, !profile.bio.isEmpty {
                        Text(profile.bio)
                            .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.Space.md)

                if stats.totalWorkouts == 0 {
                    firstRunCard
                        .padding(.horizontal, Theme.Space.md)
                } else {
                    // The grid rides high — the athlete's training is the hero. Lifetime totals,
                    // discipline mix, and consistency live one tap away under "Highlights". The
                    // toggle and grid are plain siblings (no Section header) so the bar scrolls with
                    // the tiles instead of pinning.
                    ProfileGridTabBar(tab: gridTab)
                    ProfileGrid(workouts: workouts, stats: stats, highlights: highlights,
                                weightUnit: weightUnit, distanceUnit: distanceUnit, tab: gridTab.wrappedValue,
                                prWorkoutIds: Set(records.compactMap { $0.workout?.id })) { id in
                        immersive = ImmersiveStart(id: id)
                    }
                }
            }
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) { header }
        #if DEBUG
        // --profile-scroll-badges: bring the trophy case on screen for sim verification.
        .onAppear {
            // --profile-highlights: open on the Highlights face for sim verification (the tab
            // choice is @AppStorage-shared now, so the arg forces it rather than seeding init).
            if ProcessInfo.processInfo.arguments.contains("--profile-highlights") {
                gridTabRaw = ProfileGridTab.highlights.rawValue
            }
            if ProcessInfo.processInfo.arguments.contains("--profile-scroll-badges") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation { scroll.scrollTo("profile-badges", anchor: .top) }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--profile-scroll-consistency") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation { scroll.scrollTo("profile-consistency", anchor: .bottom) }
                }
            }
        }
        #endif
        }
        .sheet(isPresented: $editing) { if let profile { EditProfileView(profile: profile) } }
        #if DEBUG
        .sheet(isPresented: $debugSharing) {
            if let latest = workouts.first(where: { $0.gps != nil }) ?? workouts.first {
                ShareCardView(workout: latest, weightUnit: weightUnit, distanceUnit: distanceUnit)
            }
        }
        .sheet(isPresented: $debugAnalytics) {
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    ProTrendsSection(workouts: workouts, distanceUnit: distanceUnit)
                    StrengthProgressSection(workouts: workouts, weightUnit: weightUnit)
                }
                .padding(Theme.Space.md)
            }
            .background(Theme.background)
            // --metric-info: auto-open a detail sheet to verify the "how it's calculated" design.
            .overlay {
                if ProcessInfo.processInfo.arguments.contains("--metric-info") {
                    Color.clear.sheet(isPresented: .constant(true)) {
                        MetricDetailSheet(explainer: MetricExplainers.fitnessFreshness)
                            .presentationDetents([.medium, .large])
                    }
                }
            }
        }
        #endif
        .task(id: workouts.count) {
            // .task(id:) re-fires on every tab visit; the stats walk only needs to re-run
            // when the data actually moved — re-walking per switch read as tab-change jank.
            guard aggregatedForCount != workouts.count else { return }
            refreshAggregates()
            aggregatedForCount = workouts.count
        }
        .fullScreenCover(item: $immersive) { start in
            ImmersiveWorkoutPager(workouts: workouts, startID: start.id,
                                  weightUnit: weightUnit, distanceUnit: distanceUnit)
        }
    }

    // MARK: Header (custom — matches Progress/World)

    /// Quiet chrome only — no screen title. The athlete's name IS the page title; a "Profile"
    /// headline above it just said the same thing twice.
    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            if showsBackButton {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            Button { editing = true } label: {
                Text("Edit").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            NavigationLink { SettingsView() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Settings")
            if let onClose {
                Button("Done") { onClose() }
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.xs).padding(.bottom, Theme.Space.xs)
        .background(Theme.background)
    }

    // MARK: Identity

    private var identity: some View {
        VStack(spacing: Theme.Space.md) {
            AvatarView(photo: profile?.avatarData, name: displayName, size: 76)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)   // long names shrink; the seal stays put
                    // Verified Pro — the same checkmark the feed shows everyone else.
                    if paywall.isEntitled(to: .fullPlan) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.purple)
                            .accessibilityLabel("Verified Pro")
                    }
                }
            }
            statTrio
        }
        .frame(maxWidth: .infinity)
    }

    /// The athlete's own ledger (solo-first, 2026-07-16 — followers/following left with the
    /// community back-burner): volume, distance, achievement. Bare numbers on the canvas,
    /// hairline-divided — no boxed card competing with the grid below.
    private var statTrio: some View {
        HStack(spacing: 0) {
            trioCell("\(stats.totalWorkouts)", "Workouts")
            trioDivider
            trioCell(distanceTotalText, distanceUnitLabel)
            trioDivider
            trioCell("\(records.count)", "PRs")
        }
        .padding(.horizontal, Theme.Space.xl)
    }

    /// Lifetime GPS distance in the athlete's display unit, whole numbers ("312").
    private var distanceTotalText: String {
        let perUnit = distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000.0
        return "\(Int((stats.totalDistanceM / perUnit).rounded()))"
    }
    private var distanceUnitLabel: String {
        distanceUnit.resolved() == .imperial ? "Miles" : "Kilometers"
    }

    private func trioCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var trioDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 28)
    }

    private var displayName: String {
        let name = profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Athlete" : name
    }

    // MARK: First-run (no workouts yet)

    private var firstRunCard: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "figure.run.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.inkTertiary)
            Text("Your story starts here").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Log your first workout and your distance, streak, muscle map, and records fill in.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl).padding(.horizontal, Theme.Space.lg)
        .background(card)
    }

    // MARK: Building blocks

    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }
}
