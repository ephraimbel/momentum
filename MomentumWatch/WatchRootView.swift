import SwiftUI

/// Watch home — the wrist's morning in one carousel (PRD §4.10): the readiness/check-in moment
/// first (the watch is where you wake up), today's planned session when the phone has synced one,
/// the race countdown when one is near, then the start cards (Run · Ride · Walk · Lift) and the
/// voice log. Cards render only when their data exists — no phone yet means the watch is simply a
/// clean start screen, never a wall of placeholders.
struct WatchRootView: View {
    @State private var path: [WatchDestination] = []
    private let sync = WatchSyncStore.shared

    var body: some View {
        NavigationStack(path: $path) {
            List {
                morningCard
                sessionCard
                raceCard
                card(.cardio(.run), title: "Run", icon: "figure.run",
                     tint: WatchTheme.accent, detail: "Pace · zones")
                card(.cardio(.ride), title: "Ride", icon: "figure.outdoor.cycle",
                     tint: Color(red: 0.62, green: 0.90, blue: 0.78), detail: "Speed · zones")
                card(.cardio(.walk), title: "Walk", icon: "figure.walk",
                     tint: Color(red: 0.84, green: 0.74, blue: 1.0), detail: "GPS · distance")
                card(.strength, title: "Lift", icon: "dumbbell.fill",
                     tint: WatchTheme.ink, detail: "Sets · rest")
                card(.voiceLog, title: "Log", icon: "mic.fill",
                     tint: Color(red: 1.0, green: 0.85, blue: 0.62), detail: "Say what you did")
            }
            .listStyle(.carousel)
            .navigationTitle { Text("momentum").foregroundStyle(WatchTheme.ink) }
            .navigationDestination(for: WatchDestination.self) { dest in
                switch dest {
                case .cardio(let type): WatchCardioView(type: type)
                case .strength: WatchStrengthView()
                case .voiceLog: WatchVoiceLogView()
                case .checkin: WatchCheckinView()
                }
            }
        }
        .tint(WatchTheme.accent)
        .onAppear(perform: applyLaunchDestination)
    }

    // MARK: The morning moment — check-in prompt until answered, then the readiness ring

    @ViewBuilder
    private var morningCard: some View {
        if let r = sync.todayReadiness {
            HStack(spacing: 11) {
                WatchReadinessRing(score: r.score, band: r.band, lineWidth: 4)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bandWord(r.band))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(WatchTheme.ink)
                    Text(r.driver.isEmpty ? "Today's readiness" : r.driver)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WatchTheme.inkTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(WatchTheme.surface))
            .listRowBackground(Color.clear)
        } else if !sync.checkinAnsweredToday {
            NavigationLink(value: WatchDestination.checkin) {
                HStack(spacing: 11) {
                    ZStack {
                        Circle().fill(WatchTheme.surfaceStrong)
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(WatchTheme.ink)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("How are you feeling?")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(WatchTheme.ink)
                        Text("Two taps · shapes today")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WatchTheme.inkTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(WatchTheme.surface))
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Today's session — the plan, synced from the phone

    @ViewBuilder
    private var sessionCard: some View {
        if let s = sync.todaySession {
            let type = WorkoutType(rawValue: s.typeRaw) ?? .run
            NavigationLink(value: type.isStrengthStyle
                           ? WatchDestination.strength
                           : WatchDestination.cardio(type)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TODAY'S PLAN")
                        .font(.system(size: 10, weight: .bold)).tracking(1.1)
                        .foregroundStyle(WatchTheme.accent)
                    Text(s.title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(WatchTheme.ink)
                    Text(s.detail)
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(WatchTheme.inkSecondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(WatchTheme.surface))
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Race countdown — appears inside two weeks; race day gets the earned iridescence

    @ViewBuilder
    private var raceCard: some View {
        if let race = sync.race, let days = sync.raceDaysAway, days <= 14 {
            let isRaceDay = days == 0
            VStack(alignment: .leading, spacing: 3) {
                Text(isRaceDay ? "RACE DAY" : "\(days) DAY\(days == 1 ? "" : "S") TO GO")
                    .font(.system(size: 10, weight: .bold)).tracking(1.1)
                    .foregroundStyle(isRaceDay ? AnyShapeStyle(WatchTheme.iridescent)
                                               : AnyShapeStyle(WatchTheme.inkSecondary))
                Text(race.name)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(WatchTheme.ink)
                Text(isRaceDay ? "Trust the plan. Go." : "Stay easy — bank freshness.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WatchTheme.inkTertiary)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(WatchTheme.surface)
                    .overlay {
                        if isRaceDay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(WatchTheme.iridescent, lineWidth: 1.2)
                        }
                    }
            )
            .listRowBackground(Color.clear)
        }
    }

    private func card(_ dest: WatchDestination, title: String, icon: String,
                      tint: Color, detail: String) -> some View {
        NavigationLink(value: dest) {
            StartCard(title: title, icon: icon, tint: tint, detail: detail)
        }
        .listRowBackground(Color.clear)
    }

    /// DEBUG deep link for deterministic verification on the watch sim (taps are unreliable there):
    /// `--watch-screen=run|ride|walk|strength|log|checkin` pushes that destination at launch.
    private func applyLaunchDestination() {
        #if DEBUG
        guard path.isEmpty,
              let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--watch-screen=") })
        else { return }
        let value = String(arg.dropFirst("--watch-screen=".count))
        if value == "strength" { path = [.strength] }
        else if value == "log" { path = [.voiceLog] }
        else if value == "checkin" { path = [.checkin] }
        else if let type = WorkoutType(rawValue: value) { path = [.cardio(type)] }
        #endif
    }
}

/// A start row styled as a brand card — tinted icon chip, discipline name, and what gets captured.
private struct StartCard: View {
    let title: String
    let icon: String
    let tint: Color
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(0.20))
                Circle().stroke(tint.opacity(0.25), lineWidth: 1)
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(WatchTheme.ink)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WatchTheme.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(WatchTheme.surface))
    }
}

/// Where a start row leads.
enum WatchDestination: Hashable {
    case cardio(WorkoutType)
    case strength
    case voiceLog
    case checkin
}
