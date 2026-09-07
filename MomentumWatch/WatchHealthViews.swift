import SwiftUI

// The wrist's health surfaces (2026-09-06): three home cards and three detail pages, every number
// from `WatchHealthStore.snapshot` — the phone's own readiness recipe, never recomputed here.
// Black canvas, white ink, one quiet colour per signal (sleep · HRV · heart · strain); the
// iridescent stroke stays reserved for a primed morning and a completed week, the way it is on
// the phone. Every numeral is tabular; every card carries a VoiceOver sentence.

// MARK: - Home cards

/// The morning in one glance: the ring, the word, and the line that says why.
struct WatchReadinessCard: View {
    let snapshot: WristHealthSnapshot

    var body: some View {
        NavigationLink(value: WatchDestination.readiness) {
            HStack(spacing: 11) {
                if let r = snapshot.readiness {
                    WatchReadinessRing(score: r.score, band: r.band, lineWidth: 4)
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 1) {
                        WatchStaleTag(snapshot: snapshot)
                        Text(r.word)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(WatchTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(WatchHealthFormat.driverPhrase(r.driver))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WatchTheme.inkTertiary)
                            .lineLimit(2)
                    }
                } else {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(WatchTheme.inkSecondary)
                        .frame(width: 46, height: 46)
                    Text("Readiness arrives with your first night of data.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WatchTheme.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchCardShape())
        }
        .listRowBackground(Color.clear)
        .accessibilityLabel(snapshot.readiness.map { "Readiness \($0.score) out of 100, \($0.word). \($0.driver)" }
                            ?? "Readiness arrives with your first night of data")
    }
}

/// Last night against the athlete's own norms: sleep, HRV, resting heart rate.
struct WatchVitalsCard: View {
    let snapshot: WristHealthSnapshot

    var body: some View {
        NavigationLink(value: WatchDestination.vitals) {
            HStack(spacing: 0) {
                column("SLEEP", value: snapshot.sleep.map { WatchHealthFormat.hoursShort($0.asleepH) } ?? "—",
                       tint: WatchTheme.sleep, trend: nil, good: true)
                divider
                column("HRV", value: snapshot.hrv.map { "\(Int($0.value.rounded()))" } ?? "—",
                       tint: WatchTheme.hrv, trend: snapshot.hrv?.trend, good: snapshot.hrv?.trend != "down")
                divider
                column("REST HR", value: snapshot.restingHR.map { "\(Int($0.value.rounded()))" } ?? "—",
                       tint: WatchTheme.heart, trend: snapshot.restingHR?.trend, good: snapshot.restingHR?.trend != "up")
            }
            .padding(.vertical, 9).padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(WatchCardShape())
        }
        .listRowBackground(Color.clear)
        .accessibilityLabel(vitalsSentence)
    }

    private var divider: some View {
        Rectangle().fill(WatchTheme.surfaceStrong).frame(width: 1, height: 26)
    }

    private func column(_ title: String, value: String, tint: Color, trend: String?, good: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(tint)
            HStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(WatchTheme.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if let glyph = WatchHealthFormat.trendGlyph(trend) {
                    Image(systemName: glyph)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(good ? WatchTheme.hrv : WatchTheme.heart)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var vitalsSentence: String {
        var parts: [String] = []
        if let s = snapshot.sleep { parts.append("Sleep \(WatchHealthFormat.hoursLong(s.asleepH))") }
        if let h = snapshot.hrv { parts.append("HRV \(Int(h.value.rounded())) milliseconds\(WatchHealthFormat.trendWord(h.trend))") }
        if let r = snapshot.restingHR { parts.append("resting heart rate \(Int(r.value.rounded()))\(WatchHealthFormat.trendWord(r.trend))") }
        return parts.isEmpty ? "No overnight vitals yet" : parts.joined(separator: ", ")
    }
}

/// Today's strain so far beside the week's training.
struct WatchStrainCard: View {
    let snapshot: WristHealthSnapshot

    var body: some View {
        NavigationLink(value: WatchDestination.strain) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STRAIN")
                        .font(.system(size: 9, weight: .bold)).tracking(0.8)
                        .foregroundStyle(WatchTheme.energy)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(snapshot.strain.map { "\($0.score)" } ?? "—")
                            .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(WatchTheme.ink)
                        Text(snapshot.strain?.band ?? "Today")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WatchTheme.inkSecondary)
                    }
                    WatchBar(progress: Double(snapshot.strain?.score ?? 0) / 100, tint: WatchTheme.energy)
                        .frame(height: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let t = snapshot.training, t.weekPlannedM > 0 || t.totalSessions > 0 {
                    WatchWeekRing(training: t, lineWidth: 4)
                        .frame(width: 40, height: 40)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchCardShape())
        }
        .listRowBackground(Color.clear)
        .accessibilityLabel(strainSentence)
    }

    private var strainSentence: String {
        var s = snapshot.strain.map { "Strain \($0.score) out of 100, \($0.band)" } ?? "No strain yet today"
        if let t = snapshot.training, t.weekPlannedM > 0 {
            s += ". This week \(WatchHealthFormat.distance(t.weekDoneM)) of \(WatchHealthFormat.distance(t.weekPlannedM))"
        }
        return s
    }
}

/// The honest empty card: why there is nothing yet, and what fills it.
struct WatchHealthEmptyCard: View {
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 12, weight: .semibold))
                Text("HEALTH")
                    .font(.system(size: 10, weight: .bold)).tracking(1.1)
            }
            .foregroundStyle(WatchTheme.inkSecondary)
            Text(line)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WatchTheme.ink)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WatchCardShape())
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}

