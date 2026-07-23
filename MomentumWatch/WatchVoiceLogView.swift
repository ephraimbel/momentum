import SwiftUI
import HealthKit

/// Voice logging on the wrist — the composer's killer feature, transferred whole. Tap, say what
/// you did ("45 min lift, then ran 4 miles"), and the SAME deterministic grammar that powers the
/// phone (`WorkoutLogParser` — pure Swift, zero dependencies, fully offline) renders receipt
/// cards right on the watch. Confirm, and each workout is written to HealthKit — which the phone
/// already imports automatically, so the log flows into plan credit, streaks, and trends with no
/// pairing session required. The wrist never blocks on the phone.
struct WatchVoiceLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var saved = false
    @State private var failed = false

    private var cards: [WorkoutLogParser.Result] {
        text.isEmpty ? [] : WorkoutLogParser.parseMulti(
            text, weightUnit: .default(), distanceUnit: DistanceUnit.auto.resolved())
    }

    private var savable: Bool {
        !cards.isEmpty && cards.allSatisfy { $0.type != nil && ($0.durationS ?? 0) > 0 }
    }

    var body: some View {
        Group {
            if saved {
                savedView
            } else {
                composer
            }
        }
        .navigationTitle { Text("Log").foregroundStyle(WatchTheme.ink) }
        .onAppear(perform: applyDebugDraft)
    }

    private var composer: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Dictation-first input (the system sheet on watchOS opens straight into the mic).
                TextFieldLink(prompt: Text("Ran 5 easy miles…")) {
                    HStack(spacing: 7) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(text.isEmpty ? "Say what you did" : text)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9).padding(.horizontal, 11)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WatchTheme.surface))
                } onSubmit: { spoken in
                    text = spoken
                    WatchHaptics.tick()
                }
                .buttonStyle(.plain)

                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    receiptCard(card)
                }

                if failed {
                    Text("Couldn't save — try again.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5))
                }

                if !cards.isEmpty {
                    Button(action: save) {
                        HStack(spacing: 6) {
                            if saving { ProgressView().controlSize(.small) }
                            else { Image(systemName: "checkmark") }
                            Text(cards.count > 1 ? "Log \(cards.count) workouts" : "Log workout")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WatchTheme.accent)
                    .foregroundStyle(.black)
                    .disabled(!savable || saving)
                    .opacity(savable ? 1 : 0.5)
                    if !savable {
                        Text("Add how long it was — “for 45 minutes”.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WatchTheme.inkTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// One compact receipt card per parsed workout — sport, duration, distance or top set line.
    private func receiptCard(_ card: WorkoutLogParser.Result) -> some View {
        let type = card.type
        let unit = DistanceUnit.auto.resolved()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: type.map(icon(for:)) ?? "questionmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WatchTheme.accent)
                Text(type?.title ?? "Which sport?")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WatchTheme.ink)
                Spacer(minLength: 0)
                if let d = card.durationS {
                    Text(Formatters.duration(s: d))
                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(WatchTheme.ink)
                }
            }
            if let m = card.distanceM {
                Text(Formatters.distance(meters: m, unit: unit))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(WatchTheme.inkSecondary)
            }
            ForEach(Array(card.exercises.prefix(3).enumerated()), id: \.offset) { _, ex in
                Text("\(ex.name)  \(ex.sets)×\(ex.reps)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(WatchTheme.inkSecondary)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WatchTheme.surface))
    }

    private var savedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(WatchTheme.accent)
            Text(cards.count > 1 ? "\(cards.count) workouts logged" : "Logged")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(WatchTheme.ink)
            Text("Saved to Health — your iPhone picks it up from there.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WatchTheme.inkSecondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(WatchTheme.control)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Save — each card becomes an HKWorkout; the phone's importer does the rest

    private func save() {
        guard savable, !saving else { return }
        saving = true
        failed = false
        let toSave = cards
        Task {
            do {
                try await Self.write(cards: toSave)
                WatchHaptics.done()
                saved = true
            } catch {
                failed = true
            }
            saving = false
        }
    }

    static func write(cards: [WorkoutLogParser.Result]) async throws {
        let store = HKHealthStore()
        let share: Set = [HKQuantityType.workoutType(),
                          HKQuantityType(.activeEnergyBurned),
                          HKQuantityType(.distanceWalkingRunning),
                          HKQuantityType(.distanceCycling)]
        try await store.requestAuthorization(toShare: share, read: [])

        let dates = WorkoutLogParser.stackedDates(for: cards)
        for (i, card) in cards.enumerated() {
            guard let type = card.type, let duration = card.durationS else { continue }
            let start = dates[i]
            let end = start.addingTimeInterval(duration)

            let config = HKWorkoutConfiguration()
            config.activityType = Self.hkActivity(for: type)
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            try await builder.beginCollection(at: start)

            // Distance rides along as a sample so the phone's import shows the miles.
            if let meters = card.distanceM, meters > 0, type.isGPS {
                let qty = HKQuantity(unit: .meter(), doubleValue: meters)
                let distType: HKQuantityType = type.discipline == .cycling
                    ? HKQuantityType(.distanceCycling)
                    : HKQuantityType(.distanceWalkingRunning)
                let sample = HKQuantitySample(type: distType, quantity: qty, start: start, end: end)
                try await builder.addSamples([sample])
            }
            try await builder.addMetadata([HKMetadataKeyWorkoutBrandName: "momentum watch log"])
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        }
    }

    /// The full sport map, wrist edition — every loggable type lands on its honest HK activity.
    static func hkActivity(for type: WorkoutType) -> HKWorkoutActivityType {
        switch type {
        case .run, .trailRun: .running
        case .walk: .walking
        case .hike: .hiking
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: .cycling
        case .strength: .traditionalStrengthTraining
        case .crossfit: .crossTraining
        case .hiit: .highIntensityIntervalTraining
        case .tennis: .tennis
        case .soccer: .soccer
        case .basketball: .basketball
        case .golf: .golf
        case .yoga: .yoga
        case .pilates: .pilates
        case .swimming: .swimming
        case .rowing: .rowing
        case .other: .other
        }
    }

    private func icon(for type: WorkoutType) -> String {
        switch type.discipline {
        case .running: "figure.run"
        case .cycling: "figure.outdoor.cycle"
        case .walking: "figure.walk"
        case .strength: "dumbbell.fill"
        }
    }

    private func applyDebugDraft() {
        #if DEBUG
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--watch-log-draft=") }),
           text.isEmpty {
            text = String(arg.dropFirst("--watch-log-draft=".count))
        }
        #endif
    }
}
