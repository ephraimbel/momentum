import SwiftUI
import CoreLocation

// The template library's second wave (2026-08-27) — the designs Share Aura's two libraries
// offer, re-drawn in our grammar: Space Grotesk numerals, Inter labels, iridescence as the one
// earned accent, lavender only where it means something. Each template is its OWN composition
// (not a variant of another), which is what makes the picker read as a library and not a matrix.
//
// Photo templates take the same media/transform/edits contract as PhotoTrio; stickers are
// transparent and compact — they're exported as PNG with alpha and pasted over someone's story.

// MARK: - Shared bits

/// A stat's value split from its unit: "4.45 mi" → ("4.45", "mi"); "34:55" → ("34:55", nil).
private func splitUnit(_ value: String) -> (value: String, unit: String?) {
    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
    guard parts.count == 2, parts[0].first?.isNumber == true else { return (value, nil) }
    return (parts[0], parts[1])
}

/// Route coordinates, or nil when there's nothing worth drawing.
private func routeCoords(_ workout: Workout) -> [CLLocationCoordinate2D]? {
    guard let gps = workout.gps else { return nil }
    let coords = gps.routeCoordinates(type: workout.type)
    return coords.count > 1 ? coords : nil
}

private func weekday(_ d: Date) -> String { d.formatted(.dateTime.weekday(.wide)).uppercased() }
private func monthDay(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()).uppercased() }
private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened).uppercased() }

// MARK: - Photo · Corner  (Aura's default: one small stat block, bottom-left, out of the way)

struct PhotoMinimalCard: View {
    let workout: Workout
    let stats: ShareStats
    let media: ShareMedia?
    let size: CGSize
    var transform: MediaTransform = .identity
    var mediaAspect: CGFloat = 1
    var overlayScale: CGFloat = 1
    var mediaHidden: Bool = false
    var voice: ShareStatVoice = .grotesk
    var edits: ShareEdits = ShareEdits()