/// "Yesterday" beside a number from another day — never a blank, never a lie.
struct WatchStaleTag: View {
    let snapshot: WristHealthSnapshot

    var body: some View {
        if !snapshot.isForToday() {
            Text(WatchHealthFormat.relativeDay(snapshot.dayKey))
                .font(.system(size: 9, weight: .bold)).tracking(0.4)
                .foregroundStyle(WatchTheme.inkTertiary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(WatchTheme.surfaceStrong))
        }
    }
}

// MARK: - Readiness detail

struct WatchReadinessDetailView: View {
    private let store = WatchHealthStore.shared

    var body: some View {
        ScrollView {
            if let s = store.current, let r = s.readiness {
                VStack(spacing: 10) {
                    WatchReadinessRing(score: r.score, band: r.band, lineWidth: 6)
                        .frame(width: 88, height: 88)
                        .padding(.top, 2)
                    VStack(spacing: 3) {
                        Text(r.word)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(WatchTheme.ink)
                        WatchStaleTag(snapshot: s)
                        Text(r.guidance)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WatchTheme.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 6) {
                        ForEach(r.pillars.sorted { abs($0.points) > abs($1.points) }) { p in
                            WatchPillarRow(title: p.title, detail: p.detail, points: p.points)
                        }
                        ForEach(r.modifiers) { m in
                            WatchPillarRow(title: m.title, detail: m.detail, points: m.points)
                        }
                    }
                    .padding(.top, 2)
                    Text(WatchHealthFormat.confidenceLine(r.confidence, signals: r.pillars.count))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(WatchTheme.inkTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 2)
            } else {
                WatchHealthEmptyPage(line: store.current?.emptyLine
                                     ?? "Open momentum on iPhone once to bring your readiness here.")
            }
        }
        .navigationTitle { Text("Readiness").foregroundStyle(WatchTheme.ink) }
        .onAppear { store.requestRefreshIfStale() }
    }
}

/// One input to the score: what it read, and the points it moved.
struct WatchPillarRow: View {
    let title: String
    let detail: String
    let points: Double

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(WatchTheme.ink)
                Text(detail)
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(WatchTheme.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(WatchHealthFormat.points(points))
                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(points >= 0.5 ? WatchTheme.hrv : (points <= -0.5 ? WatchTheme.heart : WatchTheme.inkSecondary))
        }
        .padding(.vertical, 7).padding(.horizontal, 11)
        .background(WatchCardShape(radius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail), \(WatchHealthFormat.pointsSpoken(points))")
    }
}

// MARK: - Vitals pages

/// Sleep · HRV · Resting HR · Signals, one page each on the vertical pager (the Workout idiom).
struct WatchVitalsView: View {
    private let store = WatchHealthStore.shared
    @State private var page = WatchHealthDebug.initialPage(default: "sleep")

