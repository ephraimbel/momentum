import SwiftUI
import SwiftData

/// One recovery check-in from both Today and Manage Plan. No countdown implies clearance.
struct IllnessCheckInView: View {
    let profile: UserProfile
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var improving = false
    @State private var feverFree = false
    @State private var dailyActivities = false
    @State private var concerning = false
    @State private var clinician = false
    @State private var exerciseWellTolerated = false
    @State private var kind: IllnessResponse.Kind = .respiratory
    @Environment(Services.self) private var services
    @State private var message: String?
    private var state: IllnessResponse.State? { IllnessResponse.state(for: profile) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.display(26, weight: .bold))
                    Text(guidance).font(.rounded(16)).foregroundStyle(Theme.inkSecondary)
                }
                if let state {
                    Section("How are you feeling?") {
                        Toggle("Symptoms are improving overall", isOn: $improving)
                        Toggle("Fever-free for at least 24 hours without fever medicine", isOn: $feverFree)
                        Toggle("Normal daily activities feel comfortable", isOn: $dailyActivities)
                        if state.phase != .resting {
                            Toggle("Exercise felt comfortable during, afterward and the following day, with no returning symptoms or unusual effort", isOn: $exerciseWellTolerated)
                        }
                        Toggle("Chest pain, unusual breathlessness, fainting, racing heart, severe/worsening symptoms, or advice to avoid exercise", isOn: $concerning)
                    }
                    if state.needsClinicalAdvice || (state.phase == .resting && state.kind != .respiratory)
                        || Date().timeIntervalSince(state.startedAt) >= 7 * 86_400 {
                        Section {
                            Text("This self-guided return is for mild respiratory illness. For other, prolonged or concerning illness, speak to a clinician before exercise.")
                            Toggle("A clinician has advised that I can try returning", isOn: $clinician)
                        }
                    }
                    Section {
                        Button(state.phase == .resting ? "Check my next step" : "Review my return") { checkIn() }
                            .accessibilityIdentifier("illness.checkin")
                        Button("Symptoms returned — rest again") { pause() }
                            .accessibilityIdentifier("illness.rest")
                    }
                } else {
                    Section {
                        Picker("What are you recovering from?", selection: $kind) {
                            Text("Cold or respiratory symptoms").tag(IllnessResponse.Kind.respiratory)
                            Text("Another illness or unsure").tag(IllnessResponse.Kind.other)
                        }
                        Button("Pause training while I'm unwell") { pause() }
                            .accessibilityIdentifier("illness.pause")
                    }
                }
                Section {
                    Text("This guides training choices; it does not diagnose illness or provide medical clearance. Seek urgent medical help for chest pain, difficulty breathing at rest or fainting. Your race date stays fixed, but readiness to race is not assumed.")
                        .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                    Link("How this guidance is informed", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/35863871/")!)
                }
            }
            .tint(Theme.purple)
            .navigationTitle("Recovery check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Your next step", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
    }
    private var title: String {
        switch state?.phase {
        case .resting: "Rest comes first"
        case .firstOuting: "Start small"
        case .building: "Build back gently"
        case nil: "Take the pressure off"
        }
    }
    private var guidance: String {
        switch state?.phase {
        case .resting: "Your plan stays paused until you check in. Missed training will not pile up, and rebuilding your plan keeps this recovery state."
        case .firstOuting: "Your next planned outing is capped at 15 easy minutes. Walk or jog at conversational effort; stop if symptoms or unusual effort appear. Check in after at least 24 hours to reflect on how you felt during, after and the next day."
        case .building: "Your runs stay easy and shorter while you return. After at least a week and two easy outings on separate days, check in again. Your next block will use the running you actually completed. If symptoms return, rest again."
        case nil: "Pause for illness without choosing a recovery date. When you feel better, a short check-in guides a gradual return."
        }
    }
    private func pause() {
        do {
            try IllnessResponse.pause(profile: profile, kind: kind, in: context)
            PlanAdjustmentService.propagate(profile: profile, workouts: profile.workouts, notifications: services.notifications)
            dismiss()
        }
        catch { message = error.localizedDescription }
    }
    private func checkIn() {
        do {
            try IllnessResponse.checkIn(.init(improving: improving,
                feverFreeWithoutMedicineFor24Hours: feverFree, dailyActivitiesComfortable: dailyActivities,
                concerningSymptoms: concerning, clinicianAdvisedReturn: clinician,
                exerciseWellTolerated: exerciseWellTolerated), profile: profile, in: context)
            PlanAdjustmentService.propagate(profile: profile, workouts: profile.workouts, notifications: services.notifications)
            dismiss()
        } catch {
            PlanAdjustmentService.propagate(profile: profile, workouts: profile.workouts, notifications: services.notifications)
            message = error.localizedDescription
        }
    }
}

