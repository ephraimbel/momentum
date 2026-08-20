import SwiftUI
import SwiftData
import PhotosUI
import UIKit   // UIAccessibility.isReduceMotionEnabled in the building beat

/// Onboarding → plan reveal (PRD §4.1, §7.1) — the conversion engine. Cal-AI-grade structure
/// (continuous progress, back chevron, one bold question per screen, tactile cards, a pinned
/// Continue, an anticipation "building" beat, a celebratory reveal) rendered in momentum's
/// monochrome + earned-iridescence identity.
struct OnboardingFlow: View {
    /// Called when the flow ends and the app takes over. Onboarding no longer asks for a rating —
    /// guideline 5.6.3 forbids the ask on first launch / during onboarding, so it moved to the
    /// finished-workout moment (see `AppReview` + `WorkoutRunner`).
    var onComplete: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Services.self) private var services
    @Environment(AuthController.self) private var auth
    @Environment(PaywallController.self) private var paywall
    @Environment(\.scenePhase) private var scenePhase
    /// Apple's native App Store rating alert — used by the `.rateUs` beat.
    @Environment(\.requestReview) private var requestReview
    @State private var rateStarsIn = false
    @State private var rateWorking = false   // "Rate momentum" tapped; the 1.2s settle is underway
    @State private var pickedOnboardingAvatar: PhotosPickerItem?
    /// The curated look picked on the identity beat (ring in the strip); cleared by a photo pick.
    @State private var onboardingPreset: AvatarPreset?
    // Resumes a draft when a prior onboarding was interrupted before the profile was created;
    // fresh otherwise. See OnboardingDraft.
    @State private var vm = OnboardingViewModel.resuming()
    @State private var profile: UserProfile?
    @State private var goingBack = false
    /// Request location on the final primer. Created on THAT tap, not at init: this view is
    /// re-initialized whenever RootView's body re-evaluates (cover content closures re-run), and a
    /// fresh `CLLocationManager` per pass was pure waste (perf audit 2026-08-13). Held in @State so
    /// the manager outlives the authorization prompt it raises.
    @State private var locator: LocationService?
    @State private var touchedSteps: Set<OnboardingViewModel.Step> = []  // first-pick affirmation, once per screen
    @State private var affirmation: String?          // the gentle "got it" micro-reward toast
    @State private var showPaywall = false           // the `onboarding_complete` paywall — the last beat, before the app
    @State private var paywallHandledExit = false    // exitPaywall ran — onDismiss must not advance again
    @State private var notificationPopped = false     // notifications step: the reminder banner slides in like real iOS
    @State private var healthRequestInFlight = false  // one-shot gate: a double-tap advanced two steps
    @State private var remindersAdvanced = false      // same for the reminders primer
    @State private var lastStepChangeAt = Date.distantPast   // double-tap guard for goNext/goBack
    /// True while the paywall's exit advances the step UNDER the still-presented cover — the
    /// travel animation is suppressed so the account beat is fully composed before the cover
    /// dismisses (the mid-flight crossfade used to ghost the rating step through it).
    @State private var jumpCut = false
    @State private var showRacePicker = false        // race step: the catalog of storied marathons
    @State private var showTimeEntry = false         // calibration: reveal the "recent time" entry
    @State private var buildCompleted = 0            // building beat: lines checked (parent-paced)
    @State private var buildRing = 0.0               // building beat: ring fill 0…1 (parent-paced)

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if vm.step == .building {
                // A calm, centered loader — renders full-bleed so it escapes the flow's padding.
                // `buildPlan` paces it (and slots the real generation behind the "Finalizing" line).
                BuildingPlanView(lines: vm.buildingLines(), completed: buildCompleted, ringProgress: buildRing)
                    .task { await buildPlan() }
                    .transition(.opacity)
            } else {
                VStack(spacing: Theme.Space.lg) {
                    if isQuestion { header }
                    content
                        // The screen travels in the direction of motion (forward from the right, back
                        // from the left), then each element cascades up — directionality + the
                        // "assemble" entrance reads more premium than a flat crossfade.
                        .transition(stepTransition)
                        .id(vm.step)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.sm)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isQuestion { continueBar }
        }
        .overlay(alignment: .bottom) { if isQuestion { affirmationToast } }
        .animation(jumpCut ? nil : Motion.travel, value: vm.step)
        .onAppear {
            // A returning athlete who came in through "I already have an account" shouldn't retype
            // what they just told us — prefill the name. The guest-first path (2026-07-27) has no
            // identity yet, so this is quietly a no-op there and the name step opens clean; the
            // account beat backfills it afterwards if they left it blank.
            if vm.name.isEmpty, let known = auth.displayName, !known.isEmpty { vm.name = known }
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            // Combine with any onboarding step arg to see the FEMALE anatomy figure (the flow the
            // user actually takes: select female → the anatomy beats render her body).
            if args.contains("--onboarding-female") { vm.sex = .female }
            if args.contains("--onboarding-identity") { vm.name = "Maya"; vm.step = .identity }
            // --onboarding-identity-preset <case>: land on the beat with a look staged (ring +
            // updated avatar), for sim verification — tiles are unreachable by simctl.
            if let i = args.firstIndex(of: "--onboarding-identity-preset"), i + 1 < args.count,
               let preset = AvatarPreset(rawValue: args[i + 1]) {
                vm.name = "Maya"; vm.step = .identity
                vm.avatarData = AvatarPreset.bake(preset, name: vm.name)
                onboardingPreset = preset
            }
            // Pre-set a handle so the field's taken/available state renders deterministically
            // (sim can't type): pair with a row for that handle in the backend to see ✗ + chips.
            if args.contains("--onboarding-identity-taken") { vm.name = "Maya"; vm.handle = "maya"; vm.step = .identity }
            if args.contains("--onboarding-volume") { vm.activities = [.run]; vm.experience = .some; vm.step = .runVolume }
            if args.contains("--onboarding-hybrid") { vm.activities = [.run, .strength]; vm.step = .hybridFocus }
            if args.contains("--onboarding-disciplines") { vm.step = .disciplines }
            if args.contains("--onboarding-notifications") { vm.step = .notifications }
            if args.contains("--onboarding-building") {
                vm.activities = args.contains("--building-lift") ? [.run, .strength] : [.run]
                vm.goal = .raceDistance; vm.raceDistance = .marathon; vm.name = "Maya"; vm.step = .building
            }
            if args.contains("--onboarding-reveal"), let demo = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first {
                profile = demo
                // --onboarding-reveal-runs hides the anatomy block so the first-week dropdowns sit higher.
                vm.activities = args.contains("--reveal-runs") ? [.run] : [.run, .strength]
                vm.daysPerWeek = demo.daysPerWeek; vm.goal = demo.goal
                vm.name = "Maya"; vm.step = .reveal
                // --reveal-podium: the Podium outlook card (race path w/ goal time; add
                // --reveal-podium-open for the no-race "become great" variant).
                if args.contains("--reveal-podium") {
                    vm.activities = [.run]; vm.intensity = .podium; vm.experience = .some
                    if args.contains("--reveal-podium-open") {
                        vm.goal = .endurance
                    } else {
                        vm.goal = .raceDistance; vm.raceDistance = .marathon
                        vm.goalHours = 3; vm.goalMinutes = 10
                    }
                }
            }
            if args.contains("--onboarding-goaltime") {
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .marathon; vm.step = .raceGoalTime
            }
            if args.contains("--onboarding-intensity") {
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .half; vm.hasRace = true
                vm.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 18, to: Date()) ?? Date()
                vm.experience = .some; vm.calibrationMode = .feel; vm.paceFeel = .regular; vm.weeklyRunVolumeM = 35_000
                vm.step = .intensity
            }
            if args.contains("--onboarding-injuries") { vm.activities = [.run]; vm.step = .injuries }
            if args.contains("--onboarding-health") { vm.activities = [.run]; vm.step = .health }
            if args.contains("--onboarding-calibration") {
                // The pace question folded into the experience step (2026-07-24); recipe still lands there.
                vm.activities = [.run]; vm.step = .experience
            }
            if args.contains("--onboarding-intensity-short") {
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .marathon; vm.hasRace = true
                vm.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 6, to: Date()) ?? Date()
                vm.experience = .new; vm.weeklyRunVolumeM = 15_000
                vm.step = .intensity
            }
            if args.contains("--onboarding-intensity-pr") {
                // The "12 weeks, 4:00 → 3:30 marathon" case: a goal TIME drives the verdict, so the
                // banner reacts as the athlete picks how hard to push (tooShort at Balanced → doable
                // once they commit to Aggressive/Podium). A marathon benchmark of 14:400 = a 4:00 now.
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .marathon; vm.hasRace = true
                vm.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 12, to: Date()) ?? Date()
                vm.experience = .some; vm.calibrationMode = .time; vm.benchmark = .marathon
                vm.recentRunSeconds = 14_400; vm.weeklyRunVolumeM = 45_000; vm.daysPerWeek = 5
                vm.goalHours = 3; vm.goalMinutes = 30
                vm.step = .intensity
            }
            // Full-coverage step jumps so every screen is screenshot-verifiable (sim can't tap).
            if args.contains("--onboarding-rate") { vm.step = .rateUs }
            if args.contains("--onboarding-account") { vm.step = .account }
            if args.contains("--onboarding-goal") { vm.name = "Maya"; vm.step = .goal }
            if args.contains("--onboarding-experience") { vm.activities = [.run]; vm.step = .experience }
            if args.contains("--onboarding-metrics") { vm.activities = [.run]; vm.step = .metrics }
            if args.contains("--onboarding-race") { vm.activities = [.run]; vm.goal = .raceDistance; vm.step = .race }
            if args.contains("--onboarding-musclefocus") { vm.activities = [.strength]; vm.goal = .buildMuscle; vm.step = .muscleFocus }
            if args.contains("--onboarding-days") { vm.activities = [.run]; vm.step = .days }
            if args.contains("--onboarding-preferreddays") { vm.activities = [.run]; vm.daysPerWeek = 4; vm.step = .preferredDays }
            if args.contains("--onboarding-session") { vm.activities = [.strength]; vm.step = .session }
            if args.contains("--onboarding-equipment") { vm.activities = [.strength]; vm.step = .equipment }
            if args.contains("--onboarding-split") { vm.activities = [.strength]; vm.step = .strengthSplit }
            if args.contains("--onboarding-why") { vm.activities = [.run]; vm.step = .why }
            if args.contains("--onboarding-primers") { vm.activities = [.run]; vm.step = .primers }
            #endif
        }
        .onChange(of: vm.step) { _, step in
            services.analytics.log(.onboardingStep(index: step.rawValue))
            // Checkpoint on every navigation — the draft now holds every answer made up to and
            // including the step just left, so an eviction resumes here, not at question one.
            saveDraftIfEnabled()
        }
        // Capture the very latest answers the instant the app leaves the foreground — the moment
        // iOS is most likely to evict a backgrounded app, and the one a step-change wouldn't cover
        // (answers changed on the current step before tabbing away).
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveDraftIfEnabled() } }
        // The onboarding_complete paywall (PRD §10) — shown from the rating beat's hand-off, after
        // every opt-in. **SOFT since 2026-08-06** (user call, reversing the 2026-07-28 hard flip):
        // the flow's X closes it un-entitled. Purchase and close both exit through `exitPaywall`,
        // which advances the flow UNDER the cover before dismissing it — so the dismissal reveals
        // the account beat, not a half-second flash of the rating step the wall was presented over
        // (that flash shipped through 1.2.0; fixed 2026-08-06). `onDismiss` remains only for the
        // store-unreachable deferral, whose escape dismisses without an exit callback.
        // `finishOnboarding` still arms `onboardingGatePending` first, so a force-quit AT the wall
        // re-raises it once from RootView (where the X is equally available) and the account beat
        // is never silently lost. Since 2026-08-05 the wall is the two-page flow (the device tour,
        // then the same PaywallView the rest of the app shows).
        .fullScreenCover(isPresented: $showPaywall, onDismiss: {
            if !paywallHandledExit { goToAccountBeat() }
            paywallHandledExit = false
        }) {
            OnboardingPaywallFlow(onEntitled: { exitPaywall() }, onClose: { exitPaywall() })
        }
    }

    /// A whisper-quiet "got it" toast on the first pick of a screen — the research's positive-
    /// reinforcement beat, kept monochrome and brief so it stays sleek, not chatty.
    @ViewBuilder
    private var affirmationToast: some View {
        if let affirmation {
            Text(affirmation)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                .transition(.opacity.combined(with: .offset(y: 10)))
                .padding(.bottom, 92)
        }
    }

    private var isQuestion: Bool { vm.isQuestionStep }

    // MARK: Header (back + progress)

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            // Hidden on the first step: its `back()` is a no-op, so a visible chevron there is a
            // dead, feedback-less tap target on the entry screen.
            Button { goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 28, height: 28)
            }
            .opacity(vm.canGoBack ? 1 : 0)
            .disabled(!vm.canGoBack)
            .accessibilityHidden(!vm.canGoBack)
            GeometryReader { geo in
                let w = max(10, geo.size.width * vm.progress)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    // Earned iridescence on a genuine progress surface — the same accent as the
                    // welcome route, with a glowing leading cap that echoes the comet head.
                    Capsule()
                        .fill(LinearGradient(colors: Theme.iridescent, startPoint: .leading, endPoint: .trailing))
                        .frame(width: w)
                        .shadow(color: Theme.iridescent[3].opacity(0.55), radius: 4)
                        .overlay(alignment: .trailing) {
                            Circle().fill(.white).frame(width: 6, height: 6)
                                .shadow(color: Theme.iridescent[0].opacity(0.9), radius: 5)
                        }
                }
            }
            .frame(height: 6)
        }
        .padding(.top, Theme.Space.xs)
    }

    private var continueBar: some View {
        OversizedButton(title: "Continue", isEnabled: vm.canAdvance) { goNext() }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.sm)
            .background(Theme.background)
    }

    /// One advance per gesture: a fast double-tap on any Continue used to skip a whole step —
    /// and from the primers beat it skipped the RATING and armed no paywall (audit 2026-08-11).
    /// Any second advance/back inside the travel animation's window is the same gesture, not a
    /// decision; swallow it. Programmatic advances (buildPlan, the reminders/health completions,
    /// exitPaywall) all arrive ≥0.55s after the previous step change, so none can be swallowed.
    private func goNext() {
        guard Date().timeIntervalSince(lastStepChangeAt) > 0.45 else { return }
        lastStepChangeAt = Date()
        goingBack = false
        vm.advance()
    }
    private func goBack() {
        guard Date().timeIntervalSince(lastStepChangeAt) > 0.45 else { return }
        lastStepChangeAt = Date()
        goingBack = true
        vm.back()
    }

    /// Persist the interruption-recovery draft, unless a deep link is driving the flow (those set a
    /// specific step for verification and must stay deterministic — no stray draft written or read).
    /// The answers snapshot on the main actor NOW; the encode + UserDefaults write hop off it —
    /// this fires from `.onChange(of: vm.step)`, i.e. on the exact frame the travel transition
    /// starts (perf audit 2026-08-13). The arguments scan is cached for the same reason.
    private static let deepLinkDriven =
        ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--onboarding-") })
    private func saveDraftIfEnabled() {
        guard !Self.deepLinkDriven else { return }
        let draft = vm.draft()
        Task.detached(priority: .utility) { OnboardingDraftStore.save(draft) }
    }

    // MARK: Content router

    @ViewBuilder
    private var content: some View {
        switch vm.step {
        case .name: nameStep
        case .identity: identityStep
        case .goal: goalStep
        case .disciplines: disciplinesStep
        case .race: raceStep
        case .raceGoalTime: raceGoalTimeStep
        case .muscleFocus: muscleFocusStep
        case .experience: experienceStep
        case .injuries: injuriesStep
        case .runVolume: runVolumeStep
        case .days: daysStep
        case .preferredDays: preferredDaysStep
        case .session: sessionStep
        case .equipment: equipmentStep
        case .strengthSplit: strengthSplitStep
        case .hybridFocus: hybridFocusStep
        case .metrics: metricsStep
        case .why: whyStep
        case .health: healthStep
        case .intensity: intensityStep
        case .building: EmptyView()   // rendered full-bleed in `body`
        case .reveal: PlanRevealView(vm: vm, profile: profile) {
            // "This looks great" flows into the final opt-in beats — the paywall now waits until the
            // very end (the last step's "Start training"), so nothing interrupts the reveal moment
            // (user call 2026-07-24: the paywall is the LAST thing before the app).
            goNext()
        }
        case .notifications: notificationsStep
        case .primers: primersStep
        case .rateUs: rateUsStep
        case .account: accountStep
        }
    }


    // MARK: Question steps

    private var disciplinesStep: some View {
        let programmed = ActivityChoice.allCases.filter(\.isProgrammed)
        let extras = ActivityChoice.allCases.filter { !$0.isProgrammed }
        return questionScaffold("What do you want to do?", subtitle: "Pick all that apply. We'll build your plan around these.") {
            activitySectionLabel("TRAIN")
            ForEach(Array(programmed.enumerated()), id: \.element) { i, a in
                activityCard(a).reveal(cascade(i))
            }
            activitySectionLabel("ALSO TRACK").padding(.top, Theme.Space.xs)
            Text("Logged as cross-training and added to your weeks. Your call.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(extras.enumerated()), id: \.element) { i, a in
                activityCard(a).reveal(cascade(programmed.count + i))
            }
        }
    }

    private func activityCard(_ a: ActivityChoice) -> some View {
        SelectionCard(title: a.title, systemImage: a.icon, isSelected: vm.activities.contains(a)) {
            pick { if vm.activities.contains(a) { vm.activities.remove(a) } else { vm.activities.insert(a) } }
        }
    }

    private func activitySectionLabel(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nameStep: some View {
        questionScaffold("What should we call you?", subtitle: "We'll make the plan feel like it's yours.") {
            TextField("Your name", text: $vm.name)
                .font(.display(24, weight: .bold)).foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.words).autocorrectionDisabled()
                .submitLabel(.done)
                .padding(Theme.Space.md)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
                .reveal(cascade(0))
        }
    }

    /// A face for the work — a photo, or one of the curated looks, both optional and quiet (no
    /// permission pressure mid-flow). The @handle claim RETURNED with the community launch
    /// (2026-07-29): the same `HandleField` Edit Profile uses — live Supabase availability (anon
    /// RPC, works for guests), tap-to-use suggestions, and the database's unique index as the
    /// real arbiter at claim time.
    private var identityStep: some View {
        questionScaffold("Make it yours", subtitle: "Your @handle, a photo, a look. All optional, all changeable later.") {
            // The @handle leads, on its OWN card (owner call 2026-07-29 — inside the avatar card
            // it read as buried, and it's the identity the whole community keys on). Seeded from
            // the name so most people just tap Continue; the field checks Supabase live and
            // offers alternates if taken.
            HandleField(handle: $vm.handle, backend: services.social,
                        suggestions: HandleSuggester.candidates(name: vm.name, email: nil, seed: 7),
                        boxed: true, showsOfflineHint: true)
                .onAppear {
                    if vm.handle.isEmpty, !vm.name.isEmpty {
                        vm.handle = SocialPrivacy.normalizedHandle(
                            HandleSuggester.baseHandle(name: vm.name, email: nil))
                    }
                }
                .reveal(cascade(0))
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.md) {
                    AvatarView(photo: vm.avatarData, name: vm.name.isEmpty ? "You" : vm.name, size: 56)
                    PhotosPicker(selection: $pickedOnboardingAvatar, matching: .images) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.avatarData == nil ? "Add a photo" : "Change photo")
                                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text("Optional. You can always add one later.")
                                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.md)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    .padding(.horizontal, Theme.Space.md)
                // The full 4×3 system, not a scrolling strip: a strip hid eight of the twelve
                // looks (owner call, 2026-07-29). Same grid grammar as Profile → Edit — one world
                // per row (light · charcoal · lavender), so the choice reads at a glance. No
                // ScrollView means no clipping, so the selection ring renders whole for free.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm),
                                         count: 4),
                          spacing: Theme.Space.md) {
                    ForEach(AvatarPreset.allCases) { preset in
                        Button {
                            onboardingPreset = preset
                            Haptics.selection()
                            // Bake AFTER the selection frame commits: the 512px ImageRenderer +
                            // PNG encode ran inside the tap handler, so the ring's feedback
                            // arrived a beat late on every tile (perf audit 2026-08-13). The
                            // guard drops a bake a faster second tap has superseded.
                            let name = vm.name.isEmpty ? "You" : vm.name
                            Task { @MainActor in
                                await Task.yield()
                                guard onboardingPreset == preset else { return }
                                vm.avatarData = AvatarPreset.bake(preset, name: name)
                            }
                        } label: {
                            PresetAvatarView(preset: preset,
                                             name: vm.name.isEmpty ? "You" : vm.name, size: 56)
                                .overlay {
                                    if onboardingPreset == preset {
                                        Circle().stroke(Theme.ink, lineWidth: 2).padding(-3)
                                    }
                                }
                        }
                        .buttonStyle(PressableScaleStyle(scale: 0.94))
                        .accessibilityLabel("Avatar look \(preset.rawValue)")
                    }
                }
                .padding(Theme.Space.md)
            }
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
            .reveal(cascade(1))
        }
        .onChange(of: pickedOnboardingAvatar) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    vm.avatarData = WorkoutPhotoSection.downscaled(data, maxDimension: 512)
                    onboardingPreset = nil   // the photo wins over any look picked earlier
                    Haptics.success()
                }
            }
        }
    }

    private var goalStep: some View {
        // Running-first ordering (ENDURANCE-FOCUS Phase 0): the racing + endurance goals lead — this is
        // a running app. Strength/body-composition goals remain, as the supporting pillar.
        let goals: [(Goal, String, String)] = [
            (.raceDistance, "Run a race", "flag.checkered"), (.endurance, "Run farther & faster", "wind"),
            (.stayConsistent, "Stay consistent", "calendar"), (.loseFat, "Lose fat / get fit", "flame"),
            (.buildMuscle, "Build muscle", "figure.strengthtraining.traditional"), (.getStronger, "Get stronger", "dumbbell.fill")]
        return questionScaffold("What's your main goal?", subtitle: "This shapes everything that follows.") {
            ForEach(Array(goals.enumerated()), id: \.element.0) { i, g in
                SelectionCard(title: g.1, systemImage: g.2, isSelected: vm.goal == g.0) {
                    pick { vm.goal = g.0 }
                }
                .reveal(cascade(i))
            }
        }
    }

    /// For runners this is BOTH the experience and the pace question — asked once (2026-07-24). The
    /// running level (a pace-feel) seeds the starting pace AND the experience tier, and an optional
    /// recent time sharpens it. Lifters get the plain three-way. A separate "how's your pace?" page
    /// used to ask runners the same thing twice.
    private var experienceStep: some View {
        questionScaffold(vm.running ? "How's your running?" : "How experienced are you?",
                         subtitle: vm.running ? "This sets your starting paces. You can always adjust."
                                              : (vm.hybrid ? "We'll set running and lifting separately." : nil)) {
            if vm.running {
                ForEach(Array(PaceFeel.allCases.enumerated()), id: \.element) { i, f in
                    SelectionCard(title: f.title, subtitle: f.subtitle, systemImage: f.icon,
                                  isSelected: vm.calibrationMode == .feel && vm.paceFeel == f) {
                        pick { vm.paceFeel = f; vm.calibrationMode = .feel; vm.experience = f.experienceLevel }
                    }
                    .reveal(cascade(i))
                }
                // Optional precision — a recent race/time trial sharpens the paces past the by-feel guess.
                timeEntryCard.reveal(cascade(PaceFeel.allCases.count))
                // Hybrids still need their lifting level (running has no bearing on it).
                if vm.lifting {
                    expSegment("Lifting", vm.liftExperience) { vm.liftExperience = $0 }
                        .reveal(cascade(PaceFeel.allCases.count + 1))
                }
            } else {
                ForEach(Array([ExperienceLevel.new, .some, .experienced].enumerated()), id: \.element) { i, e in
                    SelectionCard(title: e == .new ? "New to this" : e == .some ? "Some experience" : "Experienced",
                                  isSelected: vm.experience == e) { pick { vm.experience = e } }
                        .reveal(cascade(i))
                }
            }
        }
    }

    /// Current running load — seeds the plan's starting volume so it meets the athlete where they are.
    private var runVolumeStep: some View {
        questionScaffold("How much are you running now?",
                         subtitle: "So your plan starts where you are. Challenging, not crushing.") {
            metricRow("Per week", volumeLabel(vm.weeklyRunVolumeM),
                      { setWeekly(volumeDisplay(vm.weeklyRunVolumeM) - 5) },
                      { setWeekly(volumeDisplay(vm.weeklyRunVolumeM) + 5) }).reveal(cascade(0))
            metricRow("Longest run", volumeLabel(vm.longestRunM),
                      { setLongest(volumeDisplay(vm.longestRunM) - 1) },
                      { setLongest(volumeDisplay(vm.longestRunM) + 1) }).reveal(cascade(1))
        }
        .onAppear(perform: seedVolumeDefaultsIfNeeded)
    }

    // Volume is entered in the athlete's locale unit (mi in the US/UK, km elsewhere) but stored in meters.
    private var useMetricDistance: Bool { Locale.current.measurementSystem != .us }
    private var metersPerUnit: Double { useMetricDistance ? 1000 : 1609.344 }
    private var distanceUnitLabel: String { useMetricDistance ? "km" : "mi" }
    private func volumeDisplay(_ meters: Double?) -> Double { (meters ?? 0) / metersPerUnit }
    private func volumeLabel(_ meters: Double?) -> String { "\(Int(volumeDisplay(meters).rounded())) \(distanceUnitLabel)" }
    // Cap 250 display units: in km locales that clears elite-marathon mileage (~220 km/wk);
    // 200 km clipped it. (250 mi is beyond any human, harmlessly.)
    private func setWeekly(_ d: Double) { Haptics.light(); vm.weeklyRunVolumeM = min(250, max(0, d.rounded())) * metersPerUnit }
    private func setLongest(_ d: Double) { Haptics.light(); vm.longestRunM = min(60, max(1, d.rounded())) * metersPerUnit }
    /// Anchor the steppers on a sensible starting guess by experience (the athlete adjusts from there).
    private func seedVolumeDefaultsIfNeeded() {
        guard vm.weeklyRunVolumeM == nil else { return }
        let (weekly, longest): (Double, Double) = vm.experience == .experienced ? (40_000, 16_000) : (20_000, 8_000)
        vm.weeklyRunVolumeM = weekly
        vm.longestRunM = longest
    }

    /// A compact labelled 3-way experience selector (used per-discipline for hybrids).
    private func expSegment(_ title: String, _ current: ExperienceLevel,
                            _ set: @escaping (ExperienceLevel) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2).foregroundStyle(Theme.inkTertiary)
            HStack(spacing: Theme.Space.sm) {
                ForEach([ExperienceLevel.new, .some, .experienced], id: \.self) { e in
                    let on = current == e
                    Button { pick { set(e) } } label: {
                        Text(e == .new ? "New" : e == .some ? "Some" : "Pro")
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.ink : Theme.surface)
                                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                            }
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
                }
            }
        }
    }

    private var daysStep: some View {
        let opts: [(Int, String, String)] = [
            (2, "2 days", "Light week"), (3, "3 days", "A steady base"),
            (4, "4 days", "Consistent"), (5, "5 days", "High volume"), (6, "6+ days", "All in")]
        return questionScaffold("How many days a week?", subtitle: "We'll shape your week around this.") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                SelectionCard(title: o.1, subtitle: o.2, isSelected: vm.daysPerWeek == o.0) { pick { vm.daysPerWeek = o.0 } }
                    .reveal(cascade(i))
            }
            // Frequency honesty, said where the choice is made: a race build under its effective
            // day floor holds fitness rather than building readiness (PlanFeasibility owns the
            // numbers; the intensity step's verdict banner repeats the full read).
            if vm.goal == .raceDistance, let race = vm.raceDistance,
               vm.daysPerWeek < PlanFeasibility.minimumEffectiveDays(forDistanceM: race.meters) {
                let minDays = PlanFeasibility.minimumEffectiveDays(forDistanceM: race.meters)
                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 13, weight: .semibold))
                    Text("Honest note: a \(race.label.lowercased()) build really wants \(minDays)+ days. On \(vm.daysPerWeek) you'll maintain fitness, not race readiness. We'll build your week either way.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
                .transition(.opacity)
            }
        }
    }

    private var equipmentStep: some View {
        let opts: [(Equipment, String, String)] = [
            (.fullGym, "Full gym", "building.2"), (.dumbbellsOnly, "Dumbbells only", "dumbbell"),
            (.homeMinimal, "Home minimal", "house"), (.bodyweight, "Bodyweight", "figure.cooldown")]
        return questionScaffold("What equipment do you have?") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                SelectionCard(title: o.1, systemImage: o.2, isSelected: vm.equipment == o.0) { pick { vm.equipment = o.0 } }
                    .reveal(cascade(i))
            }
        }
    }

    private var sessionStep: some View {
        let opts: [(Int, String, String)] = [
            (30, "30 min", "In and out"), (45, "45 min", "A balanced session"),
            (60, "60 min", "A full workout"), (75, "75+ min", "Go long")]
        return questionScaffold("How long per session?") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                SelectionCard(title: o.1, subtitle: o.2, isSelected: vm.sessionMinutes == o.0) { pick { vm.sessionMinutes = o.0 } }
                    .reveal(cascade(i))
            }
        }
    }

    private var whyStep: some View {
        let reasons = ["clear head", "health", "look better", "compete", "me-time"]
        return questionScaffold("Why are you doing this?", subtitle: "It sets your coach's tone.") {
            ForEach(Array(reasons.enumerated()), id: \.element) { i, r in
                SelectionCard(title: r.capitalized, isSelected: vm.reason == r) { pick { vm.reason = r } }
                    .reveal(cascade(i))
            }
        }
    }

    // The running pace question now lives in `experienceStep` (2026-07-24) — a runner sets their
    // level once. The `timeEntryCard` below is still shared by that step.

    /// Past injuries — multi-select body areas the plan will train around (ENDURANCE-FOCUS §8.2).
    /// Optional and shame-free; empty = none. Feeds the protective ramp + the injury loop's watch list.
    private var injuriesStep: some View {
        questionScaffold("Anything to train around?",
                         subtitle: "Past injuries shape a safer ramp. We'll build up gently where you've been hurt. Skip if you're all clear.") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm), GridItem(.flexible())],
                      spacing: Theme.Space.sm) {
                ForEach(Array(InjuryArea.allCases.enumerated()), id: \.element) { i, area in
                    let on = vm.injuryAreas.contains(area)
                    Button {
                        Haptics.selection()
                        withAnimation(Motion.lively) {
                            if on { vm.injuryAreas.remove(area) } else { vm.injuryAreas.insert(area) }
                        }
                    } label: {
                        Text(area.label)
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(on ? .white : Theme.ink)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background {
                                Capsule().fill(on ? AnyShapeStyle(Theme.purple) : AnyShapeStyle(Theme.surface))
                                if !on { Capsule().stroke(Theme.hairline) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .reveal(cascade(i / 2))
                }
            }
            // The explicit way through for the healthy majority (owner ask 2026-07-30): without
            // it, a grid of selectable areas reads like a question you must answer.
            Button {
                Haptics.success()
                withAnimation(Motion.lively) { vm.injuryAreas.removeAll() }
                goNext()
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .bold))
                    Text("No injuries, I'm all clear")
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                }
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
            .buttonStyle(.plain)
            .reveal(cascade((InjuryArea.allCases.count + 1) / 2))
            if !vm.injuryAreas.isEmpty {
                Text("We'll ease the impact around \(vm.injuryAreas.count == 1 ? "this area" : "these areas") and watch for early warning signs.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }

    /// The recovery consent beat (ENDURANCE-FOCUS §7) — connect Apple Health so the plan adapts to how
    /// the athlete is *actually* recovering. Benefit-first, names their devices, read-only reassurance.
    ///
    /// ⚠️ App Review guideline 5.1.1(iv) (rejected build 17, 2026-08-11): a priming screen before the
    /// HealthKit request must use a neutral button word ("Continue"/"Next", never "Connect") and must
    /// NOT offer a way to bypass the system prompt (no "Maybe later"). The athlete's real choice is
    /// the system sheet itself — declining there advances the flow exactly like accepting.
    private var healthStep: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.sm) {
                Text("Train with your whole picture")
                    .font(.serif(30, weight: .semibold)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("Next, iOS will ask about Apple Health access. With it, momentum learns how you're actually recovering, so each week adapts to you, not a template. You choose what to share.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.05)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                healthBenefitRow("bed.double.fill", "Sleep & heart rate", "Rough night? Your week eases off before you overdo it.")
                healthBenefitRow("applewatch", "Your devices, one tap", "Oura, Garmin, Whoop & Apple Watch already sync to Apple Health. No separate logins.")
                healthBenefitRow("lock.fill", "Private, always", "Reads your recovery signals, saves your workouts. You pick exactly what, and can turn it off anytime.")
            }
            .padding(Theme.Space.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
            .reveal(0.15)
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.sm) {
                OversizedButton(title: "Continue") {
                    // One-shot: when permission is already determined the awaits return instantly
                    // with no system sheet to swallow taps, and a double-tap advanced two steps.
                    guard !healthRequestInFlight else { return }
                    healthRequestInFlight = true
                    Task {
                        _ = await services.health.requestAuthorization()
                        // Grab resting HR (and body mass, if the athlete skipped it) while we have
                        // consent — it upgrades HR zones to Karvonen from the very first plan.
                        let metrics = await services.health.importedBodyMetrics()
                        if let rhr = metrics.restingHR { vm.importedRestingHR = rhr }
                        if vm.bodyMassKg == nil { vm.bodyMassKg = metrics.bodyMassKg }
                        // No workout history is imported here — or anywhere. Health is a source of
                        // SIGNALS, never workouts (owner call 2026-08-15, `d419f0f`: the importer was
                        // deleted after a fresh signup pulled ~10,000 mirrored Watch/Garmin/Strava
                        // rows). A fresh account starts on an empty grid and fills from what the
                        // athlete does IN the app. What connecting earns is exactly the two reads
                        // above (resting HR + body mass → Karvonen zones from the first plan) plus
                        // live HR and the recovery signals accruing from today forward.
                        goNext()
                        // Re-arm AFTER the step transition settles (in case the athlete comes
                        // back) — an immediate reset would re-open the double-tap window.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { healthRequestInFlight = false }
                    }
                }
            }
            .reveal(0.28)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func healthBenefitRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.purple)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.purple.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Text(detail).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// How hard to push — led by the honesty banner (what the calendar + current fitness actually
    /// allow), then the three tiers with the recommended one marked. This is our edge over generic
    /// plan apps: we tell the truth before we sell the plan.
    private var intensityStep: some View {
        let f = vm.feasibility
        return questionScaffold("How hard do you want to push?",
                                subtitle: "Same goal, your pace. You can change this anytime.") {
            feasibilityBanner(f).reveal(cascade(0))
            ForEach(Array(PlanIntensity.allCases.enumerated()), id: \.element) { i, tier in
                SelectionCard(title: tier == f.recommended ? "\(tier.label)  ·  Recommended" : tier.label,
                              subtitle: tier.riskNote ?? tier.subtitle,
                              isSelected: vm.intensity == tier,
                              iridescent: tier == .podium) {
                    pick {
                        vm.intensity = tier
                        // Podium's structure needs the week to hold it — lift the day count to the
                        // tier's floor (the note below says so; the days step can still lower it,
                        // which drops the pick back to a week Podium can't fill).
                        if vm.daysPerWeek < tier.floorDays { vm.daysPerWeek = tier.floorDays }
                    }
                }
                .reveal(cascade(i + 1))
            }
            if vm.intensity == .podium {
                Text("Podium trains \(PlanIntensity.podium.floorDays)+ days a week, so we've set your week to \(vm.daysPerWeek). Every recovery guardrail still applies.")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .onAppear { if !touchedSteps.contains(.intensity) { vm.intensity = f.recommended } }
    }

    /// The truth about the goal vs. the calendar — the icon carries the verdict; monochrome otherwise.
    @ViewBuilder
    private func feasibilityBanner(_ f: PlanFeasibility) -> some View {
        let icon: String = {
            switch f.verdict {
            case .onTrack: "checkmark.seal.fill"
            case .tight: "exclamationmark.triangle.fill"
            case .tooShort: "hand.raised.fill"
            case .noRace: "infinity"
            }
        }()
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                Text(f.headline).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
            }
            if !f.detail.isEmpty {
                Text(f.detail).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !f.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(f.options, id: \.self) { opt in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.purple).padding(.top, 2)
                            Text(opt).font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline)
        }
    }

    /// The optional precise path — expand to enter a recent time over a distance you know.
    private var timeEntryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Button { Haptics.light(); withAnimation(Motion.standard) { showTimeEntry.toggle() } } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: vm.calibrationMode == .time ? "checkmark.circle.fill" : "stopwatch")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(vm.calibrationMode == .time ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.inkSecondary))
                    Text(vm.calibrationMode == .time ? "\(vm.benchmark.label) in \(Formatters.duration(s: vm.recentRunSeconds))" : "I know a recent time")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: showTimeEntry ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTimeEntry {
                HStack(spacing: 6) {                          // tighter so "Marathon" fits at full size
                    ForEach(RunBenchmark.allCases) { b in
                        let on = vm.benchmark == b
                        Button {
                            Haptics.selection()
                            vm.benchmark = b; vm.recentRunSeconds = b.defaultSeconds; vm.calibrationMode = .time
                        } label: {
                            // Uniform smaller label so the longest word ("Marathon") sits comfortably
                            // in its chip rather than shrinking alone against the others.
                            Text(b.label).font(.rounded(Theme.FontSize.label, weight: .bold))
                                .lineLimit(1).minimumScaleFactor(0.9)
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .foregroundStyle(on ? .white : Theme.ink)
                                .background {
                                    Capsule().fill(on ? AnyShapeStyle(Theme.purple) : AnyShapeStyle(Theme.background))
                                    if !on { Capsule().stroke(Theme.hairline) }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: Theme.Space.md) {
                    Text("Time").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    Spacer()
                    // Press-and-hold repeats: the range spans a 12:00 elite 5K to a 60:00 walk-jog,
                    // and nobody should tap 30 times to reach their real time.
                    Button { Haptics.light(); adjustTime(-vm.benchmark.step) } label: { metricStep("minus") }
                        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
                    // Tap the time to TYPE it — "21:45", "1:38:20", or bare digits ("2145").
                    TypableNumber(display: Formatters.duration(s: vm.recentRunSeconds),
                                  keyboard: .numbersAndPunctuation, minWidth: 84,
                                  commit: { commitTypedRaceTime($0) })
                    Button { Haptics.light(); adjustTime(vm.benchmark.step) } label: { metricStep("plus") }
                        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
                }
                .animation(.snappy(duration: 0.2), value: vm.recentRunSeconds)
                Text(paceHint).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    /// Typed race time. Accepts "21:45", "1:38:20", bare minutes ("22"), or run-on digits
    /// ("2145" → 21:45). Where an entry is ambiguous ("330" — 3m30s or 3h30m?), the benchmark's own
    /// plausible range decides: whichever reading lands inside it wins, so a marathoner's "330"
    /// means 3:30:00 and a miler's means 3:30.
    private func commitTypedRaceTime(_ raw: String) {
        let normalized = raw.replacingOccurrences(of: ".", with: ":").replacingOccurrences(of: " ", with: ":")
        let parts = normalized.split(separator: ":").compactMap { Int($0) }
        var candidates: [Double] = []
        switch parts.count {
        case 1:
            let n = parts[0]
            if n >= 100 {   // run-on digits: "2145" → 21:45; "13820" → 1:38:20
                if n >= 10_000 { candidates.append(Double((n / 10_000) * 3600 + ((n / 100) % 100) * 60 + n % 100)) }
                candidates.append(Double((n / 100) * 60 + n % 100))
            }
            candidates.append(Double(n) * 60)          // bare minutes
            candidates.append(Double(n) * 3600)        // bare hours ("3" for a marathon)
        case 2:
            candidates.append(Double(parts[0] * 60 + parts[1]))          // mm:ss
            candidates.append(Double(parts[0] * 3600 + parts[1] * 60))   // h:mm
        case 3:
            candidates.append(Double(parts[0] * 3600 + parts[1] * 60 + parts[2]))
        default: break
        }
        guard !candidates.isEmpty else { return }
        let range = vm.benchmark.range
        let seconds = candidates.first(where: { range.contains($0) })
            ?? min(range.upperBound, max(range.lowerBound, candidates[0]))
        vm.calibrationMode = .time
        vm.recentRunSeconds = seconds
    }

    private func adjustTime(_ delta: Double) {
        vm.calibrationMode = .time
        vm.recentRunSeconds = min(vm.benchmark.range.upperBound, max(vm.benchmark.range.lowerBound, vm.recentRunSeconds + delta))
    }

    /// "Easy runs ≈ 6:10 /mi" — the resulting easy pace, so the number feels meaningful.
    private var paceHint: String {
        let p5k = PlanEngine.riegelP5k(distanceM: vm.benchmark.meters, timeS: vm.recentRunSeconds)
        return "Easy runs ≈ \(Formatters.pace(secPerKm: PlanEngine.pace(.easy, p5k: p5k), unit: .auto))"
    }

    // MARK: Race setup (racers) — distance + optional date

    private var raceStep: some View {
        questionScaffold("Which race?", subtitle: "We'll point your long runs and taper at it.") {
            // The occasion first: pick a real race — Boston, Chicago, Hong Kong — and its name,
            // distance, and date are built into the plan from the very first generation.
            Button { Haptics.light(); showRacePicker = true } label: {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.plannedRaceName ?? "Find your race")
                            .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(vm.plannedRaceName != nil
                             ? "Locked in. Date and distance set below"
                             : "Boston, Chicago, Hong Kong. The big ones, with dates")
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                .padding(Theme.Space.md)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
            }
            .buttonStyle(.plain)
            .reveal(cascade(0))
            .sheet(isPresented: $showRacePicker) {
                RacePickerSheet { race, pickedDistance, date in
                    pick {
                        vm.plannedRaceName = race.name
                        vm.raceDistance = pickedDistance
                        vm.hasRace = true
                        vm.raceDate = date
                    }
                }
                // Forced rather than inherited: a sheet gets its own hosting controller, and whether
                // a `colorScheme` override propagates into one is a SwiftUI implementation detail
                // that's varied across releases. Onboarding is unconditionally dark, so this sheet
                // is too — stated here, at the onboarding call site only, because the SAME sheet is
                // presented from the Plan tab, where it must follow the athlete's appearance setting.
                .environment(\.colorScheme, .dark)
            }

            ForEach(Array(RaceDistance.allCases.enumerated()), id: \.element) { i, d in
                SelectionCard(title: d.label, subtitle: raceSubtitle(d), isSelected: vm.raceDistance == d) {
                    pick { vm.raceDistance = d }
                }
                .reveal(cascade(i + 1))
            }
            raceDateCard.reveal(cascade(RaceDistance.allCases.count + 1))
        }
    }

    private func raceSubtitle(_ d: RaceDistance) -> String {
        switch d {
        case .fiveK: "Fast and punchy"; case .tenK: "Speed meets stamina"
        case .half: "The endurance test"; case .marathon: "The big one"
        case .fiftyK: "Beyond the marathon"
        }
    }

    private var raceDateCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Toggle(isOn: $vm.hasRace) {
                Text("I have a race date").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            if vm.hasRace {
                DatePicker("Race day", selection: $vm.raceDate, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact)
            } else {
                Text("No date is fine. We'll build a rolling block you can race off anytime.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    // MARK: Muscle focus (build-muscle) — live anatomy

    private struct FocusOption { let title: String; let muscles: [MuscleGroup] }
    private var focusOptions: [FocusOption] {
        [.init(title: "Chest", muscles: [.chest]), .init(title: "Back", muscles: [.back]),
         .init(title: "Shoulders", muscles: [.shoulders]), .init(title: "Arms", muscles: [.biceps, .triceps]),
         .init(title: "Legs", muscles: [.quads, .hamstrings]), .init(title: "Glutes", muscles: [.glutes]),
         .init(title: "Core", muscles: [.core])]
    }

    private var muscleFocusStep: some View {
        questionScaffold("Where do you want to grow?", subtitle: "Pick areas to emphasize. Your plan adds volume there.") {
            AnatomyGlowView(activation: vm.targetMuscles(), sex: vm.bodySex, sequential: false)
                .frame(height: 200).frame(maxWidth: .infinity)
                .reveal(cascade(0))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm), GridItem(.flexible())],
                      spacing: Theme.Space.sm) {
                ForEach(focusOptions, id: \.title) { opt in
                    let on = !vm.muscleFocus.isDisjoint(with: Set(opt.muscles))
                    Button { pick { toggleFocus(opt) } } label: {
                        Text(opt.title)
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .reveal(cascade(1))
        }
    }

    private func toggleFocus(_ opt: FocusOption) {
        let on = !vm.muscleFocus.isDisjoint(with: Set(opt.muscles))
        if on { opt.muscles.forEach { vm.muscleFocus.remove($0) } }
        else { opt.muscles.forEach { vm.muscleFocus.insert($0) } }
    }

    // MARK: Preferred days (optional)

    private var preferredDaysStep: some View {
        questionScaffold("Any preferred days?",
                         subtitle: "Optional. We'll fit your \(vm.daysPerWeek)-day week to these. Skip to auto-spread.") {
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { wd in
                    let on = vm.preferredDays.contains(wd)
                    Button { pick { if on { vm.preferredDays.remove(wd) } else { vm.preferredDays.insert(wd) } } } label: {
                        Text(weekdayLetter(wd))
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .reveal(cascade(0))
        }
    }

    private func weekdayLetter(_ wd: Int) -> String { ["S", "M", "T", "W", "T", "F", "S"][(wd - 1) % 7] }

    // MARK: Body metrics (optional)

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var ageDisplay: Int { vm.birthYear.map { currentYear - $0 } ?? 30 }
    // Weight is entered in the athlete's stored unit (kg elsewhere, lb in the US/UK) so onboarding
    // matches what the app shows afterward (finish() sets profile.weightUnit = WeightUnit.default()),
    // but is always STORED in kg (SI). Mirrors the runVolume step's km/mi localization.
    private var useMetricWeight: Bool {
        vm.weightUnitChoice.map { $0 == WeightUnit.kg.rawValue } ?? (WeightUnit.default() == .kg)
    }
    private var useMetricHeight: Bool { vm.heightMetricChoice ?? useMetricWeight }
    private var enteredMassKg: Double { vm.bodyMassKg ?? 72.5748 }        // default ≈ 160 lb ≈ 72.6 kg
    private var weightDisplayValue: Int {
        Int((useMetricWeight ? enteredMassKg : enteredMassKg * Formatters.lbPerKg).rounded())
    }

    private var metricsStep: some View {
        questionScaffold("A bit about you", subtitle: "Optional. Sharpens your calorie + heart-rate targets. Skip if you'd rather.") {
            sexSelector.reveal(cascade(0))
            metricRow("Age", "\(ageDisplay)",
                      typed: { if let a = Int($0.filter(\.isNumber)) { setAge(a) } },
                      { setAge(ageDisplay - 1) }, { setAge(ageDisplay + 1) }).reveal(cascade(1))
            // Height feeds the BMR that drives your fuel targets — the same Mifflin–St Jeor the Fuel
            // page uses; without it that estimate leans on an assumed 172 cm. Weight sits below it,
            // the two body figures together.
            metricRow("Height", heightDisplay,
                      units: (["ft·in", "cm"], useMetricHeight ? 1 : 0, { vm.heightMetricChoice = $0 == 1 }),
                      keyboard: .numbersAndPunctuation,
                      typed: { commitTypedHeight($0) },
                      { adjustHeight(-1) }, { adjustHeight(1) }).reveal(cascade(2))
            metricRow("Weight", "\(weightDisplayValue) \(useMetricWeight ? "kg" : "lb")",
                      units: (["lb", "kg"], useMetricWeight ? 1 : 0,
                              { vm.weightUnitChoice = ($0 == 1 ? WeightUnit.kg : WeightUnit.lb).rawValue }),
                      typed: { commitTypedWeight($0) },
                      { adjustWeight(useMetricWeight ? -2 : -5) }, { adjustWeight(useMetricWeight ? 2 : 5) }).reveal(cascade(3))
        }
    }

    private func setAge(_ a: Int) { vm.birthYear = currentYear - min(90, max(13, a)) }

    /// Height display + entry, matching the FuelGoalsSheet format exactly (5′8″ imperial / 172 cm
    /// metric) and unit choice (follows weight). Always STORED in cm (SI); nil until the athlete
    /// adjusts it, so skipping the step keeps the honest fallback rather than fabricating a height.
    private var enteredHeightCm: Double { vm.heightCm ?? FuelReadiness.fallbackHeightCm }
    private var heightDisplay: String {
        if useMetricHeight { return "\(Int(enteredHeightCm.rounded())) cm" }
        let inches = Int((enteredHeightCm / 2.54).rounded())
        return "\(inches / 12)′\(inches % 12)″"
    }
    /// Nudge height by `delta` in the DISPLAYED unit (cm metric / inches imperial). Imperial steps
    /// in whole inches so the shown value never drifts off a clean foot-inch reading.
    private func adjustHeight(_ delta: Double) {
        if useMetricHeight {
            vm.heightCm = min(230, max(120, (enteredHeightCm + delta).rounded()))
        } else {
            let inches = min(90, max(48, (enteredHeightCm / 2.54).rounded() + delta))
            vm.heightCm = inches * 2.54
        }
    }
    /// Typed height in the DISPLAYED unit: metric takes plain centimeters ("178"); imperial takes
    /// "5'10", "5 10", or bare inches ("70"). Bounds mirror the steppers'.
    private func commitTypedHeight(_ raw: String) {
        let cleaned = raw.replacingOccurrences(of: "″", with: "").replacingOccurrences(of: "\u{2032}", with: "'")
        if useMetricHeight {
            guard let cm = Double(cleaned.filter { $0.isNumber || $0 == "." }) else { return }
            vm.heightCm = min(230, max(120, cm.rounded()))
            return
        }
        let parts = cleaned.split { !$0.isNumber }.compactMap { Int($0) }
        let inches: Int?
        switch parts.count {
        case 1: inches = parts[0] >= 36 ? parts[0] : parts[0] * 12   // "70" = inches; "5" = 5 feet
        case 2: inches = parts[0] * 12 + parts[1]                    // "5 10" / "5'10"
        default: inches = nil
        }
        guard let inches else { return }
        vm.heightCm = Double(min(90, max(48, inches))) * 2.54
    }

    /// Typed weight in the DISPLAYED unit (kg or lb), same bounds as the steppers.
    private func commitTypedWeight(_ raw: String) {
        guard let value = Double(raw.filter { $0.isNumber || $0 == "." }) else { return }
        if useMetricWeight {
            vm.bodyMassKg = min(181, max(36, value.rounded()))
        } else {
            vm.bodyMassKg = min(400, max(80, value.rounded())) * Formatters.kgPerLb
        }
    }

    /// Nudge stored bodyMass by `delta` in the DISPLAYED unit (kg or lb), rounding + clamping in that
    /// unit so the shown number steps cleanly (2 kg / 5 lb); always persists kg.
    private func adjustWeight(_ delta: Double) {
        if useMetricWeight {
            vm.bodyMassKg = min(181, max(36, (enteredMassKg + delta).rounded()))
        } else {
            let lb = min(400, max(80, (enteredMassKg * Formatters.lbPerKg + delta).rounded()))
            vm.bodyMassKg = lb * Formatters.kgPerLb
        }
    }

    private var sexSelector: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(BiologicalSex.allCases) { s in
                let on = vm.sex == s
                Button { pick { vm.sex = on ? nil : s } } label: {
                    Text(s.label)
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                            if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One metric row: label · optional unit toggle · − [value] +. The value is TYPABLE when the
    /// caller passes `typed` (owner ask 2026-07-30 — steppers stay, but tapping the number opens a
    /// keyboard for the exact figure); the caller parses + clamps the raw text.
    private func metricRow(_ label: String, _ value: String,
                           units: (options: [String], index: Int, set: (Int) -> Void)? = nil,
                           keyboard: UIKeyboardType = .numberPad,
                           typed: ((String) -> Void)? = nil,
                           _ minus: @escaping () -> Void, _ plus: @escaping () -> Void) -> some View {
        // A row with a unit toggle carries five elements — tighter spacing and a slimmer value
        // well keep it on one line (the first cut wrapped "Height" to two lines).
        HStack(spacing: units == nil ? Theme.Space.md : Theme.Space.sm) {
            Text(label).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(1).fixedSize()
            if let units { unitToggle(units.options, selected: units.index, set: units.set).fixedSize() }
            Spacer(minLength: 4)
            // Repeats on press-and-hold — a high-mileage athlete adjusting from the seeded default
            // to their real number shouldn't need dozens of taps.
            Button { Haptics.light(); minus() } label: { metricStep("minus") }.buttonStyle(.plain)
                .buttonRepeatBehavior(.enabled)
                .accessibilityLabel("Decrease \(label)")
            if let typed {
                TypableNumber(display: value, keyboard: keyboard,
                              minWidth: units == nil ? 76 : 58, commit: typed)
                    .accessibilityLabel("\(label), \(value)")
            } else {
                Text(value).font(.display(20, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    .frame(minWidth: 76).contentTransition(.numericText())
                    .accessibilityLabel("\(label), \(value)")
            }
            Button { Haptics.light(); plus() } label: { metricStep("plus") }.buttonStyle(.plain)
                .buttonRepeatBehavior(.enabled)
                .accessibilityLabel("Increase \(label)")
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .animation(.snappy(duration: 0.2), value: value)
    }

    /// The compact unit switch (ft·in|cm, lb|kg) — two small capsule segments beside the label,
    /// quiet until you need them (owner ask 2026-07-30: unit choice belongs to the athlete, not
    /// the locale).
    private func unitToggle(_ options: [String], selected: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                let on = i == selected
                Button { if !on { Haptics.selection(); set(i) } } label: {
                    Text(option)
                        .font(.rounded(10, weight: .bold))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? .white : Theme.inkTertiary)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Capsule().fill(on ? AnyShapeStyle(Theme.purple) : AnyShapeStyle(.clear)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.background))
        .overlay(Capsule().stroke(Theme.hairline))
    }

    private func metricStep(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44).background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
    }

    // MARK: Commitment (the investment beat — hold the iridescent ring to commit)

    /// Hybrid athletes: where the week's emphasis sits (biases the run/lift day split) — the question
    /// that makes momentum understand a run-*and*-lift athlete instead of guessing from the goal.
    /// How the lifting week composes (2026-08-20) — same card grammar as the focus step. The
    /// coach's pick leads: most athletes should let the day count decide, and the explicit splits
    /// are there for the ones who know exactly how they like to train.
    private var strengthSplitStep: some View {
        let opts: [(StrengthSplitStyle, String, String, String)] = [
            (.coach, "Coach's pick", "Full body, splitting as your lift days grow", "wand.and.stars"),
            (.fullBody, "Full body", "Every lift day trains everything", "figure.strengthtraining.traditional"),
            (.upperLower, "Upper · Lower", "Alternating upper and lower days", "figure.arms.open"),
            (.pushPullLegs, "Push · Pull · Legs", "The classic three-day rotation", "dumbbell.fill")]
        return questionScaffold("How do you like to split your lifting?",
                                subtitle: "Change it anytime from your plan settings.") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                SelectionCard(title: o.1, subtitle: o.2, systemImage: o.3, isSelected: vm.strengthSplit == o.0) {
                    pick { vm.strengthSplit = o.0 }
                }
                .reveal(cascade(i))
            }
        }
    }

    private var hybridFocusStep: some View {
        let opts: [(HybridPriority, String, String, String)] = [
            (.running, "Running comes first", "Lift to support the miles", "figure.run"),
            (.balanced, "Balanced", "Both matter, side by side", "figure.run.circle"),
            (.lifting, "Lifting comes first", "Run to stay conditioned", "dumbbell.fill")]
        return questionScaffold("Run and lift: where's your focus?",
                                subtitle: "We'll weight your week toward it. Change it anytime.") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                SelectionCard(title: o.1, subtitle: o.2, systemImage: o.3, isSelected: vm.hybridPriority == o.0) {
                    pick { vm.hybridPriority = o.0 }
                }
                .reveal(cascade(i))
            }
        }
    }

    /// Race goal time — the target the athlete is chasing (drives the reveal + the race outlook).
    private var raceGoalTimeStep: some View {
        let raceLabel = vm.raceDistance?.label ?? "race"
        return questionScaffold("Chasing a time?",
                                subtitle: "Optional. Your goal for the \(raceLabel). We'll point the plan at it.") {
            metricRow("Hours", "\(vm.goalHours)",
                      typed: { if let h = Int($0.filter(\.isNumber)) { vm.goalHours = min(9, max(0, h)) } },
                      { vm.goalHours = max(0, vm.goalHours - 1) }, { vm.goalHours = min(9, vm.goalHours + 1) }).reveal(cascade(0))
            metricRow("Minutes", String(format: "%02d", vm.goalMinutes),
                      typed: { if let m = Int($0.filter(\.isNumber)) { vm.goalMinutes = min(59, max(0, m)) } },
                      { vm.goalMinutes = (vm.goalMinutes + 55) % 60 }, { vm.goalMinutes = (vm.goalMinutes + 5) % 60 }).reveal(cascade(1))
            if let t = vm.goalFinishTimeS, let m = vm.raceDistance?.meters, m > 0 {
                Text("That's about \(Formatters.pace(secPerKm: t / (m / 1000), unit: .auto)), a strong target.")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).reveal(cascade(2))
            }
        }
    }

    /// Notification opt-in — a Runna-style beat: an iPhone showing a real momentum workout reminder,
    /// the retention hook, and a single "Turn on reminders" that asks for permission.
    private var notificationsStep: some View {
        VStack(spacing: 0) {
            // The iPhone rises from the top of the screen; only its top half is drawn — the lower half
            // is masked to transparent so the device dissolves straight into the headline below.
            phoneNotificationMockup
                .frame(maxWidth: .infinity)               // center in the full width
                .frame(height: 372, alignment: .top)      // reserve only the top ~half in layout
                // A long, continuous dissolve — crisp through the notification, then many small,
                // even steps so the rate never visibly changes (no choppiness), vanishing on a soft tail.
                .mask(
                    LinearGradient(stops: [
                        .init(color: .black, location: 0.00),
                        .init(color: .black, location: 0.30),
                        .init(color: .black.opacity(0.97), location: 0.40),
                        .init(color: .black.opacity(0.92), location: 0.48),
                        .init(color: .black.opacity(0.84), location: 0.56),
                        .init(color: .black.opacity(0.74), location: 0.64),
                        .init(color: .black.opacity(0.62), location: 0.71),
                        .init(color: .black.opacity(0.49), location: 0.78),
                        .init(color: .black.opacity(0.36), location: 0.85),
                        .init(color: .black.opacity(0.23), location: 0.91),
                        .init(color: .black.opacity(0.11), location: 0.96),
                        .init(color: .clear, location: 1.00),
                    ], startPoint: .top, endPoint: .bottom)
                )
                .reveal(0.05)
            VStack(spacing: Theme.Space.sm) {
                (Text("You're ") + Text("2× more likely").fontWeight(.bold) + Text(" to finish your plan with reminders"))
                    .font(.serif(27, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A quiet nudge before each session keeps you on track. No spam. Just your plan.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Theme.Space.sm)
            .reveal(0.18)
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.sm) {
                OversizedButton(title: "Turn on reminders") {
                    // One-shot — a fast double-tap called goNext() twice and skipped a step.
                    guard !remindersAdvanced else { return }
                    remindersAdvanced = true
                    // Advance only AFTER the notifications prompt is dismissed, so the next page's
                    // location prompt lands on a settled screen instead of stacking on this one.
                    services.notifications.requestAuthorization {
                        goNext()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { remindersAdvanced = false }
                    }
                }
                Button {
                    // Same one-shot latch as "Turn on reminders" — during the settings round-trip
                    // before the system alert presents, this button used to stay live, and tapping
                    // it advanced once immediately and AGAIN from the alert's completion, skipping
                    // the location primer and stacking its prompt over the rating beat.
                    guard !remindersAdvanced else { return }
                    remindersAdvanced = true
                    Haptics.light()
                    goNext()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { remindersAdvanced = false }
                } label: {
                    Text("Maybe later").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
            }
            .reveal(0.3)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            notificationPopped = false
            // Let the phone settle in first, then the reminder arrives a beat later — the real moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(reduceMotion ? .easeIn(duration: 0.3)
                                           : .spring(response: 0.5, dampingFraction: 0.86)) {
                    notificationPopped = true
                }
            }
        }
    }

    /// A realistic iPhone caught mid-notification — Dynamic Island, a real status bar, and the momentum
    /// reminder as a frosted lock-screen banner at the top of the screen, on a dark wallpaper. Rendered
    /// at full height; the step masks the lower half so the device dissolves into the copy below.
    // A lock-screen-clock variant (big 9:41 + date, banner beneath) was built and REVERTED the same
    // day (owner call 2026-08-11) — the owner prefers this original staging; don't re-propose it.
    private var phoneNotificationMockup: some View {
        let unit = DistanceUnit.auto.resolved() == .imperial ? "3 mi" : "5 km"
        // Warm-graphite wallpaper, on-brand with the monochrome aesthetic (and the warm-charcoal dark
        // mode): a deep warm charcoal at the top so the reminder reads crisp, lifting to a warm near-
        // white at the bottom so the screen melts into the page instead of ending on a hard dark edge.
        let wallpaper = LinearGradient(stops: [
            .init(color: Color(red: 0.14, green: 0.13, blue: 0.12), location: 0.0),
            .init(color: Color(red: 0.27, green: 0.26, blue: 0.24), location: 0.30),
            .init(color: Color(red: 0.54, green: 0.53, blue: 0.51), location: 0.60),
            .init(color: Color(red: 0.87, green: 0.87, blue: 0.865), location: 0.85),
            .init(color: Color(red: 0.97, green: 0.97, blue: 0.965), location: 1.0),
        ], startPoint: .top, endPoint: .bottom)
        return RoundedRectangle(cornerRadius: 60, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))   // titanium rail
            .overlay {
                RoundedRectangle(cornerRadius: 52, style: .continuous)
                    .fill(wallpaper)
                    // A soft neutral highlight behind the notification for depth (no colour cast).
                    .overlay {
                        RadialGradient(colors: [Color.white.opacity(0.10), .clear],
                                       center: UnitPoint(x: 0.5, y: 0.26), startRadius: 2, endRadius: 210)
                            .blendMode(.screen)
                    }
                    // Status bar, flanking the island — the indicators clear the island's right edge
                    // (island is 92pt wide/centred; the icons live in the right ~62pt), like real iOS.
                    .overlay(alignment: .top) {
                        HStack(spacing: 0) {
                            Text("9:41").font(.system(size: 14, weight: .semibold, design: .rounded))
                            Spacer(minLength: 0)
                            HStack(spacing: 5) {
                                Image(systemName: "cellularbars")
                                Image(systemName: "wifi")
                                Image(systemName: "battery.75")
                            }.font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.top, 21)
                    }
                    // The reminder slides down from above as ONE solid, opaque unit (hidden by the
                    // screen's clip, not by fading — so no part of it appears on its own timing), and
                    // settles with a gentle spring, exactly like a real iOS banner. Reduce Motion fades.
                    .overlay(alignment: .top) {
                        lockNotification(unit)
                            .padding(.horizontal, 14).padding(.top, 64)
                            .offset(y: (notificationPopped || reduceMotion) ? 0 : -155)
                            .opacity(reduceMotion ? (notificationPopped ? 1 : 0) : 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 52, style: .continuous))
                    .padding(6)   // bezel thickness
            }
            .overlay(alignment: .top) {
                Capsule().fill(.black).frame(width: 92, height: 31).padding(.top, 15)   // dynamic island
            }
            .frame(width: 300, height: 640)
            .accessibilityHidden(true)   // no shadow: it should dissolve into the page, not float on a halo
    }

    /// One iOS lock-screen notification: a light frosted panel with dark text (forced light so it reads
    /// like the real thing on the dark wallpaper, whatever the app's appearance).
    private func lockNotification(_ unit: String) -> some View {
        HStack(spacing: 11) {
            Image("BrandIcon").resizable().scaledToFit().frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("MOMENTUM").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(0.5)
                    Spacer()
                    Text("now").font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.secondary)
                Text("Time for today's run").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
                Text("Easy run · \(unit), ~30 min").font(.system(size: 13, weight: .regular, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .light)   // a light frosted panel on the dark wallpaper, like real iOS
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var primersStep: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            BrandMark(size: 96)
            // This beat is ONLY about location. It used to read "You're all set" / "Start training"
            // from when it genuinely ended onboarding — three beats (rateUs → paywall → account) have
            // since been added after it, so that copy promised a finish the flow doesn't deliver and
            // made everything past it feel like an ambush. Headline and CTA both stay neutral: if
            // this ever becomes the last step again, that's the moment to promise an ending.
            VStack(spacing: Theme.Space.sm) {
                Text("Map your runs")
                    .font(.serif(Theme.FontSize.title, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("We use your location to trace your route and open the map right where you are.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.15)
            Spacer()
            // Hands off to `rateUs`, which is the last beat before the paywall (2026-07-26).
            OversizedButton(title: "Continue") { goNext() }
                .reveal(0.3)
        }
        // Ask for location only AFTER this page is visibly on screen — the athlete reads WHY (their
        // map centered on them) first, THEN the system prompt appears. The brief beat also guarantees
        // the prior notifications prompt has cleared, so the two never stack (user report 2026-07-24).
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                // Tapping Continue inside the 0.55s window used to fire the system prompt over the
                // NEXT beat (the rating ask), which reads as a random permission grab on a screen
                // that says nothing about location. Only ask if this step is still the one on screen.
                guard vm.step == .primers else { return }
                let loc = locator ?? LocationService()
                locator = loc
                loc.requestAuthorization()
            }
        }
    }

    /// The last onboarding beat: an ask for an App Store rating, immediately before the paywall.
    ///
    /// ⚠️ App Review guideline 5.6.3 — "don't require or encourage customers to submit a rating" —
    /// and this app has already been rejected once for a rating beat in onboarding. This ships at
    /// the owner's explicit, informed direction. If a submission comes back rejected, delete the
    /// `.rateUs` case from `Step` and this view; `primersStep`'s button calls `finishOnboarding()`
    /// directly and nothing else changes (the paywall → `.account` hand-off is unaffected).
    ///
    /// Skippable by design: "Not now" is a real, equally-reachable control, and the native alert is
    /// Apple's own `requestReview` (the only sanctioned way to open it) — we never fake stars, never
    /// gate anything behind rating, and never route unhappy athletes anywhere but onward.
    private var rateUsStep: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()

            HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { i in
                    // Filled, matching RatingPromptView (owner's call — outlined was tried and
                    // reverted 2026-07-26).
                    Image(systemName: "star.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.proLavender)
                        .opacity(rateStarsIn ? 1 : 0)
                        .scaleEffect(rateStarsIn ? 1 : 0.7)
                        .animation(reduceMotion ? nil
                                   : .spring(response: 0.4, dampingFraction: 0.7).delay(0.1 + Double(i) * 0.07),
                                   value: rateStarsIn)
                }
            }
            .accessibilityHidden(true)

            // Copy order is deliberate: the athlete's own experience first (what they just built),
            // the ask second. Wording is the owner's call (2026-07-26) — "runners", not "users".
            // Note for anyone auditing this later: the closing clause does encourage a rating, which
            // is the behaviour App Review 5.6.3 names, and this app has been rejected under that rule
            // before. That trade-off was made knowingly; see the warning on OnboardingViewModel.Step.
            VStack(spacing: Theme.Space.sm) {
                Text("Your plan is ready")
                    .font(.serif(Theme.FontSize.title, weight: .semibold)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A quick rating helps the next runner find theirs.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .reveal(0.15)

            Spacer()

            VStack(spacing: Theme.Space.xs) {
                OversizedButton(title: "Rate momentum") {
                    // One-shot: during the 1.2s settle the button used to look simply dead when the
                    // rate-limited system alert chose not to appear — dimming it acknowledges the
                    // tap (and a second tap re-firing requestReview was pointless anyway).
                    guard !rateWorking else { return }
                    withAnimation(.easeOut(duration: 0.15)) { rateWorking = true }
                    // Apple's own alert — the only sanctioned way to open it. It is rate-limited by
                    // the system and may not appear; the flow must continue either way, so we never
                    // wait on it or branch on whether it showed.
                    requestReview()
                    // Latch the once-ever guard so the post-first-save pre-prompt doesn't ask the
                    // same athlete again a few days later.
                    AppReview.markAsked()
                    // Let the system alert settle before the paywall cover animates in over it —
                    // two modals racing on the same frame is how you get a stuck screen.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { finishOnboarding() }
                }
                .opacity(rateWorking ? 0.45 : 1)
                .disabled(rateWorking)
                Button {
                    Haptics.light()
                    finishOnboarding()
                } label: {
                    Text("Not now")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .reveal(0.3)
        }
        .onAppear {
            if reduceMotion { rateStarsIn = true }
            else { withAnimation { rateStarsIn = true } }
        }
    }

    /// The last beat (2026-07-27): the account, offered — never required.
    ///
    /// The athlete has been a guest for this whole flow, and everything they built is already on
    /// disk (`finish()` ran back at `.building`), so declining costs them nothing but cloud backup
    /// and Settings keeps the door open forever. This is deliberately in-flow content rather than
    /// another cover: the paywall cover has to dismiss before this can show, and a cover raised
    /// from another cover's teardown is exactly the presentation race this file already works
    /// around twice.
    private var accountStep: some View {
        AccountOptionsView(
            presentation: .onboardingBeat,
            onSkip: { complete() },
            onSignedIn: {
                // Nothing else ever writes the account's name onto the profile — do it here when
                // onboarding left the field blank (`OnboardingViewModel.finish` is the only other
                // writer, and it can no longer prefill from auth: there was no account yet).
                if let known = auth.displayName, !known.isEmpty,
                   let profile, profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                    profile.displayName = known
                    try? context.save()
                }
                // Let the Apple/Google sheet finish dismissing before this cover tears down — two
                // modals resolving on one frame is the stuck-screen bug `rateUsStep` already
                // works around above.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { complete() }
            })
    }

    /// Where onboarding actually ends: the paywall gate (or straight through for entitled athletes),
    /// then the account beat. Was inline in `primersStep` before `.rateUs` was inserted between them.
    private func finishOnboarding() {
        if paywall.isPro { goToAccountBeat(); return }
        // Arm the relaunch gate BEFORE presenting — not to wall anyone in (the gate is soft now),
        // but so a force-quit mid-wall re-offers it once from RootView instead of dropping the
        // athlete into the app with the account beat silently skipped. `setPro(true)` or the
        // flow's X clears it.
        paywall.onboardingGatePending = true
        showPaywall = true
    }

    /// Hand off to the final account beat — unless there's already a real account on this device
    /// (they came in through "I already have an account" at the welcome, or a demo/UI-test launch
    /// arg is driving the flow as `demo-user`). Asking someone to sign in twice is worse than not
    /// asking at all.
    private func goToAccountBeat() {
        if auth.isSignedIn, !auth.isGuest { complete(); return }
        goNext()
    }

    /// Onboarding is over — clear the resume draft BEFORE handing off, or the stale draft
    /// (saved on every step change, including the post-plan beats) resurrects the tail of the
    /// flow the next time RootView sees no profile — e.g. right after Settings → Delete all
    /// data, which used to loop the athlete into a plan-less "Save your progress" forever
    /// (audit 2026-08-11).
    private func complete() {
        OnboardingDraftStore.clear()
        onComplete()
    }

    /// The paywall's exit (purchase or the X), sequenced so nothing stale peeks through: advance
    /// to the account beat FIRST, under the still-presented cover, then dismiss — the dismissal
    /// reveals "Save your progress" directly instead of flashing the rating step for the length
    /// of the animation. Signed-in athletes have no account beat to advance to, so the whole flow
    /// completes in ONE dismissal (`onComplete` tears down the onboarding cover with the paywall
    /// still nested inside it) rather than two stacked ones.
    private func exitPaywall() {
        paywallHandledExit = true
        if auth.isSignedIn, !auth.isGuest { complete(); return }
        // Jump-cut, not travel: the advance happens under the still-presented cover, and if it
        // animates, the cover's dismissal reveals a half-finished crossfade — the rating step
        // ghosting through "Save your progress" (frame-stepped 2026-08-11). Compose the account
        // beat instantly, then let the cover's own dismissal be the only motion on screen.
        jumpCut = true
        goNext()
        showPaywall = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { jumpCut = false }
    }

    // MARK: Scaffolding

    @ViewBuilder
    private func questionScaffold<C: View>(_ title: String, subtitle: String? = nil,
                                           @ViewBuilder _ content: () -> C) -> some View {
        // One scroll for the whole question (title + options together) — the reliable pattern that
        // always scrolls when the content overflows (the disciplines picker etc.). The serif title
        // carries the welcome page's editorial voice through the flow; options stay in the clean UI face.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(title)
                        .font(.serif(33, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(spacing: Theme.Space.sm) { content() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.Space.md)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Staggered entrance delay for the i-th element on a screen — the assemble cascade.
    private func cascade(_ i: Int) -> Double { 0.08 + Double(i) * 0.06 }

    /// Apply a selection and, on the *first* pick of a screen, flash the affirmation micro-reward.
    private func pick(_ apply: () -> Void) {
        let firstTouch = !touchedSteps.contains(vm.step)
        apply()
        guard firstTouch else { return }
        touchedSteps.insert(vm.step)
        let lines = ["Got it.", "Nice pick.", "That shapes your plan.", "Noted."]
        let line = lines[abs(vm.step.rawValue) % lines.count]
        withAnimation(Motion.standard) { affirmation = line }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if affirmation == line { withAnimation(Motion.exit) { affirmation = nil } }
        }
    }

    /// Directional travel between steps: forward slides in from the right, back from the left.
    /// Reduce Motion drops the offset to a plain crossfade.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let dx: CGFloat = 28
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: goingBack ? -dx : dx)),
            removal: .opacity.combined(with: .offset(x: goingBack ? dx : -dx))
        )
    }

    /// Paces the "building your plan" beat and — crucially — controls exactly when it advances, so the
    /// animation ALWAYS plays in full. The lead-in lines tick off with the main thread free (perfectly
    /// smooth); the real plan generation (`finish`, which briefly blocks the main thread) runs behind
    /// the last "Finalizing" line, where a spinner is *expected* to spin — so its cost is never a
    /// visible freeze mid-tick. Only after the plan exists and the ring/checklist have settled does it
    /// reveal. This is the single source of timing truth (the old self-timed view could be outrun by
    /// `finish` and cut the animation short — the bug the athlete kept seeing).
    private func buildPlan() async {
        let lines = vm.buildingLines()
        let n = max(1, lines.count)

        func generate() {
            guard profile == nil else { return }
            profile = vm.finish(in: context)
            OnboardingDraftStore.clear()   // onboarding succeeded — nothing left to resume
            services.analytics.log(.planGenerated(disciplines: profile?.disciplines.count ?? 0))
            SKANConversion.record(.planBuilt)   // activation, for ad-campaign optimisation
        }

        // Reduce Motion: no ticking theatre — build, show the finished state, hold briefly, reveal.
        if UIAccessibility.isReduceMotionEnabled {
            generate()
            buildCompleted = n; buildRing = 1
            try? await Task.sleep(for: .seconds(0.5))
            goNext(); return
        }

        let tick = 0.5
        // The ring fills continuously to ~85% across the lead-in lines (Core Animation — stays smooth
        // no matter what the main thread does); the final 15% lands once the plan is actually built.
        withAnimation(.easeInOut(duration: Double(max(1, n - 1)) * tick + 0.3)) { buildRing = 0.85 }
        // Tick the lead-in lines one at a time; the last line stays spinning for the real work.
        for i in 0..<(n - 1) {
            try? await Task.sleep(for: .seconds(tick))
            withAnimation(.easeOut(duration: 0.35)) { buildCompleted = i + 1 }
        }
        // "Finalizing your plan" is the spinning row now — generate behind it (main-thread cost hidden).
        generate()
        // Land the last checkmark + complete the ring, hold on the finished state, then reveal.
        withAnimation(.easeOut(duration: 0.4)) { buildCompleted = n; buildRing = 1 }
        try? await Task.sleep(for: .seconds(0.85))
        goNext()
    }
}