    var body: some View {
        Group {
            if let s = store.current, s.hasVitals {
                TabView(selection: $page) {
                    if let sleep = s.sleep { WatchSleepPage(sleep: sleep, snapshot: s).tag("sleep") }
                    if let hrv = s.hrv {
                        WatchVitalPage(title: "HRV", unit: "ms", vital: hrv, tint: WatchTheme.hrv,
                                       higherIsBetter: true, snapshot: s).tag("hrv")
                    }
                    if let rhr = s.restingHR {
                        WatchVitalPage(title: "Resting HR", unit: "bpm", vital: rhr, tint: WatchTheme.heart,
                                       higherIsBetter: false, snapshot: s).tag("rhr")
                    }
                    if s.respiratoryZ != nil || s.wristTempDeltaC != nil {
                        WatchSignalsPage(snapshot: s).tag("signals")
                    }
                }
                .tabViewStyle(.verticalPage)
            } else {
                ScrollView {
                    WatchHealthEmptyPage(line: store.current?.emptyLine
                                         ?? "Open momentum on iPhone once to bring last night here.")
                }
            }
        }
        .navigationTitle { Text("Vitals").foregroundStyle(WatchTheme.ink) }
        .onAppear { store.requestRefreshIfStale() }
    }
}

struct WatchSleepPage: View {
    let sleep: WristHealthSnapshot.Sleep
    let snapshot: WristHealthSnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchPageHeader(title: "SLEEP", tint: WatchTheme.sleep,
                                tag: WatchHealthFormat.relativeDay(sleep.nightDayKey, todayWord: "Last night"))
                HStack(spacing: 12) {
                    ZStack {
                        WatchRing(progress: sleep.needH > 0 ? sleep.asleepH / sleep.needH : 0,
                                  lineWidth: 6, tint: AnyShapeStyle(WatchTheme.sleep))
                        Image(systemName: "moon.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(WatchTheme.sleep)
                    }
                    .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WatchHealthFormat.hoursLong(sleep.asleepH))
                            .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(WatchTheme.ink)
                            .minimumScaleFactor(0.8)
                        Text("of \(WatchHealthFormat.hoursLong(sleep.needH)) · \(sleep.band)")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(WatchTheme.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                if sleep.efficiencyPct != nil || sleep.deepPct != nil || sleep.remPct != nil {
                    HStack(spacing: 0) {
                        stat("EFFIC.", sleep.efficiencyPct.map { "\(Int($0.rounded()))%" } ?? "—")
                        stat("DEEP", sleep.deepPct.map { "\(Int($0.rounded()))%" } ?? "—")
                        stat("REM", sleep.remPct.map { "\(Int($0.rounded()))%" } ?? "—")
                    }
                    .padding(.vertical, 6)
                    .background(WatchCardShape(radius: 14))
                }
                WatchBars(values: sleep.week, tint: WatchTheme.sleep, reference: sleep.needH)
                    .frame(height: 34)
                    .accessibilityLabel("Seven nights")
                if sleep.debt14H >= 0.5 {
                    Text("14-day debt \(WatchHealthFormat.hoursLong(sleep.debt14H))")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(WatchTheme.inkTertiary)
                }
                if let note = sleep.note {
                    Text(note)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WatchTheme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sleep \(WatchHealthFormat.hoursLong(sleep.asleepH)) of \(WatchHealthFormat.hoursLong(sleep.needH)) need, \(sleep.band)")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(WatchTheme.inkTertiary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(WatchTheme.ink)
        }
        .frame(maxWidth: .infinity)
    }
}

/// HRV or resting heart rate: the value, the norm, the arrow, the week, the note.
struct WatchVitalPage: View {
    let title: String
    let unit: String
    let vital: WristHealthSnapshot.Vital
    let tint: Color
    let higherIsBetter: Bool
    let snapshot: WristHealthSnapshot