/// Mounted outside onboarding. A fresh account checks for its saved plan before setup starts;
/// an existing athlete can always keep using local data during an outage.
struct PlanContinuityModifier: ViewModifier {
    let profile: UserProfile?
    let onboarding: Bool
    let recording: Bool
    let onStartLocal: () -> Void
    @Environment(Services.self) private var services
    @Environment(AuthController.self) private var auth
    @State private var showIllness = false
    @State private var showSync = false
    private var sync: PlanSyncService { services.planSync }
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if !onboarding, !recording, let profile, IllnessResponse.state(for: profile) != nil {
                    Button { showIllness = true } label: {
                        HStack {
                            Image(systemName: "heart.text.square")
                            Text("Recovery check-in").font(.rounded(14, weight: .semibold))
                            Spacer(); Text("Review").font(.rounded(14)); Image(systemName: "chevron.right")
                        }.padding(12).foregroundStyle(Theme.ink).background(Theme.surface)
                    }.buttonStyle(.plain).accessibilityIdentifier("illness.banner")
                }
                if !onboarding, !recording, profile != nil,
                   sync.status == .conflict || sync.status == .unavailable {
                    Button { showSync = true } label: {
                        HStack {
                            Image(systemName: "icloud")
                            Text(sync.status == .conflict ? "Review plan changes from another device" : "Plan sync needs attention")
                                .font(.rounded(13, weight: .medium))
                            Spacer(); Image(systemName: "chevron.right")
                        }.padding(10).foregroundStyle(Theme.ink).background(Theme.surface)
                    }.buttonStyle(.plain).accessibilityIdentifier("plan.sync.attention")
                }
            }
            .overlay {
                if sync.status == .resetRequired {
                    VStack(spacing: 20) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 36)).foregroundStyle(Theme.purple)
                        Text(sync.finishingReset ? "Resetting this device" : "Finish your device reset")
                            .font(.display(25, weight: .bold)).multilineTextAlignment(.center)
                        Text(sync.detail).font(.rounded(16)).multilineTextAlignment(.center)
                        if sync.finishingReset { ProgressView() }
                        else {
                            Button("Finish device reset") { Task { await sync.finishInterruptedReset() } }
                                .accessibilityIdentifier("plan.reset.finish")
                        }
                    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                } else if auth.isSignedIn, !auth.isGuest, !onboarding, profile == nil, !sync.restoreChecked {
                    VStack(spacing: 20) {
                        Image(systemName: "icloud").font(.system(size: 36)).foregroundStyle(Theme.purple)
                        Text("Finding your saved plan").font(.display(25, weight: .bold))
                        if sync.status == .unavailable {
                            Text(sync.detail).multilineTextAlignment(.center)
                            Button("Try again") { Task { await sync.retry() } }
                            Button("Start a plan on this device") { sync.allowNewLocalPlan(); onStartLocal() }
                        } else { ProgressView() }
                    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                }
            }
            .sheet(isPresented: $showIllness) { if let profile { IllnessCheckInView(profile: profile) } }
            .sheet(isPresented: $showSync) { PlanSyncView(profile: profile) }
    }
}

struct PlanSyncView: View {
    let profile: UserProfile?
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    private var sync: PlanSyncService { services.planSync }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(sync.detail) }
                if sync.status == .conflict {
                    Section {
                        Text("Recovery restrictions stay active whichever plan you choose. Local workouts are kept.")
                        Button("Continue with my account's saved plan") { Task { await sync.resolve(useCloud: true) } }
                        Button("Continue with this device's plan") { Task { await sync.resolve(useCloud: false) } }
                    }
                } else if sync.status == .resetRequired {
                    Button("Finish device reset") { Task { await sync.finishInterruptedReset() } }
                        .disabled(sync.finishingReset)
                } else {
                    Button("Sync now") { Task { await sync.retry() } }
                    if profile?.continuity?.preservedLocalSnapshot != nil {
                        Section("Previous plan copy") {
                            Text("Restore the other plan copy kept on this device. Your current copy will be kept in its place. Recovery restrictions and local workouts stay.")
                            Button("Restore previous plan copy") { Task { await sync.restorePreservedCopy() } }
                        }
                    }
                }
                Section {
                    Text("Plan sync includes your training profile, preferences, recovery state, saved plans and recent Momentum training. GPS samples, workout photos and Apple Health history are not included.")
                        .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                }
            }.navigationTitle("Plan sync")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
