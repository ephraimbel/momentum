import SwiftUI
import SwiftData

/// Open a planned session to review and adjust it (PRD §7.7) — the Plan page's editing surface. Check
/// it off, move it to another day, tune a cardio target, or remove it, all in the app's own language.
/// No-shame: completing earns an iridescent state; nothing is ever marked "failed".
struct SessionDetailSheet: View {
    @Bindable var session: PlannedSession
    var distanceUnit: DistanceUnit = .auto
    var profile: UserProfile? = nil
    var onRemove: () -> Void
    var onStart: (PlannedSession) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var rescheduling = false
    @State private var adjusting = false
    @State private var confirmRemove = false

    /// The structured-workout expansion, memoized per input change — `body` needed it in two
    /// places, and every distance-stepper tap re-rendered the whole sheet, so the builder was
    /// running two to three times per render (heavy-work-in-body rule). A plain reference box
    /// (fields unobserved), so filling it mid-body is invisible to SwiftUI.
    private final class StructuredMemo { var key = "\u{0}"; var value: StructuredWorkout? }
    @State private var structuredMemo = StructuredMemo()
    private var structured: StructuredWorkout? {
        let key = """
        \(session.runType?.rawValue ?? "-")|\(session.intervals ?? "-")|\
        \(session.targetDistanceM ?? -1)|\(session.targetDurationS ?? -1)|\
        \(session.targetPaceSPerKm ?? -1)|\(profile?.plan?.p5kSPerKm ?? -1)|\(profile?.raceDistanceM ?? -1)
        """
        if structuredMemo.key != key {
            structuredMemo.key = key
            structuredMemo.value = StructuredWorkoutBuilder.build(
                from: session, p5kSPerKm: profile?.plan?.p5kSPerKm,
                raceDistanceM: profile?.raceDistanceM)
        }
        return structuredMemo.value
    }

