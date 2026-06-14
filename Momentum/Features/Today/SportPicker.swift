import SwiftUI

/// The "Choose Activity" picker — momentum's Strava-style activity selector, grouped by category with
/// a search bar at the top. Typing filters to matching activities; tapping one selects it and
/// dismisses. Monochrome cards via the shared `SelectionCard`.
struct SportPicker: View {
    @Binding var selection: WorkoutType
    var onClose: () -> Void

    @State private var query = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func matches(_ t: WorkoutType) -> Bool {
        trimmed.isEmpty || t.title.localizedCaseInsensitiveContains(trimmed)
    }
    private var results: [WorkoutType] { WorkoutType.allCases.filter(matches) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if trimmed.isEmpty {
                            ForEach(SportCategory.allCases) { category in
                                section(category.title, WorkoutType.allCases.filter { $0.category == category })
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
                              isSelected: selection == sport) {
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
