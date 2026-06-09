import SwiftUI
import SwiftData

/// Today / Home (PRD §7.2). Phase 1: the calm entry point with a prominent Start control that
/// routes through the activity chooser into a live session and then the summary. The plan-driven
/// "Today card" (what's on today + streak + week ring) lands in Phase 2.
struct TodayView: View {
    @Environment(\.modelContext) private var context

    @State private var showingChooser = false
    @State private var liveType: WorkoutType?
    @State private var summary: PresentedWorkout?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.xl) {
                Spacer()
                VStack(spacing: Theme.Space.sm) {
                    Text("Ready to train?")
                        .font(.system(size: Theme.FontSize.title, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Pick a session and momentum will track it.")
                        .font(.system(size: Theme.FontSize.body))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                OversizedButton(title: "Start", systemImage: "play.fill") {
                    showingChooser = true
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.xl)
            }
        }
        .navigationTitle("Today")
        .sheet(isPresented: $showingChooser) {
            ActivityChooserView { type in
                showingChooser = false
                liveType = type
            }
            .presentationDetents([.medium])
        }
        .fullScreenCover(item: $liveType) { type in
            if type == .strength {
                StrengthLiveView(container: context.container) { finishedId in
                    liveType = nil
                    if let finishedId { summary = PresentedWorkout(id: finishedId, type: type) }
                }
            } else {
                CardioLiveView(type: type, container: context.container) { finishedId in
                    liveType = nil
                    if let finishedId { summary = PresentedWorkout(id: finishedId, type: type) }
                }
            }
        }
        .fullScreenCover(item: $summary) { presented in
            if presented.type == .strength {
                StrengthSummaryView(workoutId: presented.id) { summary = nil }
            } else {
                CardioSummaryView(workoutId: presented.id) { summary = nil }
            }
        }
    }
}

/// Identifiable wrapper so a finished workout id can drive `fullScreenCover(item:)`.
struct PresentedWorkout: Identifiable {
    let id: UUID
    let type: WorkoutType
}

#Preview {
    NavigationStack { TodayView() }
        .environment(Services.live())
        .modelContainer(PersistenceController.inMemory().container)
}
