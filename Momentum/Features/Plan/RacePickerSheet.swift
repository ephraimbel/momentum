import SwiftUI

/// The race picker — finding your race should feel like choosing an occasion, not filling a form.
/// A searchable catalog of the world's storied events: the seven World Marathon Majors spotlighted
/// (serif, editorial weight), then the United States and international icons — including the great
/// halfs and shorter classics, because most people race those.
///
/// The flow is deliberate, never abrupt: tap a race and it OPENS in place — distance chips for
/// everything the weekend offers, the computed date, the honest estimate note — and only the pinned
/// "Lock in" button commits. Honest by design: we're not affiliated with any event; dates are each
/// race's traditional calendar slot and stay editable after locking in.
struct RacePickerSheet: View {
    /// Called with the chosen race, the distance picked from its weekend, and the computed date.
    var onPick: (RaceCatalog.Race, RaceDistance, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selected: RaceCatalog.Race?
    @State private var distance: RaceDistance = .marathon

    private var results: [RaceCatalog.Race] { RaceCatalog.search(query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Per-day caches (perf audit 2026-08-13)
    //
    // `body` re-runs per search keystroke, and every race row resolved its next occurrence (up to
    // three Calendar walks) plus 3-4 fresh `Date.formatted` passes each time — ~20-60 ms per
    // keystroke across the 100-race catalog. Both caches are static: the catalog is immutable and
    // the resolved dates only change when the day does.

    /// A race's resolved next date with every string a row renders, computed once per day.
    private struct RowDate {
        let date: Date
        let monthDay: String     // "Apr 21"
        let year: String         // "2027"
        let fullLine: String     // "Monday, April 21, 2027"
        let abbreviated: String  // accessibility label form
    }
    @MainActor private static var rowDateCache: (day: Date, rows: [String: RowDate?]) = (.distantPast, [:])
    @MainActor private static func rowDate(for race: RaceCatalog.Race) -> RowDate? {
        let day = Calendar.current.startOfDay(for: Date())
        if rowDateCache.day != day { rowDateCache = (day, [:]) }
        if let hit = rowDateCache.rows[race.id] { return hit }
        let built: RowDate? = race.nextDate().map { next in
            RowDate(date: next,
                    monthDay: next.formatted(.dateTime.month(.abbreviated).day()),
                    year: next.formatted(.dateTime.year()),
                    fullLine: next.formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
                    abbreviated: next.formatted(date: .abbreviated, time: .omitted))
        }
        rowDateCache.rows[race.id] = built
        return built
    }

    /// The default (not-searching) region grouping — one pass over the static catalog, ever.
    private static let racesByRegion: [(region: RaceCatalog.Region, races: [RaceCatalog.Race])] = {
        let all = RaceCatalog.search("")
        return RaceCatalog.Region.allCases.compactMap { region in
            let races = all.filter { $0.region == region }
            return races.isEmpty ? nil : (region, races)
        }
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if searching {
                        raceList(results, kicker: results.isEmpty ? nil : "RESULTS")
                        if results.isEmpty { emptyState }
                    } else {
                        ForEach(Self.racesByRegion, id: \.region) { group in
                            raceList(group.races, kicker: group.region.rawValue.uppercased(),
                                     spotlight: group.region == .majors)
                        }
                    }
                    Text("Dates are each race's traditional weekend — an estimate, not a promise. Confirm with your race; the date stays editable after locking in.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Space.sm)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .navigationTitle("Find your race")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search races, cities, countries")
            // Typing a new search resets the review — a lock-in bar for a race that's no longer on
            // screen would be a trap, and this flow never traps.
            .onChange(of: query) { _, _ in
                withAnimation(reduceMotion ? nil : Motion.standard) { selected = nil }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            // The commitment moment, pinned: nothing locks in until the athlete says so.
            .safeAreaInset(edge: .bottom) {
                if let race = selected, let next = Self.rowDate(for: race)?.date {
                    lockInBar(for: race, date: next)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
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
            // Lazy: the default view lists ~100 cards across the regions — building them all on
            // the sheet's first frame is why the race step arrived late.
            LazyVStack(spacing: Theme.Space.sm) {
                ForEach(races) { race in
                    raceRow(race, spotlight: spotlight)
                }
            }
        }
    }

    /// One race, editorially set — and the review stage when selected: the card opens in place with
    /// the weekend's distances and the date, so choosing feels considered, never accidental.
    private func raceRow(_ race: RaceCatalog.Race, spotlight: Bool) -> some View {
        let isSelected = selected?.id == race.id
        let next = Self.rowDate(for: race)
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : Motion.standard) {
                if isSelected {
                    selected = nil
                } else {
                    selected = race
                    distance = race.flagship
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: Theme.Space.md) {
                    // Bundled emoji artwork also renders when the system emoji font is unavailable.
                    Image(race.flagArtworkName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(race.name)
                            .font(spotlight ? .serif(19, weight: .semibold) : .rounded(Theme.FontSize.body, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                        Text(subtitle(for: race))
                            .font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    if let next {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(next.monthDay)
                                .font(.display(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Theme.ink)
                            Text(next.year)
                                .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }

                // The open state: pick the weekend's distance; everything stays on this card.
                if isSelected {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                            .padding(.vertical, Theme.Space.sm)
                        if race.distances.count > 1 {
                            Text("RACE WEEKEND DISTANCES")
                                .font(.rounded(9, weight: .black)).tracking(1.4)
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        HStack(spacing: Theme.Space.xs) {
                            ForEach(race.distances) { d in
                                distanceChip(d)
                            }
                        }
                        if let next {
                            Text("\(next.fullLine) · traditional weekend")
                                .font(.rounded(Theme.FontSize.label, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(isSelected ? Theme.purple : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(race.name), \(race.city), \(race.country), \(next?.abbreviated ?? "")")
        .accessibilityHint(isSelected ? "Selected — choose a distance, then lock it in below" : "Opens this race")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func subtitle(for race: RaceCatalog.Race) -> String {
        let extra = race.distances.count - 1
        let base = "\(race.city) · \(race.flagship.label)"
        return extra > 0 ? "\(base) + \(extra) more" : base
    }

    private func distanceChip(_ d: RaceDistance) -> some View {
        let on = distance == d
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : Motion.lively) { distance = d }
        } label: {
            Text(d.label)
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                .foregroundStyle(on ? .white : Theme.ink)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                .background {
                    Capsule().fill(on ? AnyShapeStyle(Theme.purple) : AnyShapeStyle(Theme.background))
                    if !on { Capsule().stroke(Theme.hairline) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: Lock-in

    /// The pinned commitment: full-width ink, the race named on the button — one considered tap.
    private func lockInBar(for race: RaceCatalog.Race, date: Date) -> some View {
        VStack(spacing: Theme.Space.xs) {
            Button {
                Haptics.success()
                onPick(race, distance, date)
                dismiss()
            } label: {
                Text("Lock in \(race.name)")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(Theme.background)
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous), tone: .ink)
            }
            .buttonStyle(.plain)
            Text("\(distance.label) · \(date.formatted(.dateTime.month(.abbreviated).day().year()))")
                .font(.rounded(Theme.FontSize.label, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.xs)
        .background(.ultraThinMaterial)
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