    var body: some View {
        let ink = edits.ink.color
        ZStack(alignment: .bottomLeading) {
            ShareBackdrop(media: media, transform: transform, aspect: mediaAspect, size: size, hidden: mediaHidden)
            if edits.ink != .ink {
                LinearGradient(stops: [.init(color: .clear, location: 0.6),
                                       .init(color: .black.opacity(0.5), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: size.height * 0.012) {
                if edits.showTitle {
                    Text(edits.resolvedSubtitle(for: workout))
                        .font(.rounded(size.width * 0.026, weight: .semibold)).tracking(1)
                        .foregroundStyle(ink.opacity(0.8))
                    Text(edits.resolvedTitle(for: workout))
                        .font(.display(size.width * 0.05, weight: .bold))
                        .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.7)
                }
                if edits.showStats {
                    HStack(alignment: .firstTextBaseline, spacing: size.width * 0.05) {
                        ForEach(stats.rows.indices, id: \.self) { i in
                            let s = splitUnit(stats.rows[i].value)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(s.value).font(.display(size.width * 0.048, weight: .heavy)).monospacedDigit()
                                if let u = s.unit {
                                    Text(u).font(.rounded(size.width * 0.024, weight: .semibold))
                                        .baselineOffset(size.width * 0.02)
                                }
                            }
                            .foregroundStyle(ink)
                        }
                    }
                }
                if edits.showWordmark {
                    Text("momentum").font(.display(size.width * 0.032, weight: .bold))
                        .foregroundStyle(ink.opacity(0.7)).padding(.top, size.height * 0.004)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: size.width * 0.008, y: 1)
            .padding(size.width * 0.07)
            .padding(.bottom, size.height * 0.03)
            .scaleEffect(overlayScale, anchor: .bottomLeading)
            if edits.showRoute, let coords = routeCoords(workout) {
                ShareRoute(coords: coords, lineWidth: size.width * 0.009, casing: edits.ink.routeCasing)
                    .frame(width: size.width * 0.26, height: size.width * 0.26)
                    .padding(size.width * 0.07)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .scaleEffect(overlayScale, anchor: .topTrailing)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Photo · Hero  (the hero number owns the card)

struct PhotoBigCard: View {
    let workout: Workout
    let stats: ShareStats
    let media: ShareMedia?
    let size: CGSize
    var transform: MediaTransform = .identity
    var mediaAspect: CGFloat = 1
    var overlayScale: CGFloat = 1
    var mediaHidden: Bool = false
    var edits: ShareEdits = ShareEdits()

    var body: some View {
        let ink = edits.ink.color
        let hero = splitUnit(stats.rows.first?.value ?? "")
        ZStack {
            ShareBackdrop(media: media, transform: transform, aspect: mediaAspect, size: size, hidden: mediaHidden)
            if edits.ink != .ink { Color.black.opacity(0.22) }
            VStack(spacing: size.height * 0.01) {
                Spacer(minLength: 0)
                if edits.showTitle {
                    Text(edits.resolvedTitle(for: workout).uppercased())
                        .font(.rounded(size.width * 0.03, weight: .bold)).tracking(3)
                        .foregroundStyle(ink.opacity(0.85))
                }
                HStack(alignment: .firstTextBaseline, spacing: size.width * 0.01) {
                    Text(hero.value).font(.display(size.width * 0.26, weight: .black)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if let u = hero.unit {
                        Text(u.uppercased()).font(.display(size.width * 0.07, weight: .bold))
                            .baselineOffset(size.width * 0.13)
                    }
                }
                .foregroundStyle(ink)
                if edits.showStats, stats.rows.count > 1 {
                    HStack(spacing: size.width * 0.04) {
                        ForEach(stats.rows.dropFirst().indices, id: \.self) { i in
                            Text(stats.rows[i].value)
                                .font(.rounded(size.width * 0.036, weight: .semibold)).monospacedDigit()
                            if i < stats.rows.count - 1 { Circle().frame(width: 4, height: 4) }
                        }
                    }
                    .foregroundStyle(ink.opacity(0.85))
                }
                Spacer(minLength: 0)
                if edits.showWordmark {
                    Text("momentum").font(.display(size.width * 0.045, weight: .bold))
                        .foregroundStyle(ink.opacity(0.85)).padding(.bottom, size.height * 0.08)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: size.width * 0.01, y: 1)
            .scaleEffect(overlayScale)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Card · Splits  (the mile-by-mile ledger — the thing runners actually screenshot)

struct SplitsCard: View {
    let workout: Workout
    let stats: ShareStats
    let size: CGSize
    var distanceUnit: DistanceUnit = .auto
    var edits: ShareEdits = ShareEdits()

    private var pad: CGFloat { size.width * 0.09 }
    private var unit: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }

    /// One row of the ledger, from either source.
    private struct SplitLine { let index: Int; let distanceM: Double; let durationS: Double; let elevDeltaM: Double?; let isPartial: Bool }

    /// Persisted splits when the recorder wrote them; otherwise derived from the route the same
    /// way the post-run charts do (`CardioMetrics.splits` over `routePoints`), so an older run with
    /// a stored trace still gets a real table instead of "no splits".
    private var rows: [SplitLine] {
        guard let gps = workout.gps else { return [] }
        let stored = gps.splits.sorted { $0.index < $1.index }
        if !stored.isEmpty {
            return stored.map { SplitLine(index: $0.index, distanceM: $0.distanceM, durationS: $0.durationS,
                                          elevDeltaM: $0.elevDeltaM, isPartial: $0.isPartial) }
        }
        let unitM = distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000.0
        let pts = gps.routePoints(type: workout.type).map { CardioMetrics.SamplePoint(t: $0.t, cumulativeM: $0.cumulativeM) }
        return CardioMetrics.splits(pts, unitMeters: unitM).map {
            SplitLine(index: $0.index, distanceM: $0.distanceM, durationS: $0.durationS, elevDeltaM: nil, isPartial: $0.isPartial)
        }
    }

    var body: some View {
        ZStack {
            Color.black
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(edits.resolvedTitle(for: workout).uppercased()).tracking(3)
                    Spacer()
                    Text(edits.resolvedSubtitle(for: workout).uppercased()).tracking(1.5)
                }
                .font(.rounded(size.width * 0.028, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

                Spacer(minLength: 0)
                Text("SPLITS").font(.rounded(size.width * 0.03, weight: .bold)).tracking(3)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, size.height * 0.015)
                if rows.isEmpty {
                    Text("No splits for this one.")
                        .font(.rounded(size.width * 0.04, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                } else {
                    // Up to 12 rows, then the card is a story not a spreadsheet.
                    let shown = Array(rows.prefix(12))
                    let fastest = shown.filter { !$0.isPartial && $0.distanceM > 0 }
                        .min { $0.durationS / $0.distanceM < $1.durationS / $1.distanceM }?.index
                    ForEach(shown, id: \.index) { s in
                        let km = s.distanceM / 1000
                        let pace = km > 0 ? Formatters.pace(secPerKm: s.durationS / km, unit: distanceUnit) : "–"
                        HStack(alignment: .firstTextBaseline) {
                            Text(s.isPartial ? "\(s.index + 1)*" : "\(s.index + 1)")
                                .font(.display(size.width * 0.045, weight: .heavy)).monospacedDigit()
                                .frame(width: size.width * 0.12, alignment: .leading)
                            // The bar: pace relative to the fastest — the one earned accent on
                            // the fastest split.
                            Spacer()
                            Text(pace).font(.display(size.width * 0.05, weight: .bold)).monospacedDigit()
                            if let elev = s.elevDeltaM, elev != 0 {
                                Text(String(format: "%+.0f", distanceUnit.resolved() == .imperial ? elev * 3.28084 : elev))
                                    .font(.rounded(size.width * 0.028, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: size.width * 0.13, alignment: .trailing)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, size.height * 0.008)
                        .overlay(alignment: .bottom) {
                            if s.index == fastest {
                                IridescentView(intensity: 0.9, isStatic: true)
                                    .frame(height: size.height * 0.004).clipShape(Capsule())
                            } else {
                                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline) {
                    ForEach(stats.rows.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stats.rows[i].label.uppercased()).font(.rounded(size.width * 0.024, weight: .semibold)).tracking(1.5)
                                .foregroundStyle(.white.opacity(0.5))
                            Text(stats.rows[i].value).font(.display(size.width * 0.05, weight: .bold)).monospacedDigit()
                                .foregroundStyle(.white)
                        }
                        if i < stats.rows.count - 1 { Spacer() }
                    }
                }
                if edits.showWordmark {
                    Text("momentum").font(.display(size.width * 0.045, weight: .bold))
                        .foregroundStyle(.white).padding(.top, size.height * 0.03)
                }
            }
            .padding(pad)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Card · Week  (this week so far — the ring's numbers as type)

struct WeekCard: View {
    let workout: Workout
    let stats: ShareStats
    let size: CGSize
    var distanceUnit: DistanceUnit = .auto
    /// nil when there's no honest target (no plan, no declared volume): the card then shows the
    /// week's distance alone rather than inventing a denominator.
    var reading: WeekRing.Reading?
    var edits: ShareEdits = ShareEdits()

    private var pad: CGFloat { size.width * 0.09 }

    var body: some View {
        ZStack {
            Color.white
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("THIS WEEK").tracking(3)
                    Spacer()
                    Text(weekday(workout.startedAt)).tracking(1.5)
                }
                .font(.rounded(size.width * 0.028, weight: .semibold))
                .foregroundStyle(.black.opacity(0.45))
                Spacer(minLength: 0)
                let completed = reading?.completedM ?? (workout.gps?.distanceM ?? 0)
                let dist = splitUnit(Formatters.distance(meters: completed, unit: distanceUnit))
                HStack(alignment: .firstTextBaseline, spacing: size.width * 0.01) {
                    Text(dist.value).font(.display(size.width * 0.2, weight: .black)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if let u = dist.unit {
                        Text(u).font(.display(size.width * 0.06, weight: .bold)).baselineOffset(size.width * 0.1)
                    }
                }
                .foregroundStyle(.black)
                if let r = reading {
                    let pct = Int((r.to * 100).rounded())
                    Text("\(pct)% of \(Formatters.distance(meters: r.targetM, unit: distanceUnit)) this week")
                        .font(.rounded(size.width * 0.036, weight: .medium)).foregroundStyle(.black.opacity(0.6))
                    // The ring's sweep as a bar — iridescent for the part this session added.
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.black.opacity(0.08))
                            Capsule().fill(.black).frame(width: g.size.width * min(1, r.from))
                            IridescentView(intensity: 0.95, isStatic: true)
                                .mask(alignment: .leading) {
                                    Capsule().frame(width: g.size.width * min(1, r.to))
                                }
                                .mask(alignment: .leading) {
                                    HStack(spacing: 0) {
                                        Color.clear.frame(width: g.size.width * min(1, r.from))
                                        Rectangle()
                                    }
                                }
                        }
                    }
                    .frame(height: size.height * 0.012)
                    .padding(.top, size.height * 0.02)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY").font(.rounded(size.width * 0.024, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(.black.opacity(0.45))
                    Text(stats.rows.map(\.value).joined(separator: "  ·  "))
                        .font(.display(size.width * 0.042, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.black).lineLimit(1).minimumScaleFactor(0.7)
                }
                if edits.showWordmark {
                    Text("momentum").font(.display(size.width * 0.045, weight: .bold))
                        .foregroundStyle(.black).padding(.top, size.height * 0.03)
                }
            }
            .padding(pad)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Card · Ticket  (date · time · the numbers, set like a receipt)

struct TicketCard: View {
    let workout: Workout
    let stats: ShareStats
    let size: CGSize
    var edits: ShareEdits = ShareEdits()

    private var pad: CGFloat { size.width * 0.1 }

    var body: some View {
        ZStack {
            Color(hex: "F3F1EC")
            VStack(alignment: .leading, spacing: size.height * 0.006) {
                Text(weekday(workout.startedAt)).font(.display(size.width * 0.09, weight: .black))
                Text(monthDay(workout.startedAt)).font(.display(size.width * 0.09, weight: .black))
                Text(clock(workout.startedAt)).font(.display(size.width * 0.09, weight: .black))
                Rectangle().fill(.black.opacity(0.15)).frame(height: 2).padding(.vertical, size.height * 0.025)
                ForEach(stats.rows.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline) {
                        Text(stats.rows[i].label.uppercased()).font(.rounded(size.width * 0.03, weight: .semibold)).tracking(2)
                            .foregroundStyle(.black.opacity(0.5))
                        Spacer()
                        Text(stats.rows[i].value).font(.display(size.width * 0.06, weight: .bold)).monospacedDigit()
                    }
                }
                if edits.showTitle {
                    Text(edits.resolvedTitle(for: workout).uppercased())
                        .font(.rounded(size.width * 0.03, weight: .semibold)).tracking(2)
                        .foregroundStyle(.black.opacity(0.5)).padding(.top, size.height * 0.02)
                }
                Spacer(minLength: 0)
                if edits.showWordmark {
                    Text("momentum").font(.display(size.width * 0.045, weight: .bold))
                }
            }
            .foregroundStyle(.black)
            .padding(pad)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Stickers

/// The compact stat line every sticker builds on: "4.45 mi, 7:51 /mi".
private func stickerLine(_ stats: ShareStats) -> String {
    stats.rows.prefix(2).map(\.value).joined(separator: ", ")
}

/// Centres a sticker in the export frame; the frame itself is transparent.
private struct StickerFrame<Content: View>: View {
    let size: CGSize
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack { Color.clear; content() }
            .frame(width: size.width, height: size.height)
    }
}

struct BubbleSticker: View {
    let workout: Workout; let stats: ShareStats; let size: CGSize
    var edits: ShareEdits = ShareEdits()
    var body: some View {
        StickerFrame(size: size) {
            VStack(alignment: .trailing, spacing: size.height * 0.008) {
                Text(stickerLine(stats))
                    .font(.rounded(size.width * 0.05, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, size.width * 0.045).padding(.vertical, size.width * 0.028)
                    .background(RoundedRectangle(cornerRadius: size.width * 0.05, style: .continuous)
                        .fill(edits.ink == .lavender ? Theme.proLavender : Theme.inkOnFixedLight))
                Text("\(workout.type.title) \(clock(workout.startedAt).lowercased())")
                    .font(.rounded(size.width * 0.026, weight: .medium)).foregroundStyle(edits.ink.color.opacity(0.85))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
        }
    }
}

struct VerifiedSticker: View {
    let workout: Workout; let stats: ShareStats; let size: CGSize
    var edits: ShareEdits = ShareEdits()
    var body: some View {
        let d = splitUnit(stats.rows.first?.value ?? "")
        StickerFrame(size: size) {
            HStack(spacing: size.width * 0.02) {
                Text("\(d.value) \(d.unit == "mi" ? "miles" : (d.unit ?? ""))")
                    .font(.rounded(size.width * 0.055, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.black)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: size.width * 0.05, weight: .semibold))
                    .foregroundStyle(Theme.proLavender)
            }
            .padding(.horizontal, size.width * 0.05).padding(.vertical, size.width * 0.03)
            .background(Capsule().fill(.white))
            .shadow(color: .black.opacity(0.2), radius: size.width * 0.01, y: 2)
        }
    }
}

struct HeartSticker: View {
    let workout: Workout; let stats: ShareStats; let size: CGSize
    var edits: ShareEdits = ShareEdits()
    var body: some View {
        StickerFrame(size: size) {
            HStack(spacing: size.width * 0.02) {
                Image(systemName: "heart.fill").font(.system(size: size.width * 0.045, weight: .bold))
                Text(stats.rows.first?.value ?? "")
                    .font(.rounded(size.width * 0.055, weight: .bold)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, size.width * 0.05).padding(.vertical, size.width * 0.03)
            .background(Capsule().fill(Theme.like))
            .shadow(color: .black.opacity(0.2), radius: size.width * 0.01, y: 2)
        }
    }
}

struct HighlighterSticker: View {
    let workout: Workout; let stats: ShareStats; let size: CGSize
    var edits: ShareEdits = ShareEdits()
    var body: some View {
        StickerFrame(size: size) {
            Text(stickerLine(stats))
                .font(.rounded(size.width * 0.06, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.black)
                .padding(.horizontal, size.width * 0.02).padding(.vertical, size.width * 0.008)
                .background {
                    // The marker stroke — lavender on white type is the one place the accent
                    // may be a fill, because the athlete literally highlighted it.
                    Rectangle().fill(edits.ink == .lavender ? Theme.proLavender.opacity(0.85) : Color(hex: "FFE566"))
                        .rotationEffect(.degrees(-1.2))
                }
        }
    }
}

struct SentenceSticker: View {
    let workout: Workout; let stats: ShareStats; let size: CGSize
    var edits: ShareEdits = ShareEdits()

    /// Built as one AttributedString — a chain of `Text +` operators is exactly the expression
    /// the type-checker gives up on.
    private var sentence: AttributedString {
        let dist = stats.rows.first?.value ?? ""
        let time = stats.rows.count > 2 ? stats.rows[2].value : (stats.rows.last?.value ?? "")
        let pace = stats.rows.count > 1 ? stats.rows[1].value : ""
        func bold(_ t: String) -> AttributedString {
            var a = AttributedString(t); a.inlinePresentationIntent = .stronglyEmphasized; return a
        }
        var out = bold(dist)
        out += AttributedString(" \(workout.type.title.lowercased()) in ")
        out += bold(time)
        if pace.isEmpty { out += AttributedString(".") }
        else { out += AttributedString(", at "); out += bold(pace); out += AttributedString(" pace.") }
        return out
    }

    var body: some View {
        StickerFrame(size: size) {
            Text(sentence)
                .font(.rounded(size.width * 0.045, weight: .regular))
                .foregroundStyle(.black)
                .multilineTextAlignment(.leading)
                .padding(size.width * 0.05)
                .frame(width: size.width * 0.8, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: size.width * 0.01).fill(.white))
                .shadow(color: .black.opacity(0.15), radius: size.width * 0.01, y: 2)
        }
    }
}

struct SerifLineSticker: View {
    let workout: Workout; let stats: ShareStats; let size: CGSize
    var edits: ShareEdits = ShareEdits()
    var body: some View {
        // "Four miles." — the number as a word, the way a race report reads. Our display face, not
        // a serif: we stay Space Grotesk on brand (owner call 2026-08-25).
        let d = splitUnit(stats.rows.first?.value ?? "")
        let n = Double(d.value) ?? 0
        let word = NumberFormatter.localizedString(from: NSNumber(value: Int(n.rounded())), number: .spellOut)
        let unitWord = d.unit == "mi" ? "miles" : d.unit == "km" ? "kilometres" : (d.unit ?? "")
        StickerFrame(size: size) {
            Text("\(word.prefix(1).uppercased() + word.dropFirst()) \(unitWord).")
                .font(.display(size.width * 0.075, weight: .bold))
                .foregroundStyle(edits.ink.color)
                .shadow(color: .black.opacity(0.35), radius: size.width * 0.008, y: 1)
                .multilineTextAlignment(.center)
                .padding(.horizontal, size.width * 0.1)
        }
    }
}

struct DateStackSticker: View {
    let workout: Workout; let stats: ShareStats; let size: CGSize
    var edits: ShareEdits = ShareEdits()
    var body: some View {
        StickerFrame(size: size) {
            HStack(alignment: .top, spacing: size.width * 0.08) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(weekday(workout.startedAt)); Text(monthDay(workout.startedAt)); Text(clock(workout.startedAt))
                }
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(stats.rows.indices, id: \.self) { i in Text(stats.rows[i].value.uppercased()).monospacedDigit() }
                }
            }
            .font(.display(size.width * 0.038, weight: .bold))
            .foregroundStyle(edits.ink.color)
            .shadow(color: .black.opacity(0.35), radius: size.width * 0.008, y: 1)
        }
    }
}

struct CondensedSticker: View {
    let workout: Workout; let stats: ShareStats; let size: CGSize
    var edits: ShareEdits = ShareEdits()
    var body: some View {
        StickerFrame(size: size) {
            VStack(spacing: size.height * 0.004) {
                Text((stats.rows.first?.value ?? "").uppercased())
                    .font(.display(size.width * 0.14, weight: .black)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(stats.rows.dropFirst().map(\.value).joined(separator: "   ").uppercased())
                    .font(.display(size.width * 0.04, weight: .bold)).monospacedDigit()
            }
            // Aura's is red; ours is the brand lavender — the loud template earns the accent.
            .foregroundStyle(edits.ink == .white ? Theme.proLavender : edits.ink.color)
            .shadow(color: .black.opacity(0.35), radius: size.width * 0.008, y: 1)
            .padding(.horizontal, size.width * 0.06)
        }
    }
}