    /// Key off the precise sport when set (discipline buckets swim/row under running).
    private var isGPS: Bool { session.workoutType?.isGPS ?? (session.discipline != .strength) }
    private var isStrength: Bool { session.workoutType?.isStrengthStyle ?? (session.discipline == .strength) }
    private var done: Bool { session.status == .completed }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    statusChip
                    targets
                    if let caveat = racePaceCaveat { note(caveat) }
                    fuelSection
                    // The session's why — always, not only when it was moved. The engines write a
                    // rationale onto eased, deload, rebuild-week, and injury-converted sessions too,
                    // and "adaptation explained in plain words" means the athlete can read it HERE,
                    // where they actually look, not only in a buried timeline.
                    if let why = session.rationale, !why.isEmpty {
                        note(why)
                    }
                    if rescheduling { rescheduleStrip }
                    if adjusting, isGPS { distanceAdjuster }
                    actions
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.xxl)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .confirmationDialog("Remove this session?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Haptics.medium(); onRemove(); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(IridescentMaterial().opacity(0.5)) : AnyShapeStyle(Theme.surface))
                Circle().stroke(Theme.hairline)
                Image(systemName: PlanCoaching.icon(for: session)).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(PlanCoaching.brief(for: session, distanceUnit: distanceUnit))
                    .font(.display(22, weight: .black)).foregroundStyle(Theme.ink).lineLimit(2)
                Text(session.date.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: 34, height: 34).background(Circle().fill(Theme.surface)).contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
    }

    // MARK: Status

    private var statusChip: some View {
        let (text, icon): (String, String) = switch session.status {
        case .completed: ("Completed", "checkmark.circle.fill")
        case .moved: ("Moved", "arrow.turn.up.right")
        case .missed: ("Rolled forward", "arrow.turn.up.right")
        case .planned: ("Planned", "circle")
        }
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
            Text(text).font(.rounded(Theme.FontSize.caption, weight: .bold)).tracking(0.3)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
        .background {
            Capsule().fill(done ? AnyShapeStyle(IridescentMaterial().opacity(0.3)) : AnyShapeStyle(Theme.surface))
            Capsule().stroke(Theme.hairline)
        }
    }

    // MARK: Targets

    @ViewBuilder
    private var targets: some View {
        if isStrength {
            if !session.strengthTargets.isEmpty { exercisesSection }
        } else {
            let chips = cardioChips
            if !chips.isEmpty {
                section("Targets") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.sm) { ForEach(chips, id: \.self) { chip($0) } }
                    }
                }
            }
            // Guided quality sessions (intervals/tempo/run-walk) expand into a step breakdown so the
            // athlete sees the shape of the session before starting the guided run.
            if let workout = structured {
                structuredSection(workout)
            }
        }
    }

    /// A compact, grouped preview of a structured session — rep blocks collapse to one line
    /// ("6 × 400 m @ pace") with the recovery shown once, warm-up/cool-down as their own rows.
    private func structuredSection(_ w: StructuredWorkout) -> some View {
        section("Workout") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(Array(structuredLines(w).enumerated()), id: \.offset) { _, line in
                    HStack {
                        Text(line.label).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer(minLength: Theme.Space.sm)
                        Text(line.detail).font(.rounded(Theme.FontSize.caption, weight: .semibold))
                            .monospacedDigit().foregroundStyle(Theme.inkSecondary)
                    }
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.surface)
                        RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)
                    }
                }
            }
        }
    }

    /// Shared with Today's confirm sheet (`StructuredWorkout.summaryLines`) so the prescription
    /// reads identically on every surface.
    private func structuredLines(_ w: StructuredWorkout) -> [(label: String, detail: String)] {
        w.summaryLines(distanceUnit: distanceUnit)
    }

    /// "Race pace" work is priced at the athlete's *current predicted* pace, not the goal they
    /// typed — coaching-correct, but a silent mismatch reads as a bug to anyone chasing a time.
    /// One quiet sentence wherever race-pace reps appear turns that into a trust moment.
    private var racePaceCaveat: String? {
        let mentionsRacePace = session.intervals?.lowercased().contains("race") ?? false
        guard mentionsRacePace || session.runType == .race else { return nil }
        return "Race pace here is your current predicted pace — it moves with your fitness as training lands, so the plan always trains you where you are today."
    }

    private var exercisesSection: some View {
        section("Exercises") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(session.strengthTargets.sorted { $0.order < $1.order }, id: \.persistentModelID) { ex in
                    exerciseRow(ex)
                }
            }
        }
    }

    private var cardioChips: [String] {
        var out: [String] = []
        if let rt = session.runType { out.append(rt.rawValue.capitalized) }
        if let d = session.targetDistanceM, d > 0 { out.append(Formatters.distance(meters: d, unit: distanceUnit)) }
        if let p = session.targetPaceSPerKm, p > 0 { out.append("~\(Formatters.pace(secPerKm: p, unit: distanceUnit))") }
        if let dur = session.targetDurationS, dur > 0 { out.append(Formatters.duration(s: dur)) }
        // The HR anchor for the pace target (§10) — "Z2 · 128–141 bpm" when the athlete's zones are known.
        if let rt = session.runType,
           let hr = HRZones.target(for: rt, maxHR: profile?.maxHR, restingHR: profile?.restingHR) {
            out.append(hr)
        }
        // The raw intervals string ("6×400m @ 5K pace") is superseded by the grouped Workout section
        // for guided sessions; only show it as a chip when no structured breakdown will render.
        if let iv = session.intervals, structured == nil { out.append(iv) }
        return out
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.rounded(Theme.FontSize.body, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)
            }
    }

    private func exerciseRow(_ ex: PlannedExercise) -> some View {
        HStack {
            Text(ex.exercise?.name ?? "Exercise").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.sm)
            Text(ex.prescriptionText)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)
        }
    }

    private func note(_ text: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "info.circle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            Text(text).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Reschedule

    private var rescheduleStrip: some View {
        section("Move to") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(next14, id: \.self) { day in
                        let on = Calendar.current.isDate(day, inSameDayAs: session.date)
                        Button {
                            Haptics.selection()
                            PlanCoaching.reschedule(session, to: day, in: context)
                            withAnimation(.easeOut(duration: 0.2)) { rescheduling = false }
                        } label: {
                            VStack(spacing: 3) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                                Text(day.formatted(.dateTime.day())).font(.display(20, weight: .heavy)).monospacedDigit()
                            }
                            .foregroundStyle(on ? .white : Theme.ink)
                            .frame(width: 54, height: 66)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.purple : Theme.surface)
                                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(on ? Color.clear : Theme.hairline)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var next14: [Date] {
        let start = Calendar.current.startOfDay(for: Date())
        return (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: Distance adjuster (cardio)

    private var distanceAdjuster: some View {
        let km = (session.targetDistanceM ?? 5000) / 1000
        let imperial = distanceUnit.resolved() == .imperial
        let value = imperial ? km * 1000 / Formatters.metersPerMile : km
        return section("Distance") {
            HStack(spacing: Theme.Space.lg) {
                Spacer()
                stepButton("minus") { adjustDistance(by: -0.5) }
                VStack(spacing: 0) {
                    Text(value.formatted(.number.precision(.fractionLength(value == value.rounded() ? 0 : 1))))
                        .font(.display(38, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text((imperial ? "mi" : "km").uppercased())
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                }
                .frame(minWidth: 92)
                stepButton("plus") { adjustDistance(by: 0.5) }
                Spacer()
            }
            .animation(.snappy(duration: 0.2), value: session.targetDistanceM)
        }
    }

    private func adjustDistance(by deltaUnits: Double) {
        Haptics.light()
        let imperial = distanceUnit.resolved() == .imperial
        let perUnit = imperial ? Formatters.metersPerMile : 1000
        let current = session.targetDistanceM ?? 5000
        session.targetDistanceM = max(perUnit * 0.5, current + deltaUnits * perUnit)
        try? context.save()
    }

    private func stepButton(_ s: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: s).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 50, height: 50).background { Circle().fill(Theme.surface); Circle().stroke(Theme.hairline) }
        }.buttonStyle(.plain)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: Theme.Space.sm) {
            // Primary — do the workout now (when it isn't already done).
            if !done {
                Button { Haptics.medium(); onStart(session); dismiss() } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Theme.background)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
                }
                .buttonStyle(.plain)
            }

            // Check off / undo.
            Button {
                Haptics.success()
                withAnimation(Motion.standard) { PlanCoaching.setCompletion(session, done: !done, in: context) }
            } label: {
                Label(done ? "Mark not done" : "Mark done", systemImage: done ? "arrow.uturn.left" : "checkmark")
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(Theme.ink)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                        RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                    }
            }
            .buttonStyle(.plain)

            HStack(spacing: Theme.Space.sm) {
                secondary(rescheduling ? "Close" : "Move", systemImage: "calendar") {
                    withAnimation(.easeOut(duration: 0.2)) { rescheduling.toggle(); if rescheduling { adjusting = false } }
                }
                if isGPS {
                    secondary(adjusting ? "Close" : "Adjust", systemImage: "slider.horizontal.3") {
                        withAnimation(.easeOut(duration: 0.2)) { adjusting.toggle(); if adjusting { rescheduling = false } }
                    }
                }
            }

            Button(role: .destructive) { confirmRemove = true } label: {
                Label("Remove", systemImage: "trash")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundStyle(.red)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            }
            .buttonStyle(.plain)
        }
    }

    private func secondary(_ title: String, systemImage: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Label(title, systemImage: systemImage)
                .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            content()
        }
    }

    // MARK: Fuel (ENDURANCE-FOCUS §11) — long runs and races only; short runs stay silent

    @ViewBuilder
    private var fuelSection: some View {
        if session.discipline == .running, session.status == .planned,
           let dur = FuelingGuide.estimatedDurationS(distanceM: session.targetDistanceM,
                                                     paceSPerKm: session.targetPaceSPerKm,
                                                     durationS: session.targetDurationS) {
            let g = FuelingGuide.guidance(durationS: dur, isRace: session.runType == .race)
            if g.carbsPerHour != nil {
                section("Fuel") {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        HStack(spacing: Theme.Space.sm) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.purple)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Theme.purple.opacity(0.1)))
                            Text(g.headline).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        }
                        fuelRow("BEFORE", g.before)
                        fuelRow("DURING", g.during)
                        fuelRow("AFTER", g.after)
                        Text(FuelingGuide.Guidance.disclaimer)
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                    .padding(Theme.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
                }
            }
        }
    }

    private func fuelRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text(label).font(.rounded(9, weight: .black)).tracking(0.8).foregroundStyle(Theme.inkTertiary)
                .frame(width: 52, alignment: .leading).padding(.top, 3)
            Text(text).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
