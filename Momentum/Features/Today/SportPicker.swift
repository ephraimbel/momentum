import SwiftUI
import SwiftData

/// The "Choose Activity" picker — momentum's Strava-style activity selector, grouped by category with
/// a search bar at the top. A **"Your activities"** shortcut row sits at the very top: the activities a
/// user has starred plus the ones they log most, so a hybrid athlete (runs + lifts) never scrolls for
/// their two or three. **Sports shown up there are REMOVED from their category section below**
/// (owner call 2026-07-30 — Run appearing in both "Your activities" and "Foot Sports" read as a
/// doubled list); starring moves a row up with an animation, unstarring sends it home. Star
/// toggles live on every card. Monochrome cards via the shared `SelectionCard`. The ONE picker
/// everywhere — Today's chip, the manual log, and the plan's add-session sheet all present this view.
/// (A tile-grid restructure was built and rejected same day — keep the row list.)
struct SportPicker: View {
    @Binding var selection: WorkoutType
    var onClose: () -> Void

    @State private var query = ""
    @State private var favorites = SportFavorites()
    /// Feeds the "most used" ordering only (`loggedCounts`), never a displayed total — so it reads a
    /// recent slice rather than every workout ever logged to sort a list of ~20 sports. 500 sessions
    /// is years of training for most athletes; where it does differ from all-time, ranking by recent
    /// use is the better answer for a picker anyway.
    private static var recentForRanking: FetchDescriptor<Workout> {
        var d = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\Workout.startedAt, order: .reverse)])
        d.fetchLimit = 500
        return d
    }
    @Query(SportPicker.recentForRanking) private var workouts: [Workout]
    /// Per-sport log counts, snapshotted once on present — grouping the whole workout table inside a
    /// computed property re-ran per body evaluation (every search keystroke, every star toggle).
    @State private var loggedCounts: [WorkoutType: Int] = [:]

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func matches(_ t: WorkoutType) -> Bool {
        trimmed.isEmpty || t.title.localizedCaseInsensitiveContains(trimmed)
    }
    private var results: [WorkoutType] { WorkoutType.allCases.filter(matches) }

    /// The top shortcut list: starred activities first (in the order starred), then the most-logged
    /// ones not already starred. Capped so it stays a quick-pick, not a second full list.
    private var topActivities: [WorkoutType] {
        var out = favorites.favorites
        let mostUsed = loggedCounts.sorted { $0.value > $1.value }.map(\.key).filter { !out.contains($0) }
        out += mostUsed
        return Array(out.prefix(5))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if trimmed.isEmpty {
                            let top = topActivities
                            if !top.isEmpty {
                                section("Your activities", top)
                            }
                            // Each category minus what "Your activities" already shows — a sport
                            // never appears twice on this screen. A category whose sports all
                            // moved up disappears entirely rather than sitting as an empty header.
                            ForEach(SportCategory.allCases) { category in
                                let rest = WorkoutType.allCases.filter {
                                    $0.category == category && !top.contains($0)
                                }
                                if !rest.isEmpty { section(category.title, rest) }
                            }
                        } else if results.isEmpty {
                            emptyState
                        } else {
                            section(nil, results)   // flat results while searching
                        }
                    }
                    .padding(Theme.Space.lg)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .task { loggedCounts = Dictionary(grouping: workouts, by: \.type).mapValues(\.count) }
            .background(Theme.background)
            .navigationTitle("Choose Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onClose() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
            TextField("Search activities", text: $query)
                .font(.rounded(Theme.FontSize.body, weight: .medium))
                .foregroundStyle(Theme.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.hairline))
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.xs)
    }

    @ViewBuilder
    private func section(_ title: String?, _ sports: [WorkoutType]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let title {
                Text(title.uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
            }
            ForEach(sports) { sport in
                SelectionCard(title: sport.title,
                              systemImage: sport.systemImage,
                              isSelected: selection == sport,
                              isFavorite: favorites.isFavorite(sport),
                              // Animated: with the sections deduped, starring MOVES the row up to
                              // "Your activities" (and unstarring sends it home) — the slide makes
                              // that read as a move, not a vanish-and-reappear.
                              onToggleFavorite: { withAnimation(Motion.lively) { favorites.toggle(sport) } }) {
                    selection = sport
                    onClose()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.inkTertiary)
            Text("No activities match \u{201C}\(trimmed)\u{201D}")
                .font(.rounded(Theme.FontSize.body, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xxl)
    }
}

/// UserDefaults-backed favorite activities behind the picker's star toggles. Order is preserved (newly
/// starred activities append) so "Your activities" keeps the user's own ordering ahead of most-used.
@Observable
final class SportFavorites {
    private static let key = "favoriteWorkoutTypes"
    private(set) var favorites: [WorkoutType]

    init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        favorites = raw.compactMap(WorkoutType.init(rawValue:))
    }

    func isFavorite(_ t: WorkoutType) -> Bool { favorites.contains(t) }

    func toggle(_ t: WorkoutType) {
        if let i = favorites.firstIndex(of: t) { favorites.remove(at: i) } else { favorites.append(t) }
        UserDefaults.standard.set(favorites.map(\.rawValue), forKey: Self.key)
    }
}
