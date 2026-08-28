import SwiftUI

/// The superset partner picker (2026-07-23): always names the anchor — "Pair Barbell Rows
/// with…" — so there's never a what-am-I-picking moment. Three rungs, easiest first:
///
///  1. **In this workout** — the session's other standalone exercises, one tap to link. The
///     plan gave you five exercises; running two as a pair is the most common superset there is.
///  2. **Suggested** — classic antagonist partners from the catalog (chest↔back, biceps↔triceps,
///     quads↔hamstrings): one side rests while the other works. Same equipment ranks first.
///  3. **Browse all** — the full library for everything else.
struct SupersetPickerView: View {
    let vm: StrengthViewModel
    let anchorRowId: UUID
    var onDone: () -> Void

    @State private var browsing = false
    /// Computed ONCE per presentation, off the body path: `supersetSuggestions` synchronously
    /// fetches the whole exercise catalog from SwiftData, and running that inside body re-paid
    /// the fetch on every vm refresh while the sheet was open (audit 2026-08-11 — the
    /// engine-work-in-body rule).
    @State private var suggestions: [Exercise] = []

    private var anchorName: String {
        vm.exercises.first(where: { $0.id == anchorRowId })?.name ?? "this exercise"
    }

    var body: some View {
        if browsing {
            ExerciseLibraryView { exercises in
                Task {
                    if let first = exercises.first {
                        await vm.pairSuperset(anchor: anchorRowId, with: first)
                        for extra in exercises.dropFirst() { await vm.addExercise(extra) }
                    }
                    onDone()
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    header
                    let links = vm.supersetLinkCandidates(for: anchorRowId)
                    if !links.isEmpty {
                        section("IN THIS WORKOUT") {
                            ForEach(links) { candidate in
                                row(name: candidate.name, detail: "already on your list") {
                                    Task {
                                        await vm.pairExisting(anchorRowId, candidate.id)
                                        onDone()
                                    }
                                }
                            }
                        }
                    }
                    if !suggestions.isEmpty {
                        section("SUGGESTED · OPPOSITE MUSCLES") {
                            ForEach(suggestions) { exercise in
                                row(name: exercise.name, detail: muscleLine(exercise)) {
                                    Task {
                                        await vm.pairSuperset(anchor: anchorRowId, with: exercise)
                                        onDone()
                                    }
                                }
                            }
                        }
                    }
                    Button { browsing = true } label: {
                        HStack {
                            Label("Browse all exercises", systemImage: "magnifyingglass")
                                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        .padding(Theme.Space.md)
                        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.Space.md)
            }
            .background(Theme.background)
            .onAppear { suggestions = vm.supersetSuggestions(for: anchorRowId) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 11, weight: .bold))
                Text("SUPERSET").tracking(1.2)
            }
            .font(.rounded(Theme.FontSize.label, weight: .bold))
            .foregroundStyle(Theme.inkTertiary)
            Text("Pair \(anchorName) with…")
                .font(.display(24, weight: .black))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Alternate sets with no rest between the two — the rest ring comes after each round.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.md)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            VStack(spacing: 0) { content() }
                .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
    }

    private func row(name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, Theme.Space.md)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Divider().overlay(Theme.hairline).padding(.leading, Theme.Space.md)
        }
        .accessibilityLabel("Pair with \(name), \(detail)")
    }

    /// "Back · Hamstrings" — where the partner hits, so the pairing's logic is visible.
    private func muscleLine(_ exercise: Exercise) -> String {
        let names = exercise.primaryMuscles.compactMap { MuscleGroup(rawValue: $0)?.displayName }
        return names.isEmpty ? "opposite muscle group" : names.joined(separator: " · ")
    }
}