    private var good: Bool {
        switch vital.trend {
        case "up": higherIsBetter
        case "down": !higherIsBetter
        default: true
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchPageHeader(title: title.uppercased(), tint: tint, tag: WatchHealthFormat.relativeDay(snapshot.dayKey, todayWord: "Overnight"))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(vital.value.rounded()))")
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(WatchTheme.ink)
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WatchTheme.inkSecondary)
                    if let glyph = WatchHealthFormat.trendGlyph(vital.trend) {
                        Image(systemName: glyph)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(good ? WatchTheme.hrv : WatchTheme.heart)
                    }
                    Spacer(minLength: 0)
                }
                if let base = vital.baseline {
                    Text("Your norm \(Int(base.rounded())) \(unit)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(WatchTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                WatchBars(values: vital.week, tint: tint, reference: vital.baseline)
                    .frame(height: 38)
                    .accessibilityLabel("Seven days")
                if let note = vital.note {
                    Text(note)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WatchTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) \(Int(vital.value.rounded())) \(unit)\(WatchHealthFormat.trendWord(vital.trend))")
    }
}

/// Breathing rate and wrist temperature: the two overnight signals that only ever subtract.
struct WatchSignalsPage: View {
    let snapshot: WristHealthSnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchPageHeader(title: "SIGNALS", tint: WatchTheme.inkSecondary, tag: nil)
                if let z = snapshot.respiratoryZ {
                    signal("Breathing rate", value: String(format: "%+.1f SD", z),
                           word: z >= 2 ? "Well above your norm" : (z >= 1 ? "A little above your norm" : "In your norm"),
                           flagged: z >= 1)
                }
                if let t = snapshot.wristTempDeltaC {
                    signal("Wrist temperature", value: String(format: "%+.1f °C", t),
                           word: t >= 0.5 ? "Above your norm" : (t >= 0.3 ? "Slightly above your norm" : "In your norm"),
                           flagged: t >= 0.3)
                }
                Text("Both are read against your own overnight norm. A raised night can be a hard day, a late meal, or the start of something. Never a diagnosis.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WatchTheme.inkTertiary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 2)
        }
    }

    private func signal(_ title: String, value: String, word: String, flagged: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(WatchTheme.ink)
                Text(word).font(.system(size: 10, weight: .medium)).foregroundStyle(WatchTheme.inkTertiary)
            }
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(flagged ? WatchTheme.energy : WatchTheme.inkSecondary)
        }
        .padding(.vertical, 7).padding(.horizontal, 11)
        .background(WatchCardShape(radius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value), \(word)")
    }
}

// MARK: - Strain and the week

struct WatchStrainView: View {
    private let store = WatchHealthStore.shared
    @State private var page = WatchHealthDebug.initialPage(default: "strain")

    var body: some View {
        Group {
            if let s = store.current, s.strain != nil || s.training != nil {
                TabView(selection: $page) {
                    if let strain = s.strain { WatchStrainPage(strain: strain, snapshot: s).tag("strain") }
                    if let t = s.training { WatchWeekPage(training: t).tag("week") }
                }
                .tabViewStyle(.verticalPage)
            } else {
                ScrollView {
                    WatchHealthEmptyPage(line: "Strain builds from today's sessions and steps. Start a run and it fills in.")
                }
            }
        }
        .navigationTitle { Text("Strain").foregroundStyle(WatchTheme.ink) }
        .onAppear { store.requestRefreshIfStale() }
    }
}

