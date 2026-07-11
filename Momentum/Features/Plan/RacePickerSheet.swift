import SwiftUI

/// The race picker — finding your marathon should feel like choosing an occasion, not filling a
/// form. Searchable catalog of the world's storied races: the seven World Marathon Majors
/// spotlighted up top (serif names, editorial weight), then the United States and international
/// icons. Selecting a race hands back its name, distance, and computed next date in one tap.
/// Honest by design: we're not affiliated with any event and every date is the race's traditional
/// calendar slot — the caption says so, and the date stays editable after picking.
struct RacePickerSheet: View {
    /// Called with the chosen race and its computed next date.
    var onPick: (RaceCatalog.Race, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [RaceCatalog.Race] { RaceCatalog.search(query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if searching {
                        raceList(results, kicker: results.isEmpty ? nil : "RESULTS")
                        if results.isEmpty { emptyState }
                    } else {
                        ForEach(RaceCatalog.Region.allCases, id: \.self) { region in
                            let races = results.filter { $0.region == region }
                            if !races.isEmpty {
                                raceList(races, kicker: region.rawValue.uppercased(),
                                         spotlight: region == .majors)
                            }
                        }
                    }
                    Text("Dates are each race's traditional weekend — an estimate, not a promise. Confirm with your race; you can adjust the date after picking.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Space.sm)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationTitle("Find your race")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search races, cities, countries")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationBackground(Theme.background)
    }

    // MARK: Sections

    private func raceList(_ races: [RaceCatalog.Race], kicker: String?, spotlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let kicker {
                Text(kicker)
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
            }
            VStack(spacing: Theme.Space.sm) {
                ForEach(races) { race in
                    raceRow(race, spotlight: spotlight)
                }
            }
        }
    }

    /// One race, editorially set: serif name (the occasion), city + flag, and the date chip.
    private func raceRow(_ race: RaceCatalog.Race, spotlight: Bool) -> some View {
        let next = race.nextDate()
        return Button {
            guard let next else { return }
            Haptics.success()
            onPick(race, next)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                Text(race.flag).font(.system(size: 26))
                VStack(alignment: .leading, spacing: 3) {
                    Text(race.name)
                        .font(spotlight ? .serif(19, weight: .semibold) : .rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    Text("\(race.city) · \(race.distance.label)")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: Theme.Space.sm)
                if let next {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(next.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.display(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Theme.ink)
                        Text(next.formatted(.dateTime.year()))
                            .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
            }
            .padding(Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: spotlight ? 1.2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(race.name), \(race.city), \(next?.formatted(date: .abbreviated, time: .omitted) ?? "")")
        .accessibilityHint("Points your plan at this race")
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Text("No races match \"\(query)\"")
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Text("Pick your distance and date manually — the plan builds the same either way.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}
