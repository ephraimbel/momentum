import SwiftUI
import SwiftData

/// Open a planned session to review and adjust it (PRD §7.7) — the Plan page's editing surface. Check
/// it off, move it to another day, tune a cardio target, or remove it, all in the app's own language.
/// No-shame: completing earns an iridescent state; nothing is ever marked "failed".
struct SessionDetailSheet: View {
    @Bindable var session: PlannedSession
    var distanceUnit: DistanceUnit = .auto
    var onRemove: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var rescheduling = false
    @State private var adjusting = false
    @State private var confirmRemove = false

    private var isCardio: Bool { session.discipline != .strength }
    private var done: Bool { session.status == .completed }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    statusChip
                    targets
                    if let why = session.rationale, session.status == .moved {
                        note(why)
                    }
                    if rescheduling { rescheduleStrip }
                    if adjusting, isCardio { distanceAdjuster }
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
            Button("Remove", role: .destructive) { onRemove(); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(IridescentMaterial().opacity(0.5)) : AnyShapeStyle(Theme.surface))
                Circle().stroke(Theme.hairline)
                Image(systemName: disciplineIcon).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
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
        if isCardio {
            let chips = cardioChips
            if !chips.isEmpty {
                section("Targets") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.sm) { ForEach(chips, id: \.self) { chip($0) } }
                    }
                }
            }
        } else if !session.strengthTargets.isEmpty {
            section("Exercises") {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(session.strengthTargets.sorted { $0.order < $1.order }, id: \.persistentModelID) { ex in
                        exerciseRow(ex)
                    }
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
        if let iv = session.intervals { out.append(iv) }
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
            Spacer()
            Text("\(ex.targetSets) × \(ex.targetRepLow)–\(ex.targetRepHigh)")
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
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .frame(width: 54, height: 66)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.ink : Theme.surface)
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
            // Primary — check off / undo.
            Button {
                Haptics.success()
                withAnimation(Motion.standard) { PlanCoaching.setCompletion(session, done: !done, in: context) }
            } label: {
                Label(done ? "Mark not done" : "Mark done", systemImage: done ? "arrow.uturn.left" : "checkmark")
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(done ? Theme.ink : Theme.background)
                    .background {
                        if done {
                            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                        } else {
                            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink)
                        }
                    }
            }
            .buttonStyle(.plain)

            HStack(spacing: Theme.Space.sm) {
                secondary(rescheduling ? "Close" : "Move", systemImage: "calendar") {
                    withAnimation(.easeOut(duration: 0.2)) { rescheduling.toggle(); if rescheduling { adjusting = false } }
                }
                if isCardio {
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

    private var disciplineIcon: String {
        switch session.discipline {
        case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill"
        }
    }
}