struct WatchStrainPage: View {
    let strain: WristHealthSnapshot.Strain
    let snapshot: WristHealthSnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchPageHeader(title: "STRAIN", tint: WatchTheme.energy, tag: "Today so far")
                HStack(spacing: 12) {
                    ZStack {
                        WatchRing(progress: Double(strain.score) / 100, lineWidth: 6,
                                  tint: AnyShapeStyle(WatchTheme.energy))
                        Text("\(strain.score)")
                            .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(WatchTheme.ink)
                    }
                    .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(strain.band)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(WatchTheme.ink)
                        Text("Workouts \(Int(strain.workoutLoad.rounded())) · Day \(Int(strain.ambientLoad.rounded()))")
                            .font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(WatchTheme.inkTertiary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                WatchBars(values: strain.week.map { $0.map(Double.init) }, tint: WatchTheme.energy, reference: nil, ceiling: 100)
                    .frame(height: 38)
                    .accessibilityLabel("Seven days of strain")
                Text(WatchHealthFormat.strainLine(strain, readiness: snapshot.readiness))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WatchTheme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Strain \(strain.score) out of 100, \(strain.band)")
    }
}

struct WatchWeekPage: View {
    let training: WristHealthSnapshot.Training

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchPageHeader(title: "THIS WEEK", tint: WatchTheme.accent, tag: nil)
                HStack(spacing: 12) {
                    WatchWeekRing(training: training, lineWidth: 6)
                        .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        if training.weekPlannedM > 0 {
                            Text(WatchHealthFormat.distance(training.weekDoneM))
                                .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(WatchTheme.ink)
                                .minimumScaleFactor(0.8)
                            Text("of \(WatchHealthFormat.distance(training.weekPlannedM)) planned")
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                                .foregroundStyle(WatchTheme.inkSecondary)
                        } else {
                            Text(WatchHealthFormat.distance(training.weekDoneM))
                                .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(WatchTheme.ink)
                            Text("so far this week")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(WatchTheme.inkSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    stat("SESSIONS", training.totalSessions > 0 ? "\(training.doneSessions)/\(training.totalSessions)" : "\(training.doneSessions)")
                    stat("STREAK", training.streakDays > 0 ? "\(training.streakDays)d" : "—")
                    stat("LOAD", training.loadWord ?? "—")
                }
                .padding(.vertical, 6)
                .background(WatchCardShape(radius: 14))
                if let line = training.loadLine {
                    Text(line)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WatchTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(weekSentence)
    }

    private var weekSentence: String {
        var s = "This week \(WatchHealthFormat.distance(training.weekDoneM))"
        if training.weekPlannedM > 0 { s += " of \(WatchHealthFormat.distance(training.weekPlannedM)) planned" }
        if training.totalSessions > 0 { s += ", \(training.doneSessions) of \(training.totalSessions) sessions" }
        if training.streakDays > 0 { s += ", \(training.streakDays) day streak" }
        return s
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(WatchTheme.inkTertiary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(WatchTheme.ink).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Components

struct WatchCardShape: View {
    var radius: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(WatchTheme.surface)
    }
}

struct WatchPageHeader: View {
    let title: String
    let tint: Color
    let tag: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold)).tracking(1.1)
                .foregroundStyle(tint)
            Spacer(minLength: 4)
            if let tag {
                Text(tag)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WatchTheme.inkTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        // The vertical page indicator lives on the right edge; keep the header clear of it.
        .padding(.trailing, 10)
    }
}

struct WatchHealthEmptyPage: View {
    let line: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(WatchTheme.inkSecondary)
                .padding(.top, 8)
            Text(line)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WatchTheme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 4)
    }
}

/// A progress ring: the fill never shows less than a hairline, so "0" still reads as a ring.
struct WatchRing: View {
    let progress: Double
    var lineWidth: CGFloat = 5
    var tint: AnyShapeStyle = AnyShapeStyle(WatchTheme.ink)

    var body: some View {
        ZStack {
            Circle().stroke(WatchTheme.surfaceStrong, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// The week's ring: distance banked against the plan (sessions when the week has no distance);
/// iridescent once the week is done — the earned accent, nowhere else.
struct WatchWeekRing: View {
    let training: WristHealthSnapshot.Training
    var lineWidth: CGFloat = 5

    private var progress: Double {
        if training.weekPlannedM > 0 { return training.weekDoneM / training.weekPlannedM }
        if training.totalSessions > 0 { return Double(training.doneSessions) / Double(training.totalSessions) }
        return 0
    }

    var body: some View {
        ZStack {
            WatchRing(progress: progress, lineWidth: lineWidth,
                      tint: progress >= 0.999 ? AnyShapeStyle(WatchTheme.iridescentAngular) : AnyShapeStyle(WatchTheme.accent))
            Text("\(Int((min(1, progress) * 100).rounded()))")
                .font(.system(size: lineWidth > 5 ? 15 : 11, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(WatchTheme.ink)
                .minimumScaleFactor(0.6)
                .padding(lineWidth + 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Week \(Int((min(1, progress) * 100).rounded())) percent complete")
    }
}

/// A flat progress bar.
struct WatchBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(WatchTheme.surfaceStrong)
                Capsule().fill(tint).frame(width: max(3, g.size.width * min(1, max(0, progress))))
            }
        }
    }
}

/// Seven bars, oldest first, today brightest; a missing day is a faint dot at the floor; the
/// reference (a norm, a need) draws as a hairline so the eye reads above/below at a glance.
struct WatchBars: View {
    let values: [Double?]
    let tint: Color
    var reference: Double?
    var ceiling: Double? = nil

    private var top: Double {
        let present = values.compactMap { $0 } + [reference].compactMap { $0 }
        if let ceiling { return ceiling }
        let m = present.max() ?? 1
        return m > 0 ? m * 1.1 : 1
    }

    var body: some View {
        GeometryReader { g in
            let count = max(1, values.count)
            let slot = g.size.width / CGFloat(count)
            let barWidth = min(7, slot * 0.5)
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                        let last = i == values.count - 1
                        Group {
                            if let v {
                                Capsule()
                                    .fill(tint.opacity(last ? 1 : 0.5))
                                    .frame(width: barWidth, height: max(barWidth, g.size.height * CGFloat(min(1, v / top))))
                            } else {
                                Circle().fill(WatchTheme.surfaceStrong).frame(width: 3, height: 3)
                            }
                        }
                        .frame(width: slot, alignment: .bottom)
                    }
                }
                if let reference, reference > 0, reference <= top {
                    Rectangle()
                        .fill(WatchTheme.ink.opacity(0.35))
                        .frame(height: 1)
                        .offset(y: -g.size.height * CGFloat(reference / top))
                }
            }
        }
    }
}

// MARK: - Words and numbers

enum WatchHealthFormat {
    static func hoursShort(_ h: Double) -> String {
        let total = Int((h * 60).rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    static func hoursLong(_ h: Double) -> String {
        let total = Int((h * 60).rounded())
        return "\(total / 60)h \(String(format: "%02d", total % 60))m"
    }

    /// One decimal and the unit, the way the Plan board's ledger reads ("15.1 mi", "24.3 km").
    static func distance(_ meters: Double) -> String {
        let unit = DistanceUnit.auto.resolved()
        let value = unit == .imperial ? meters / Formatters.metersPerMile : meters / 1000
        return "\(value.formatted(.number.precision(.fractionLength(1)))) \(unit == .imperial ? "mi" : "km")"
    }

    /// The card shows the mover ("Sleep did the work"); the confidence rides on the detail page.
    static func driverPhrase(_ driver: String) -> String {
        driver.components(separatedBy: " · ").first ?? driver
    }

    static func points(_ p: Double) -> String {
        let r = Int(p.rounded())
        return r > 0 ? "+\(r)" : (r < 0 ? "−\(abs(r))" : "0")
    }

    static func pointsSpoken(_ p: Double) -> String {
        let r = Int(p.rounded())
        return r > 0 ? "plus \(r)" : (r < 0 ? "minus \(abs(r))" : "no change")
    }

    static func trendGlyph(_ trend: String?) -> String? {
        switch trend {
        case "up": "arrow.up"
        case "down": "arrow.down"
        default: nil
        }
    }

    static func trendWord(_ trend: String?) -> String {
        switch trend {
        case "up": ", above your norm"
        case "down": ", below your norm"
        default: ""
        }
    }

    static func confidenceLine(_ confidence: String, signals: Int) -> String {
        let word: String = switch confidence {
        case "high": "High confidence"
        case "medium": "Fair confidence"
        case "low": "Low confidence"
        default: "Early read"
        }
        return "\(word) · \(signals) signal\(signals == 1 ? "" : "s")"
    }

    static func strainLine(_ strain: WristHealthSnapshot.Strain, readiness: WristHealthSnapshot.Readiness?) -> String {
        switch strain.band {
        case "Peak": return "A peak day. Tomorrow wants to be easy."
        case "Hard": return "A hard day banked. Sleep is where it pays off."
        case "Moderate": return "A solid day of work, well within you."
        default:
            if let r = readiness, r.band == "primed" || r.band == "ready" {
                return "Light so far, and you are recovered. Room for the session."
            }
            return "Light so far."
        }
    }

    /// "Yesterday" / "2 days ago" for a day key that is not today; `todayWord` for today.
    static func relativeDay(_ dayKey: String, todayWord: String = "Today", now: Date = Date(),
                            calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: dayKey) else { return todayWord }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return todayWord
        case 1: return "Yesterday"
        default: return "\(days) days ago"
        }
    }
}

/// Simulator-only: `--watch-page=<tag>` opens a pager on a given page so every page can be
/// captured by launch argument (taps and crown swipes are unreliable in the sandbox).
enum WatchHealthDebug {
    static func initialPage(default tag: String) -> String {
        #if DEBUG
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--watch-page=") }) {
            return String(arg.dropFirst("--watch-page=".count))
        }
        #endif
        return tag
    }
}
