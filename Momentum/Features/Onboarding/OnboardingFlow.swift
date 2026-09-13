import SwiftUI
import SwiftData
import PhotosUI
import UIKit   // UIAccessibility.isReduceMotionEnabled in the building beat

/// Onboarding → plan reveal (PRD §4.1, §7.1) — the conversion engine. Cal-AI-grade structure
/// (continuous progress, back chevron, one bold question per screen, tactile cards, a pinned
/// Continue, an anticipation "building" beat, a celebratory reveal) rendered in momentum's
/// monochrome + earned-iridescence identity.
struct OnboardingFlow: View {
    /// Called when the flow ends and the app takes over.
    ///
    /// The saved first week leads to an optional native review ask, then checkout and Today.
    /// Account and permission setup remain contextual in the app.
    /// True only when raised from the welcome, mid-hand-off (`WelcomeGalleryView.Handoff`): the
    /// cover then plays the tail of the welcome's exit itself — the landed icon holding, then its
    /// burst (`WelcomeHandoffBurst`) — and the content surfaces beneath it a third of the way
    /// into that burst. False through every other door.
    var arrivingFromWelcome = false
    var onComplete: () -> Void
    /// Seconds to stay invisible after presentation before the content is inserted and fades up.
    private var revealDelay: Double { arrivingFromWelcome ? WelcomeGalleryView.Handoff.revealDelayS : 0 }

    /// Through every door but the welcome the flow is fully present on its FIRST frame. The
    /// flags start true when there is no arrival to stage: a first frame rendered at opacity 0
    /// and then switched on was enough to break the paywall cover presented later from inside
    /// this view (bisected 2026-09-05) — the hierarchy has to be born visible, not turned on.
    init(arrivingFromWelcome: Bool = false, onComplete: @escaping () -> Void) {
        self.arrivingFromWelcome = arrivingFromWelcome
        self.onComplete = onComplete
        _revealed = State(initialValue: !arrivingFromWelcome)
        _burstSpent = State(initialValue: !arrivingFromWelcome)
    }

    @Environment(\.modelContext) private var context
    @ReducedMotionPreference private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(Services.self) private var services
    @Environment(AuthController.self) private var auth
    @Environment(PaywallController.self) private var paywall
    @Environment(\.scenePhase) private var scenePhase
    /// The native App Store sheet, raised by the review beat after the reveal (owner call
    /// 2026-09-05). Held here so the page stays a plain previewable view.
    @Environment(\.requestReview) private var requestReview
    /// The athlete left the location primer. Anything the beat scheduled can't key off `vm.step`
    /// alone — without this latch a fast Continue can put the system prompt on top of plan building.
    @State private var leftPrimers = false
    @State private var pickedOnboardingAvatar: PhotosPickerItem?
    /// The curated look picked on the identity beat (ring in the strip); cleared by a photo pick.
    @State private var onboardingPreset: AvatarPreset?
    // Resumes a draft when a prior onboarding was interrupted before the profile was created;
    // fresh otherwise. See OnboardingDraft.
    @State private var vm = OnboardingViewModel.resuming()
    @State private var profile: UserProfile?
    @State private var goingBack = false
    @State private var showSupportingActivities = false
    @State private var showSessionLimits = false
    @State private var showApproachOptions = false
    @State private var showStrengthPreferences = false
    @State private var generationInFlight = false
    @State private var revealTracked = false
    /// Request location on the final primer. Created on THAT tap, not at init: this view is
    /// re-initialized whenever RootView's body re-evaluates (cover content closures re-run), and a
    /// fresh `CLLocationManager` per pass was pure waste (perf audit 2026-08-13). Held in @State so
    /// the manager outlives the authorization prompt it raises.
    @State private var touchedSteps: Set<OnboardingViewModel.Step> = []  // preserve explicit choices over recommendations
    @State private var showPaywall = false           // the `onboarding_complete` paywall — the last beat, before the app
    @State private var paywallHandledExit = false    // exitPaywall ran — onDismiss must not advance again
    @State private var notificationPopped = false     // notifications step: the reminder banner slides in like real iOS
    @State private var healthRequestInFlight = false  // one-shot gate: a double-tap advanced two steps
    @State private var remindersAdvanced = false      // same for the reminders primer
    @State private var locationRequestInFlight = false // wait for the real Core Location response
    @State private var lastStepChangeAt = Date.distantPast   // double-tap guard for goNext/goBack
    /// True while the paywall's exit advances the step UNDER the still-presented cover — the
    /// travel animation is suppressed so the account beat is fully composed before the cover
    /// dismisses (the mid-flight crossfade used to ghost the step underneath through it).
    @State private var jumpCut = false
    @State private var showRacePicker = false        // race step: the catalog of storied marathons
    @State private var showOtherActivities = false
    @State private var showGoalTime = false
    @State private var showTrainingAssessment = false
    @State private var handleUnavailable = false
    @State private var buildFailed = false
    @State private var draftBenchmark: RunBenchmark = .fiveK
    @State private var draftRunSeconds: Double = 1800
    @State private var resultTimeEntered = false
    @State private var draftResultDate: Date?
    @State private var showTimeEntry = false         // calibration: reveal the "recent time" entry
    @State private var briefSealed = false            // approach step: the seal's one bounce after arrival
    @State private var buildCompleted = 0            // building beat: lines checked (parent-paced)
    @State private var buildRing = 0.0               // building beat: ring fill 0…1 (parent-paced)
    @State private var completedOnce = false         // the completion hand-off ran — never twice
    @State private var lastLoggedStep: OnboardingViewModel.Step? // `.onChange` cannot see screen one
    /// The arrival out of the welcome: the whole flow fades up from the white it was handed.
    /// The welcome's burst has finished playing on this cover and its landing layer is gone.
    @State private var burstSpent = false
    /// Content is inserted only at the reveal, so its entrance cascades play when they can be seen.
    @State private var revealed = false

    var body: some View {
        ZStack {
            // The arrival out of the welcome fades each layer INSIDE the hierarchy — canvas,
            // content, continue bar — and never the root chain: an animated `.opacity` on the
            // root silently broke the paywall cover presented from `finishOnboarding` (a nested
            // cover raised from beneath a compositing modifier never appeared; bisected 2026-09-05).
            // The canvas is there from the FIRST frame, through every door: the cover keeps the
            // system presentation backdrop (a custom one, even opaque white, swallowed taps on
            // content still at opacity 0 — the reveal's CTA in its overture; 2026-09-05), and
            // that backdrop follows the device appearance, so the canvas is what keeps a dark
            // device from flashing charcoal under the light flow.
            OnboardingCanvas()
            if revealed { Group {
            if vm.step == .building {
                // A calm, centered loader — renders full-bleed so it escapes the flow's padding.
                // `buildPlan` starts immediately and reveals the saved result as soon as it is ready.
                BuildingPlanView(lines: ["Saving your first week"], completed: buildCompleted, ringProgress: buildRing)
                    .task { await buildPlan() }
                    .transition(.opacity)
            } else if vm.step == .reveal {
                // Full-bleed too: the reveal's scroll runs under the status bar (its aurora crown
                // and a top scrim live there), so it escapes the question column's padding.
                // The personal briefing leads to the review page; its Continue opens checkout.
                PlanRevealView(vm: vm, profile: profile) { continueFromReveal() }
                    .onAppear {
                        guard !revealTracked else { return }
                        revealTracked = true
                        services.analytics.log(.onboardingMilestone(action: "reveal_visible", step: "reveal", durationMs: nil))
                    }
                    .transition(.opacity)
            } else if vm.step == .review {
                // Keep the CTA outside entrance transforms and the question column's padding.
                reviewPage
            } else {
                VStack(spacing: 12) {
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
            // Inserted with a TRANSITION rather than driven by a persistent `.opacity`: a
            // state-driven opacity anywhere in this tree left the reveal's continue button deaf
            // to taps and the paywall cover never presented (bisected 2026-09-05). A transition
            // animates the same fade and leaves no modifier behind once it lands.
            // Opacity ONLY. A transition carrying `.offset` — even one that never plays, on a
            // deep-linked reveal — left the reveal's ScrollView un-hittable under motion
            // (`OnboardingNoRatingUITests`, 2026-09-05); the Reduce Motion path, which had no
            // offset, was fine. The 12 pt rise is not worth a dead page.
            .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if revealed, isQuestion { continueBar.transition(.opacity) }
        }
        // The welcome's burst, finished HERE (`WelcomeGalleryView.Handoff`): the landed icon on
        // its glow, centred where the welcome left it, then the burst over the arriving question.
        // Applied after the inset so its centre is the full safe area's — the continue bar
        // arriving mid-burst must not shift it. A conditional that empties, never a persistent
        // compositing modifier on this chain (see the note in `body`).
        .overlay {
            if !burstSpent {
                WelcomeHandoffBurst(onReveal: { revealNow() }, onSpent: { burstSpent = true })
            }
        }
        .animation(jumpCut ? nil : (reduceMotion ? Motion.crossfade : OnboardingStyle.pageTransition), value: vm.step)
        .onAppear {
            reveal()
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
            // The mileage-ceiling row (2026-08-28) and the honesty line when the cap is under the goal.
            if args.contains("--onboarding-volume") {
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .marathon; vm.hasRace = true
                vm.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 20, to: Date()) ?? Date()
                vm.experience = .some; vm.weeklyRunVolumeM = 40_000; vm.longestRunM = 16_000
                vm.step = .runVolume
            }
            if args.contains("--onboarding-intensity-capped") {
                vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .marathon; vm.hasRace = true
                vm.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 20, to: Date()) ?? Date()
                vm.goalHours = 3; vm.goalMinutes = 0
                vm.experience = .some; vm.calibrationMode = .feel; vm.paceFeel = .regular
                vm.weeklyRunVolumeM = 40_000; vm.longestRunM = 16_000; vm.targetWeeklyRunVolumeM = 64_000
                vm.intensity = .aggressive; vm.step = .intensity
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
            if args.contains("--onboarding-account") { vm.step = .account }
            // The review beat. The native sheet is a system surface the sim renders unreliably
            // (StoreKit rate-limits it), so this verifies the PAGE; check the sheet on device.
            if args.contains("--onboarding-review") { vm.name = "Maya"; vm.step = .review }
            if args.contains("--onboarding-goal") { vm.name = "Maya"; vm.step = .goal }
            if args.contains("--onboarding-units") { vm.name = "Maya"; vm.activities = [.run]; vm.step = .units }
            if args.contains("--onboarding-experience") { vm.activities = [.run]; vm.step = .experience }
            if args.contains("--onboarding-experience-hybrid") { vm.activities = [.run, .strength]; vm.step = .experience }
            if args.contains("--onboarding-metrics") { vm.activities = [.run]; vm.step = .metrics }
            if args.contains("--onboarding-race") { vm.activities = [.run]; vm.goal = .raceDistance; vm.step = .race }
            if args.contains("--onboarding-musclefocus") { vm.activities = [.strength]; vm.goal = .buildMuscle; vm.step = .muscleFocus }
            if args.contains("--onboarding-days") { vm.activities = [.run]; vm.step = .days }
            if args.contains("--onboarding-preferreddays") { vm.activities = [.run]; vm.daysPerWeek = 4; vm.step = .preferredDays }
            if args.contains("--onboarding-session") { vm.activities = [.strength]; vm.step = .session }
            if args.contains("--onboarding-session-runner") { vm.activities = [.run]; vm.step = .session }
            if args.contains("--onboarding-equipment") { vm.activities = [.strength]; vm.step = .equipment }
            if args.contains("--onboarding-split") { vm.activities = [.strength]; vm.step = .strengthSplit }
            if args.contains("--onboarding-why") { vm.activities = [.run]; vm.step = .why }
            if args.contains("--onboarding-primers") { vm.activities = [.run]; vm.step = .primers }
            vm.step = OnboardingViewModel.currentStep(for: vm.step)
            #endif
            UserDefaults.standard.set("activation_v2", forKey: "analytics.onboarding.flow")
            logOnboardingStep(vm.step)
        }
        .onChange(of: vm.step) { _, step in
            Haptics.light()   // the screen landing — one light tick per step, so travel has feel
            logOnboardingStep(step)
            // The reveal→review jump cut has landed by the time this runs; the permission beats
            // after it travel normally. Cleared on the next turn so this change keeps its cut.
            if step == .review, jumpCut { DispatchQueue.main.async { jumpCut = false } }
            // Checkpoint on every navigation — the draft now holds every answer made up to and
            // including the step just left, so an eviction resumes here, not at question one.
            saveDraftIfEnabled()
        }
        // Capture the very latest answers the instant the app leaves the foreground — the moment
        // iOS is most likely to evict a backgrounded app, and the one a step-change wouldn't cover
        // (answers changed on the current step before tabbing away).
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveDraftIfEnabled() } }
        // Purchase/Restore enters Today. A genuine store outage may defer the persisted gate
        // for this launch; an ordinary dismissal can never complete an unpaid onboarding.
        .fullScreenCover(isPresented: $showPaywall, onDismiss: {
            if !paywallHandledExit, paywall.isPro || paywall.storeUnreachableDeferral { complete() }
            paywallHandledExit = false
        }) {
            OnboardingPaywallFlow(
                startAtCheckout: true,
                personalizedOutcome: vm.projectedOutcome(),
                onEntitled: { exitPaywall() })
        }
        .alert("Your answers are safe", isPresented: $buildFailed) {
            Button("Try again") { Task { await buildPlan() } }
            Button("Review answers", role: .cancel) { vm.step = .days }
        } message: {
            Text("We couldn't save your plan. Try again to finish building it.")
        }
        .trackScreen(.onboarding)
    }

    private var isQuestion: Bool { vm.isQuestionStep }

    // MARK: Header (back + progress)

    private var header: some View {
        VStack(spacing: Theme.Space.sm) {
            HStack {
                GlassCircleButton(systemName: "chevron.left", label: "Back") { goBack() }
                    .opacity(vm.canGoBack ? 1 : 0)
                    .disabled(!vm.canGoBack)
                    .accessibilityHidden(!vm.canGoBack)
                Spacer(minLength: Theme.Space.xs)
                Text(vm.chapterTitle)
                    .font(.rounded(10, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(Theme.purple)
                    .contentTransition(.opacity)
                    .animation(Motion.crossfade, value: vm.chapterTitle)
                Spacer(minLength: Theme.Space.xs)
                Menu {
                    Picker("Distance units", selection: distanceUnitBinding) {
                        Text("Kilometres").tag(DistanceUnit.metric)
                        Text("Miles").tag(DistanceUnit.imperial)
                    }
                } label: {
                    Text(distanceUnitLabel)
                        .font(.rounded(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 46, height: 46)
                }
                .accessibilityLabel("Distance units, \(distanceUnitLabel)")
                .accessibilityIdentifier("onboarding.distanceUnits")
                .opacity(vm.step == .name ? 0 : 1)
                .disabled(vm.step == .name)
                .accessibilityHidden(vm.step == .name)
            }
            Capsule().fill(Theme.hairline)
                .overlay(alignment: .leading) {
                    Capsule()
                        // Plain brand purple (owner call 2026-09-05): progress is "happening now",
                        // which is exactly what lavender means app-wide. No gradient on the line.
                        .fill(Theme.purple)
                        .scaleEffect(x: vm.progress, y: 1, anchor: .leading)
                        .animation(reduceMotion ? nil : OnboardingStyle.progress, value: vm.progress)
                }
                .frame(height: 3)
                .overlay {
                    GeometryReader { geometry in
                        Circle().fill(Theme.purple)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .offset(x: max(0, min(geometry.size.width - 7,
                                                geometry.size.width * vm.progress - 3.5)), y: -2)
                            .animation(reduceMotion ? nil : OnboardingStyle.progress, value: vm.progress)
                    }
                    .accessibilityHidden(true)
                }
                .accessibilityLabel("Setup progress")
                .accessibilityValue("\(Int(vm.progress * 100)) percent")
        }
        .padding(.top, Theme.Space.xs)
    }

    private var continueBar: some View {
        OnboardingCTA(title: "Continue", isEnabled: vm.canAdvance && !(vm.step == .name && handleUnavailable)) { goNext() }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.sm)
            // A soft rise into the canvas so scrolled options dissolve under the button, no edge.
            .background(
                LinearGradient(colors: [OnboardingStyle.canvas(colorScheme).opacity(0),
                                        OnboardingStyle.canvas(colorScheme), OnboardingStyle.canvas(colorScheme)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -Theme.Space.lg)
                    .ignoresSafeArea())
    }

    /// One advance per gesture: a fast double-tap on any Continue used to skip a whole step —
    /// and from the primers beat it skipped the RATING and armed no paywall (audit 2026-08-11).
    /// Any second advance/back inside the travel animation's window is the same gesture, not a
    /// decision; swallow it. Programmatic advances (buildPlan, the reminders/health completions,
    /// exitPaywall) all arrive ≥0.55s after the previous step change, so none can be swallowed.
    private func goNext() {
        guard vm.canAdvance, Date().timeIntervalSince(lastStepChangeAt) > 0.45 else { return }
        lastStepChangeAt = Date()
        goingBack = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        services.analytics.log(.onboardingMilestone(action: "step_continue", step: String(describing: vm.step), durationMs: nil))
        vm.advance()
    }
    /// The flow moving ITSELF — the build handing to the reveal. It must not arm the double-tap
    /// guard: under Reduce Motion the reveal's CTA is live on its first frame, and once the
    /// reveal handed forward through `goNext` (the review beat, 2026-09-05) a tap inside the
    /// 0.45 s window after arrival was silently dropped. The guard is for a finger, not a timer.
    private func advanceAutomatically() {
        goingBack = false
        vm.advance()
    }
    private func goBack() {
        guard Date().timeIntervalSince(lastStepChangeAt) > 0.45 else { return }
        lastStepChangeAt = Date()
        goingBack = true
        vm.back()
    }

    private func logOnboardingStep(_ step: OnboardingViewModel.Step) {
        guard lastLoggedStep != step else { return }
        lastLoggedStep = step
        UserDefaults.standard.set(vm.goal.rawValue, forKey: "analytics.onboarding.goal")
        UserDefaults.standard.set(vm.runningBackgroundChosen ? (vm.returningRunner ? "returning" : vm.experience.rawValue) : "unknown", forKey: "analytics.onboarding.background")
        let position = (vm.steps.firstIndex(of: step) ?? 0) + 1
        services.analytics.log(.onboardingStep(
            name: String(describing: step),
            index: step.rawValue,
            position: position,
            total: vm.steps.count))
    }

    /// Persist the interruption-recovery draft, unless a deep link is driving the flow (those set a
    /// specific step for verification and must stay deterministic — no stray draft written or read).
    /// Save the small snapshot in navigation order, before a later step or clear can overtake it.
    private static let deepLinkDriven =
        ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--onboarding-") })
    /// `--review-no-ask`: hold the review beat's native sheet so a UI test can read the page
    /// underneath it (a system surface answers no queries and covers every one of ours). Read once
    /// — the router would otherwise scan the argument list on every body pass.
    static let reviewAskSuppressed =
        ProcessInfo.processInfo.arguments.contains("--review-no-ask")
    private func saveDraftIfEnabled() {
        guard !Self.deepLinkDriven, profile == nil else { return }
        // This tiny snapshot is saved synchronously: step saves and clear cannot overtake one another.
        OnboardingDraftStore.save(vm.draft())
    }

    // MARK: Content router

    @ViewBuilder
    private var content: some View {
        switch vm.step {
        case .name: nameStep
        case .identity: identityStep
        case .goal: goalStep
        case .units: unitsStep
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
        case .reveal: EmptyView()      // rendered full-bleed in `body`, like `.building`
        // Keeps the athlete's own plan in view all the way into checkout, with one beat between:
        // the ask, which raises the native sheet on arrival and then hands on to the paywall.
        case .review: reviewPage
        case .notifications: notificationsStep
        case .primers: primersStep
        case .account: accountStep
        }
    }


    // MARK: Question steps

    private var disciplinesStep: some View {
        let programmed = ActivityChoice.allCases.filter { $0.isProgrammed && $0 != .run }
        let extras = ActivityChoice.allCases.filter { !$0.isProgrammed }
        return questionScaffold("What supports your running?",
                                subtitle: "Choose the activities you want alongside your runs.") {
            activitySectionLabel("YOUR FOUNDATION")
            ChoiceCard(title: "Run", subtitle: "Included in every Momentum coaching plan",
                       systemImage: ActivityChoice.run.icon, isSelected: true, multi: true) {}
                .allowsHitTesting(false)
                .accessibilityRemoveTraits(.isButton)
                .accessibilityHint("Running is included in every coaching plan")
                .onboardingEntrance(cascade(0))
            activitySectionLabel("ADD TO YOUR PLAN").padding(.top, Theme.Space.xs)
            ForEach(Array(programmed.enumerated()), id: \.element) { i, a in
                activityCard(a).onboardingEntrance(cascade(i + 1))
            }
            detailButton("Other activities",
                         value: vm.activities.isDisjoint(with: extras) ? "Optional" : "\(vm.activities.intersection(extras).count) selected",
                         systemImage: "plus") { showOtherActivities = true }
        }
        .sheet(isPresented: $showOtherActivities) {
            detailSheet("Other activities", subtitle: "Cross-training around your runs.") {
                ForEach(extras, id: \.self) { a in activityCard(a) }
            }
        }
    }

    private func activityCard(_ a: ActivityChoice) -> some View {
        ChoiceCard(title: a.title, systemImage: a.icon, isSelected: vm.activities.contains(a), multi: true) {
            pick { if vm.activities.contains(a) { vm.activities.remove(a) } else { vm.activities.insert(a) } }
        }
    }

    private func coachingNote(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(message).font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md).onboardingCard()
    }

    private func detailButton(_ title: String, value: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary).frame(width: 28)
                Text(title).font(.rounded(15, weight: .medium)).foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                Text(value).font(.rounded(12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, 16).frame(minHeight: 52).onboardingCard()
        }
        .buttonStyle(RaisedPressStyle(scale: 0.99))
    }

    private func detailSheet<C: View>(_ title: String, subtitle: String? = nil,
                                      @ViewBuilder content: () -> C) -> some View {
        OnboardingDetailSheet(title: title, subtitle: subtitle, content: content)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
    }

    private func activitySectionLabel(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nameStep: some View {
        questionScaffold("Let's make it yours.", subtitle: "Start with your name and a username.") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    activitySectionLabel("NAME")
                    TextField("Your name", text: $vm.name)
                        .font(.rounded(20, weight: .medium)).foregroundStyle(Theme.ink)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                        .textContentType(.name).submitLabel(.done)
                        .frame(minHeight: 44)
                }
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 2) {
                    activitySectionLabel("USERNAME")
                    HandleField(handle: $vm.handle, backend: services.social,
                                suggestions: HandleSuggester.candidates(name: vm.name, email: nil, seed: 7),
                                showsOfflineHint: true,
                                onAvailabilityChange: { handleUnavailable = $0 == .taken || $0 == .reserved })
                }
            }
            .padding(20)
            .onboardingCard()
            .onboardingEntrance(cascade(0))
            Text("You can change these in your profile anytime.")
                .font(.rounded(13, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                .onboardingEntrance(cascade(1))
        }
        .onAppear { vm.suggestHandle(afterEditing: vm.name) }
        .onChange(of: vm.name) { old, _ in vm.suggestHandle(afterEditing: old) }
    }

    private var identityStep: some View { nameStep }

    /// Units. Asked early because every number after it is quoted back in the athlete's own, and
    /// answered for them from their locale so the common case is one tap on Continue.
    ///
    /// Two rows rather than one metric/imperial switch: mixing is real and normal (the UK runs in
    /// miles and weighs in kilos), and a single toggle would force one of those to be wrong.
    private var unitsStep: some View {
        questionScaffold("Which units do you use?",
                         subtitle: "Every distance, pace and weight is shown your way.") {
            unitRow("Distance", index: 0) {
                SegmentedCapsule(items: [DistanceUnit.metric, .imperial],
                                 selection: distanceUnitBinding, scale: .page,
                                 title: { $0 == .metric ? "Kilometres" : "Miles" },
                                 spokenLabel: { $0 == .metric ? "Kilometres" : "Miles" })
            }
            unitRow("Weight", index: 1) {
                SegmentedCapsule(items: [WeightUnit.kg, .lb],
                                 selection: weightUnitBinding, scale: .page,
                                 title: { $0 == .kg ? "Kilograms" : "Pounds" },
                                 spokenLabel: { $0 == .kg ? "Kilograms" : "Pounds" })
            }
        }
    }

    /// Reads the resolved unit (locale until the athlete answers) and writes their answer.
    private var distanceUnitBinding: Binding<DistanceUnit> {
        Binding(get: { useMetricDistance ? .metric : .imperial },
                set: { vm.distanceUnitChoice = $0.rawValue })
    }
    private var weightUnitBinding: Binding<WeightUnit> {
        Binding(get: { useMetricWeight ? .kg : .lb },
                set: { vm.weightUnitChoice = $0.rawValue })
    }

    private func unitRow<C: View>(_ title: String, index: Int,
                                  @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title.uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.3)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.leading, Theme.Space.xs)
            control()
        }
        .onboardingEntrance(cascade(index))
    }

    private var goalStep: some View {
        // Running-first ordering (ENDURANCE-FOCUS Phase 0): the racing + endurance goals lead — this is
        // a running app. Strength/body-composition goals remain, as the supporting pillar.
        let goals: [Goal] = [
            .raceDistance, .endurance, .stayConsistent, .loseFat, .buildMuscle, .getStronger]
        return questionScaffold("What are we training for?", subtitle: "Your goal gives every session a purpose.") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Array(goals.enumerated()), id: \.element) { i, goal in
                    OnboardingGoalTile(goal: goal, selected: vm.goal == goal) { pick { vm.goal = goal } }
                        .onboardingEntrance(cascade(i / 2), lift: 8)
                }
            }
            detailButton("Supporting activities", value: vm.lifting ? "Strength + running" : "Running only",
                         systemImage: "plus") { showSupportingActivities = true }
                .accessibilityIdentifier("onboarding.supportingActivities")
        }
        .sheet(isPresented: $showSupportingActivities) {
            NavigationStack {
                disciplinesStep.padding(Theme.Space.lg)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSupportingActivities = false }
                    } }
            }.presentationDragIndicator(.visible)
        }
    }

    /// Recent training background controls progression. The optional result calibrates speed
    /// separately; it never silently upgrades the athlete's training experience.
    private var experienceStep: some View {
        questionScaffold("Where are you with running?",
                         subtitle: "Think about your recent routine, not how fast you run.") {
            ForEach(Array([ExperienceLevel.new, .some, .experienced].enumerated()), id: \.element) { i, level in
                OnboardingBackgroundChoice(
                    symbol: level == .new ? "figure.walk" : level == .some ? "figure.run" : "calendar.badge.checkmark",
                    title: level == .new ? "New to running" : level == .some ? "Running regularly" : "Training consistently",
                    subtitle: level == .new ? "My first regular running routine."
                        : level == .some ? "I run most weeks."
                        : "I follow a structured routine.",
                    isSelected: vm.runningBackgroundChosen && !vm.returningRunner && vm.experience == level
                ) { pick { vm.chooseRunningBackground(level) } }
                .onboardingEntrance(cascade(i))
            }
            OnboardingBackgroundChoice(symbol: "arrow.counterclockwise", title: "Returning after a break",
                       subtitle: "Start from my recent running, not my old peak.",
                       isSelected: vm.returningRunner) { pick { vm.chooseReturningBackground() } }
                .onboardingEntrance(cascade(3))
            Text(vm.runningBackgroundChosen
                 ? (vm.returningRunner ? "A fresh start, built around your recent running."
                    : vm.experience == .new ? "We'll ease you in with a manageable first week."
                    : "We'll build from the running you're already doing.")
                 : "Choose the starting point that feels most like you.")
                .font(.rounded(14, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : Motion.crossfade, value: vm.runningBackgroundChosen)
                .animation(reduceMotion ? nil : Motion.crossfade, value: vm.returningRunner)
                .animation(reduceMotion ? nil : Motion.crossfade, value: vm.experience)
            timeEntryCard.onboardingEntrance(cascade(4))
            Text("No recent result? We'll use an estimated starting effort and adjust from the runs you log.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    /// Current running load — seeds the plan's starting volume so it meets the athlete where they are.
    private var runVolumeStep: some View {
        questionScaffold("Your recent running.",
                         subtitle: "A little context helps us start at the right level. We'll plan how far you build from here.") {
            activitySectionLabel("YOUR LAST FOUR WEEKS")
            metricRow("Per week", volumeLabel(vm.weeklyRunVolumeM),
                      typed: { if let value = Double($0) { setWeekly(value) } },
                      { setWeekly(volumeDisplay(vm.weeklyRunVolumeM) - 5) },
                      { setWeekly(volumeDisplay(vm.weeklyRunVolumeM) + 5) })
                .onboardingEntrance(cascade(0))
            metricRow("Longest run", volumeLabel(vm.longestRunM),
                      typed: { if let value = Double($0) { setLongest(value) } },
                      { setLongest(volumeDisplay(vm.longestRunM) - 1) },
                      { setLongest(volumeDisplay(vm.longestRunM) + 1) })
                .onboardingEntrance(cascade(1))
            Text("An estimate is enough. Tap a number to enter it, or leave it as Not sure.")
                .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if vm.returningRunner {
                Button("I haven't run in the last four weeks") {
                    Haptics.selection()
                    vm.weeklyRunVolumeM = 0; vm.longestRunM = 0
                }.font(.rounded(14, weight: .semibold))
            }
            Button("I'm not sure") {
                vm.weeklyRunVolumeM = nil; vm.longestRunM = nil
            }.font(.rounded(14, weight: .semibold))
                .accessibilityIdentifier("onboarding.volume.unknown")
            coachingNote("We'll take it from here", "Your first week starts conservatively when recent running is unknown. Your logged runs help shape what comes next.")
                .onboardingEntrance(cascade(2), lift: 8)
        }
    }

    // Volume is entered in the athlete's locale unit (mi in the US/UK, km elsewhere) but stored in
    // meters. Route through DistanceUnit so this agrees with the rest of the app: a plain
    // measurementSystem check put UK athletes (`.uk`, not `.us`) in km while every other surface
    // showed them miles.
    /// The athlete's own answer from the units step, falling back to their locale until they
    /// reach it. This used to read the locale and nothing else, so a runner whose phone region
    /// disagreed with how they think was quoted miles (or km) through the entire flow with no
    /// way to correct it.
    private var useMetricDistance: Bool {
        (vm.distanceUnitChoice.flatMap(DistanceUnit.init(rawValue:)) ?? .auto).resolved() == .metric
    }
    private var metersPerUnit: Double { useMetricDistance ? 1000 : 1609.344 }
    private var distanceUnitLabel: String { useMetricDistance ? "km" : "mi" }
    private func volumeDisplay(_ meters: Double?) -> Double { (meters ?? 0) / metersPerUnit }
    private func volumeLabel(_ meters: Double?) -> String {
        guard let meters else { return "Not sure" }
        return "\(Int(volumeDisplay(meters).rounded())) \(distanceUnitLabel)"
    }
    // Cap 250 display units: in km locales that clears elite-marathon mileage (~220 km/wk);
    // 200 km clipped it. (250 mi is beyond any human, harmlessly.)
    private func setWeekly(_ d: Double) { Haptics.light(); vm.weeklyRunVolumeM = min(250, max(0, d.rounded())) * metersPerUnit }
    private func setLongest(_ d: Double) { Haptics.light(); vm.longestRunM = min(60, max(0, d.rounded())) * metersPerUnit }
    /// Optional training-limit editor, outside the main interview. Existing draft limits stay
    /// editable here; removing a limit is explicit and never discards a past answer silently.
    private func setTarget(_ delta: Double) {
        Haptics.light()
        let weekly = volumeDisplay(vm.weeklyRunVolumeM).rounded()
        let current = vm.targetWeeklyRunVolumeM.map(volumeDisplay) ?? weekly
        let next = (current + delta).rounded()
        vm.targetWeeklyRunVolumeM = max(1, min(250, next)) * metersPerUnit
    }
    /// Hybrids answer both disciplines without extending the running question below the CTA.
    private var liftingExperiencePicker: some View {
        Menu {
            Picker("Lifting experience", selection: $vm.liftExperience) {
                Text("New to lifting").tag(ExperienceLevel.new)
                Text("Some experience").tag(ExperienceLevel.some)
                Text("Experienced").tag(ExperienceLevel.experienced)
            }
        } label: {
            HStack {
                Text("Lifting experience").foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                Text(vm.liftExperience == .new ? "New" : vm.liftExperience == .some ? "Some" : "Experienced")
                    .foregroundStyle(Theme.inkSecondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .font(.rounded(14, weight: .medium))
            .padding(16).frame(minHeight: 52).onboardingCard()
        }
        .accessibilityIdentifier("onboarding.liftingExperience")
    }

    private var daysStep: some View {
        questionScaffold("Let's shape your training week.", subtitle: "We've suggested a rhythm for your goal. Adjust it only if your week needs something different.") {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(vm.daysPerWeek)").font(.display(42, weight: .semibold)).monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        // The count rolls AND lifts: the number is the answer, so it is the thing
                        // that reacts, not the segment that was tapped.
                        .onboardingAcknowledge(trigger: vm.daysPerWeek, scale: 1.1)
                    Text("training days / week").font(.rounded(14)).foregroundStyle(Theme.inkSecondary)
                    Spacer(minLength: 0)
                }
                SegmentedCapsule(items: [2, 3, 4, 5, 6],
                                 selection: Binding(get: { vm.daysPerWeek },
                                                    set: { vm.daysPerWeek = $0; vm.daysPerWeekChosen = true }),
                                 scale: .page,
                                 title: { "\($0)" }, spokenLabel: { "\($0) training days" })
                    .monospacedDigit()
                Rectangle().fill(Theme.hairline).frame(height: 1)
                activitySectionLabel("PREFERRED DAYS · OPTIONAL")
                preferredDaysPicker.padding(.horizontal, -12)
                Text(vm.preferredDays.isEmpty ? "Leave the days to us, or tap the ones that fit your week."
                     : "Preferences noted. We'll arrange your sessions around them.")
                    .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20).background(Theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.hairline) }
            .onboardingEntrance(cascade(0), lift: 8)
            detailButton("Session time", value: vm.limitRegularRunTime || vm.lifting ? "\(vm.sessionMinutes) min" : "Coach chooses",
                         systemImage: "clock") { showSessionLimits = true }
                .accessibilityIdentifier("onboarding.sessionLimits")
            Text(vm.targetWeeklyRunVolumeM.map { "Your weekly distance limit: \(volumeLabel($0)). Edit in Session time." }
                 ?? vm.longRunLimitMinutes.map { "Long runs: up to \($0) min. Tap Session time to change." }
                 ?? "We'll choose session lengths. Add a limit only if you need one.")
                .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            coachingNote(coachDaysTitle, coachDaysMessage)
            // Frequency honesty, said where the choice is made: a race build under its effective
            // day floor holds fitness rather than building readiness (PlanFeasibility owns the
            // numbers; the intensity step's verdict banner repeats the full read).
            if vm.goal == .raceDistance, let race = vm.raceDistance,
               vm.plannedRunDays < PlanFeasibility.minimumEffectiveDays(forDistanceM: race.meters) {
                let minDays = PlanFeasibility.minimumEffectiveDays(forDistanceM: race.meters)
                // Read against the RUN days, not the total: a five-day hybrid week holds three
                // runs, and quoting the total told them they were covered when they were not.
                // When the two differ, say why — the split is theirs to change on the next screen.
                let runDays = vm.plannedRunDays
                let split = runDays < vm.daysPerWeek
                    ? " Your \(vm.daysPerWeek) days split \(runDays) running and \(vm.daysPerWeek - runDays) lifting."
                    : ""
                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 13, weight: .semibold))
                    Text("Honest note: a \(race.label.lowercased()) build really wants \(minDays)+ running days. On \(runDays) you'll maintain fitness, not race readiness.\(split) We'll build your week either way.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onboardingCard()
                .transition(.opacity)
            }
        }
        .onAppear { vm.applyRecommendedDaysIfUntouched() }
        .sheet(isPresented: $showSessionLimits) {
            NavigationStack {
                sessionStep.padding(Theme.Space.lg)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSessionLimits = false }
                    } }
            }.presentationDragIndicator(.visible)
        }
    }

    /// The days step opens on the coach's pick and says why (2026-09-06): running is built on
    /// frequency, so the note names the goal's rhythm and how the days split between running and
    /// lifting. Once the athlete picks their own count the note follows their number.
    private var coachDaysTitle: String {
        vm.daysPerWeek == vm.recommendedDays ? "The coach's pick for your goal" : "A week built around your availability"
    }
    private var coachDaysMessage: String {
        let runs = vm.plannedRunDays
        let lifts = vm.daysPerWeek - runs
        let split = vm.lifting && vm.running
            ? "\(vm.daysPerWeek) days: \(runs) running, \(lifts) lifting."
            : "\(vm.daysPerWeek) training days."
        let why: String
        if vm.goal == .raceDistance, let race = vm.raceDistance {
            why = " We'd suggest \(vm.recommendedDays) days to balance preparation for your \(race.label.lowercased()) with recovery."
        } else {
            why = " We'd suggest \(vm.recommendedDays) days to balance running and recovery for your goal."
        }
        let tail = vm.daysPerWeek < vm.recommendedDays
            ? " Fewer days still works — every run counts — the build just takes longer."
            : " Leave preferred days empty and we'll arrange the week around recovery."
        return split + why + tail
    }

    private var equipmentStep: some View {
        let opts: [(Equipment, String, String)] = [
            (.fullGym, "Full gym", "building.2"), (.dumbbellsOnly, "Dumbbells only", "dumbbell"),
            (.homeMinimal, "Home minimal", "house"), (.bodyweight, "Bodyweight", "figure.cooldown")]
        return questionScaffold("What equipment do you have?", subtitle: "Your strength sessions will use what you have available.") {
            liftingExperiencePicker
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                ChoiceCard(title: o.1, systemImage: o.2, isSelected: vm.equipment == o.0) { pick { vm.equipment = o.0 } }
                    .onboardingEntrance(cascade(i))
            }
            detailButton("Strength preferences", value: strengthSplitTitle, systemImage: "slider.horizontal.3") {
                showStrengthPreferences = true
            }.accessibilityIdentifier("onboarding.strengthPreferences")
        }
        .sheet(isPresented: $showStrengthPreferences) {
            detailSheet("Strength preferences", subtitle: "The coach chooses how to arrange your strength sessions. You can set a split if you already have a preference.") {
                Picker("Lifting split", selection: $vm.strengthSplit) {
                    Text("Coach's pick").tag(StrengthSplitStyle.coach)
                    Text("Full body").tag(StrengthSplitStyle.fullBody)
                    Text("Upper / lower").tag(StrengthSplitStyle.upperLower)
                    Text("Push / pull / legs").tag(StrengthSplitStyle.pushPullLegs)
                }.pickerStyle(.inline)
                    .accessibilityIdentifier("onboarding.liftingSplit")
            }
        }
    }

    private var sessionStep: some View {
        let opts: [(Int, String, String)] = [
            (30, "30 min", "In and out"), (45, "45 min", "A balanced session"),
            (60, "60 min", "A full workout"), (75, "75 min", "More time to train")]
        return questionScaffold("How much time do you have?",
                                subtitle: "This shapes your usual sessions. Longer runs are planned separately around your goal and current fitness.") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                ChoiceCard(title: o.1, subtitle: o.2, isSelected: vm.sessionMinutes == o.0) { pick { vm.sessionMinutes = o.0 } }
                    .onboardingEntrance(cascade(i))
            }
            if vm.running {
                DisclosureGroup("Weekly distance limit (optional)") {
                    metricRow("Weekly limit", vm.targetWeeklyRunVolumeM.map(volumeLabel) ?? "Coach",
                              { setTarget(-5) }, { setTarget(5) })
                    Button("Let the coach choose") { vm.targetWeeklyRunVolumeM = nil }
                        .font(.rounded(14, weight: .semibold))
                    Text("Only set this if you need a firm weekly limit. Otherwise we'll build toward what your goal needs.")
                        .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.font(.rounded(14, weight: .medium))
                Toggle("Keep regular runs within this time", isOn: $vm.limitRegularRunTime)
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                DisclosureGroup("Long-run time limit (optional)") {
                    Picker("Long-run limit", selection: $vm.longRunLimitMinutes) {
                        Text("Let the coach choose").tag(Int?.none)
                        ForEach([30, 45, 60, 75, 90, 120, 150, 180], id: \.self) { value in
                            Text("\(value) min").tag(Optional(value))
                        }
                    }
                    Text("Includes warm-up, work and recovery at the planned effort. Race day is separate. Short limits can reduce preparation for longer races.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    private var whyStep: some View {
        let reasons = ["clear head", "health", "look better", "compete", "me-time"]
        return questionScaffold("Why are you doing this?", subtitle: "It sets your coach's tone.") {
            ForEach(Array(reasons.enumerated()), id: \.element) { i, r in
                ChoiceCard(title: r.capitalized, isSelected: vm.reason == r) { pick { vm.reason = r } }
                    .onboardingEntrance(cascade(i))
            }
        }
    }

    // The running pace question now lives in `experienceStep` (2026-07-24) — a runner sets their
    // level once. The `timeEntryCard` below is still shared by that step.

    /// Past injuries — multi-select body areas the plan will train around (ENDURANCE-FOCUS §8.2).
    /// Optional and shame-free; empty = none. Feeds a conservative history modifier and the injury
    /// loop's watch list; it is not a diagnosis of current capacity.
    private var injuriesStep: some View {
        questionScaffold("Anything to train around?",
                         subtitle: "Past injuries help us leave more recovery margin and avoid repeating aggravating patterns. Skip if none apply.") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                      spacing: 12) {
                ForEach(Array(InjuryArea.allCases.enumerated()), id: \.element) { i, area in
                    let on = vm.injuryAreas.contains(area)
                    Button {
                        Haptics.selection()
                        if on { vm.injuryAreas.remove(area) } else { vm.injuryAreas.insert(area) }
                    } label: {
                        Text(area.label)
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Capsule().fill(on ? Theme.ink : (colorScheme == .dark ? Theme.surface : .white)))
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                            .animation(Motion.crossfade, value: on)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .onboardingEntrance(cascade(i / 2))
                }
            }
            // The explicit way through for the healthy majority (owner ask 2026-07-30): without
            // it, a grid of selectable areas reads like a question you must answer.
            Button {
                Haptics.success()
                vm.injuryAreas.removeAll()
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
                .onboardingCard()
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
            .buttonStyle(.plain)
            .onboardingEntrance(cascade((InjuryArea.allCases.count + 1) / 2))
            // Reserve the coaching line so selecting the first area never shifts the grid.
            Text("We'll ease the impact around these areas and watch for early warning signs.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(vm.injuryAreas.isEmpty ? 0 : 1)
                .accessibilityHidden(vm.injuryAreas.isEmpty)
                .animation(Motion.crossfade, value: vm.injuryAreas.isEmpty)
        }
    }

    /// The recovery consent beat (ENDURANCE-FOCUS §7) — Apple Health as a source of SIGNALS, so
    /// the plan adapts to how the athlete is actually recovering. Staged as a permission hero (glass
    /// pass 2026-08-27): a glowing glyph, the ask in plain words, and a quiet mock of the sheet
    /// that follows, dissolving into the CTA.
    ///
    /// ⚠️ App Review guideline 5.1.1(iv) (rejected build 17, 2026-08-11): a priming screen before the
    /// HealthKit request must use a neutral button word ("Continue"/"Next", never "Connect") and must
    /// NOT offer a way to bypass the system prompt (no "Maybe later"). The athlete's real choice is
    /// the system sheet itself — declining there advances the flow exactly like accepting.
    private var healthStep: some View {
        OnboardingHeroPage {
            Spacer(minLength: Theme.Space.lg)
            // The icon rests on its own pulse — the resting heart rate this beat is asking to
            // read, beating behind Apple's mark rather than deforming it.
            HealthTile()
                .background { HeartbeatHalo(tint: Color(hex: "FF4563"), diameter: 190) }
                .onboardingHover(amplitude: 3, tilt: 0, period: 3.6)
                .onboardingEntrance(0.02, lift: 10)
            OnboardingHeading(title: "Train around your recovery",
                              subtitle: "Share Apple Health signals to help your plan respond to recovery. Tracking starts when you connect. You choose what to share; workout history is never imported.", alignment: .center)
                .padding(.top, Theme.Space.md)
                .padding(.horizontal, Theme.Space.sm)
                .onboardingEntrance(0.08)
            Spacer(minLength: Theme.Space.lg)
            // The sheet plays the tap that follows: Turn On All presses, the signals switch on.
            HealthSheetMock()
                .frame(maxWidth: .infinity)
                .frame(height: 330, alignment: .top)
                .bottomFade(from: 0.45)
                .onboardingEntrance(0.16, lift: 26)
            Spacer(minLength: 0)
        } actions: {
            // `inFlight` is the same latch that blocks the double tap: after the system sheet is
            // answered there are still two HealthKit reads before the step advances, and on a
            // device with real Health data that wait is not instant. Without the spinner the
            // athlete taps Continue, dismisses iOS's sheet, and then watches a dead button.
            OnboardingCTA(title: "Continue", inFlight: healthRequestInFlight) {
                // One-shot: when permission is already determined the awaits return instantly
                // with no system sheet to swallow taps, and a double-tap advanced two steps.
                guard !healthRequestInFlight else { return }
                healthRequestInFlight = true
                Task {
                    let connection = await services.health.connectForSignals()
                    // Grab resting HR (and body mass, if the athlete skipped it) while we have
                    // consent — it upgrades HR zones to Karvonen from the very first plan.
                    if let rhr = connection.restingHR { vm.healthRestingHR = rhr }
                    if vm.bodyMassKg == nil { vm.bodyMassKg = connection.bodyMassKg }
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
            .padding(.top, Theme.Space.sm)
            .onboardingEntrance(0.26)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Propose the coach's approach and honest feasibility assessment up front. All four
    /// intensity choices remain available in an optional sheet, with explicit overrides preserved.
    private var intensityStep: some View {
        let f = vm.feasibility
        return questionScaffold("Here's the approach we recommend.",
                                subtitle: "Your answers set the starting point. We'll handle the progression and adjust from the runs you log.") {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    // The seal bounces once after the brief has landed: the coach signing off.
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 20)).foregroundStyle(Theme.purple)
                        .symbolEffect(.bounce.up, options: .nonRepeating, value: briefSealed)
                    Text(vm.name.split(separator: " ").first.map { "MADE FOR \($0.uppercased())" } ?? "YOUR TRAINING BRIEF")
                        .font(.rounded(10, weight: .semibold)).tracking(1.4)
                        .foregroundStyle(Theme.inkSecondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(vm.goal == .raceDistance ? (vm.raceDistance?.label ?? "Your race") : vm.goal.planLabel)
                    .font(.display(30, weight: .semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label("\(vm.daysPerWeek) days / week", systemImage: "calendar")
                    Text("·").accessibilityHidden(true)
                    Text(vm.intensity.label).contentTransition(.opacity)
                }.font(.rounded(13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                Text(vm.intensity.subtitle).font(.rounded(14)).foregroundStyle(Theme.inkSecondary)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text(f.headline).font(.rounded(18, weight: .semibold))
                if !f.detail.isEmpty {
                    Text(f.detail.replacingOccurrences(of: " What helps most:", with: ""))
                        .font(.rounded(14)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let need = f.weeklyCapShortfallM {
                    Text("Your \(volumeLabel(vm.targetWeeklyRunVolumeM)) weekly limit is below this goal's usual \(Int((need / metersPerUnit).rounded())) \(distanceUnitLabel).")
                        .font(.rounded(13, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("View training assessment") { showTrainingAssessment = true }
                    .font(.rounded(14, weight: .semibold))
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.hairline) }
            .onboardingEntrance(cascade(0), lift: 10)
            OnboardingCoachingLoop().onboardingEntrance(cascade(1), lift: 6)
            detailButton("Adjust approach", value: "Optional", systemImage: "slider.horizontal.3") {
                showApproachOptions = true
            }.accessibilityIdentifier("onboarding.approach.options")
        }
        .sheet(isPresented: $showTrainingAssessment) {
            detailSheet("Your training assessment") { feasibilityBanner(vm.feasibility) }
        }
        .sheet(isPresented: $showApproachOptions) {
            detailSheet("Your training approach", subtitle: "Your coach has made a recommendation. Change it only if you'd prefer a different approach.") {
                ForEach(PlanIntensity.allCases) { tier in
                    ChoiceCard(title: tier == vm.feasibility.recommended ? "\(tier.label)  ·  Recommended" : tier.label,
                               subtitle: tier.subtitle, isSelected: vm.intensity == tier) {
                        pick {
                            vm.chooseIntensity(tier)
                        }
                    }
                }
                if vm.intensity == .podium {
                    Text("Podium needs \(PlanIntensity.podium.floorDays)+ days. Your week is set to \(vm.daysPerWeek).")
                        .font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .onAppear {
            vm.applyRecommendedIntensityIfUntouched()
        }
        .task {
            // After the card's own entrance; a no-op under Reduce Motion (symbol effects honor it).
            do { try await Task.sleep(for: .seconds(0.7)) } catch { return }
            briefSealed = true
        }
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
            // Ceiling honesty: their cap is under the goal's usual mileage. Said once, plainly.
            if let need = f.weeklyCapShortfallM {
                Text("Your \(volumeLabel(vm.targetWeeklyRunVolumeM)) cap is under this goal's usual \(Int((need / metersPerUnit).rounded())) \(distanceUnitLabel) a week.")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !f.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(f.options, id: \.self) { opt in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.ink).padding(.top, 2)
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
        .onboardingCard()
    }

    /// The optional precise path — expand to enter a recent time over a distance you know.
    private var timeEntryCard: some View {
        detailButton("Recent race or timed effort",
                     value: vm.calibrationMode == .time ? "\(vm.benchmark.label) · \(Formatters.duration(s: vm.recentRunSeconds))" : "Optional",
                     systemImage: "stopwatch") {
            draftBenchmark = vm.benchmark
            draftRunSeconds = vm.recentRunSeconds
            draftResultDate = vm.benchmarkPerformedAt
            resultTimeEntered = vm.calibrationMode == .time
            showTimeEntry = true
        }
        .sheet(isPresented: $showTimeEntry) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Use a recent race or strong timed effort, not an easy training run or the time you hope to achieve.")
                            .font(.rounded(Theme.FontSize.body, weight: .medium))
                        timeEntryControls
                        Toggle("I know when I ran this", isOn: Binding(
                            get: { draftResultDate != nil },
                            set: { draftResultDate = $0 ? Date() : nil }))
                        if draftResultDate != nil {
                            DatePicker("Result date", selection: Binding(
                                get: { draftResultDate ?? Date() }, set: { draftResultDate = $0 }),
                                in: ...Date(), displayedComponents: .date)
                        }
                        Text("The date helps us explain how recent this evidence is. An older result may no longer reflect today's fitness.")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                        if !resultTimeEntered {
                            Text("Enter your own time above, such as 22:30 or 3:30:00, then save it.")
                                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        OversizedButton(title: "Use this result", isEnabled: resultTimeEntered, expandsForText: true) {
                            guard resultTimeEntered else { return }
                            vm.benchmark = draftBenchmark
                            vm.recentRunSeconds = draftRunSeconds
                            vm.benchmarkPerformedAt = draftResultDate
                            vm.calibrationMode = .time
                            showTimeEntry = false
                        }
                        .accessibilityIdentifier("onboarding.saveBenchmark")
                        if vm.calibrationMode == .time {
                            Button("Remove saved result") {
                                vm.calibrationMode = vm.paceFeel == nil ? .none : .feel
                                vm.benchmarkPerformedAt = nil
                                showTimeEntry = false
                            }
                            .font(.rounded(Theme.FontSize.body, weight: .medium))
                            .frame(maxWidth: .infinity)
                        }
                    }.padding(24)
                }
                .navigationTitle("Your recent result")
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showTimeEntry = false }
                } }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var timeEntryControls: some View {
        VStack(spacing: 20) {
            if typeSize.isAccessibilitySize {
                // Five equal chips cannot retain their labels at accessibility sizes. A native
                // menu names the selected distance in full and gives every choice a full row.
                Menu {
                    ForEach(RunBenchmark.allCases) { benchmark in
                        Button(benchmark.label) {
                            Haptics.selection()
                            draftBenchmark = benchmark
                            draftRunSeconds = benchmark.defaultSeconds
                            resultTimeEntered = false
                        }
                    }
                } label: {
                    HStack {
                        Text(draftBenchmark.label).font(.rounded(Theme.FontSize.body, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 16))
                    }
                    .padding(12)
                    .onboardingCard()
                }
                .accessibilityIdentifier("onboarding.benchmarkDistance")
                Text("Time").font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                benchmarkTimeValue.frame(maxWidth: .infinity)
                HStack {
                    Button { Haptics.light(); adjustTime(-draftBenchmark.step) } label: { metricStep("minus") }
                        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
                        .accessibilityLabel("Decrease time")
                    Spacer()
                    Button { Haptics.light(); adjustTime(draftBenchmark.step) } label: { metricStep("plus") }
                        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
                        .accessibilityLabel("Increase time")
                }
            } else {
            HStack(spacing: 6) {                          // tighter so "Marathon" fits at full size
                ForEach(RunBenchmark.allCases) { b in
                    let on = draftBenchmark == b
                    Button {
                        Haptics.selection()
                        draftBenchmark = b; draftRunSeconds = b.defaultSeconds; resultTimeEntered = false
                    } label: {
                        // Uniform smaller label so the longest word ("Marathon") sits comfortably
                        // in its chip rather than shrinking alone against the others.
                        Text(b.label).font(.rounded(Theme.FontSize.label, weight: .bold))
                            .lineLimit(1).minimumScaleFactor(0.9)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background { if on { Capsule().fill(Theme.ink) } }
                            .modifier(ChipRaise(on: on))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: Theme.Space.md) {
                Text("Time").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                // Press-and-hold repeats: the range spans a 12:00 elite 5K to a 60:00 walk-jog,
                // and nobody should tap 30 times to reach their real time.
                Button { Haptics.light(); adjustTime(-draftBenchmark.step) } label: { metricStep("minus") }
                    .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
                // Tap the time to TYPE it — "21:45", "1:38:20", or bare digits ("2145").
                benchmarkTimeValue
                Button { Haptics.light(); adjustTime(draftBenchmark.step) } label: { metricStep("plus") }
                    .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
            }
            }
            Text(paceHint).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var benchmarkTimeValue: some View {
        TypableNumber(display: Formatters.duration(s: draftRunSeconds),
                      keyboard: .numbersAndPunctuation, minWidth: 84,
                      axID: "onboarding.benchmarkTime", commitsEmptyInput: true,
                      commit: { commitTypedRaceTime($0) })
    }


    /// Typed race time. Accepts "21:45", "1:38:20", bare minutes ("22"), or run-on digits
    /// ("2145" → 21:45). Where an entry is ambiguous ("330" — 3m30s or 3h30m?), the benchmark's own
    /// plausible range decides: whichever reading lands inside it wins, so a marathoner's "330"
    /// means 3:30:00 and a miler's means 3:30.
    private func commitTypedRaceTime(_ raw: String) {
        guard let seconds = OnboardingViewModel.benchmarkSeconds(raw, benchmark: draftBenchmark) else {
            resultTimeEntered = false
            return
        }
        draftRunSeconds = seconds
        resultTimeEntered = true
    }

    private func adjustTime(_ delta: Double) {
        resultTimeEntered = true
        draftRunSeconds = min(draftBenchmark.range.upperBound, max(draftBenchmark.range.lowerBound, draftRunSeconds + delta))
    }

    /// "Easy runs ≈ 6:10 /mi" — the resulting easy pace, so the number feels meaningful.
    private var paceHint: String {
        let p5k = PlanEngine.riegelP5k(distanceM: draftBenchmark.meters, timeS: draftRunSeconds)
        return "Easy runs ≈ \(Formatters.pace(secPerKm: PlanEngine.pace(.easy, p5k: p5k), unit: useMetricDistance ? .metric : .imperial))"
    }

    // MARK: Race setup (racers) — distance + optional date

    private var raceStep: some View {
        questionScaffold("What's your next finish line?", subtitle: "Choose your distance. Add a date or target time if you have one.") {
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
                .onboardingCard()
            }
            .buttonStyle(.plain)
            .onboardingEntrance(cascade(0))
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
                // that's varied across releases. Onboarding is unconditionally light, so this sheet
                // is too — stated here, at the onboarding call site only, because the SAME sheet is
                // presented from the Plan tab, where it must follow the athlete's appearance setting.
                .environment(\.colorScheme, .light)
            }

            activitySectionLabel("RACE DISTANCE")
            HStack(spacing: 6) {
                ForEach(RaceDistance.allCases) { distance in
                    Button { pick { vm.raceDistance = distance } } label: {
                        Text(raceShortLabel(distance))
                            .font(.rounded(13, weight: .semibold))
                            .foregroundStyle(vm.raceDistance == distance ? .white : Theme.ink)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(vm.raceDistance == distance ? Theme.ink : .white))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(RaisedPressStyle(scale: 0.99))
                    .accessibilityLabel(distance.label)
                    .accessibilityAddTraits(vm.raceDistance == distance ? .isSelected : [])
                }
            }
            .padding(.bottom, 6)
            raceDateCard
            detailButton("Target finish time",
                         value: vm.goalFinishTimeS.map { Formatters.duration(s: $0) } ?? "Optional",
                         systemImage: "timer") { showGoalTime = true }
                .sheet(isPresented: $showGoalTime) {
                    detailSheet("Your target time", subtitle: "We'll assess it against your starting point.") {
                        raceGoalTimeControls
                    }
                }

        }
    }

    private func raceShortLabel(_ distance: RaceDistance) -> String {
        switch distance {
        case .fiveK: "5K"
        case .tenK: "10K"
        case .half: "Half"
        case .marathon: "Marathon"
        case .fiftyK: "50K"
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
        .onboardingCard()
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
                .frame(height: 140).frame(maxWidth: .infinity)
                .onboardingEntrance(cascade(0))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm), GridItem(.flexible())],
                      spacing: Theme.Space.sm) {
                ForEach(focusOptions, id: \.title) { opt in
                    let on = !vm.muscleFocus.isDisjoint(with: Set(opt.muscles))
                    Button { pick { toggleFocus(opt) } } label: {
                        Text(opt.title)
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background {
                                if on { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.ink) }
                            }
                            .modifier(SegmentRaise(on: on))
                    }
                    .buttonStyle(RaisedPressStyle())
                }
            }
            .onboardingEntrance(cascade(1))
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
            preferredDaysPicker
        }
    }

    private var preferredDaysPicker: some View {
        OnboardingWeekPicker(selectedDays: $vm.preferredDays) {
            touchedSteps.insert(vm.step)
        }
    }

    private func weekdayLetter(_ wd: Int) -> String { ["S", "M", "T", "W", "T", "F", "S"][(wd - 1) % 7] }

    // MARK: Required personal details

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
        questionScaffold("A few personal details.", subtitle: "Your age and body measurements help tailor heart-rate and fueling estimates around your training.") {
            sexSelector.onboardingEntrance(cascade(0))
            metricRow("Age", vm.birthYear == nil ? "Add" : "\(ageDisplay)",
                      typed: { if let a = Int($0.filter(\.isNumber)) { setAge(a) } },
                      { setAge(ageDisplay - 1) }, { setAge(ageDisplay + 1) }).onboardingEntrance(cascade(1))
            // Height feeds the BMR that drives your fuel targets — the same Mifflin–St Jeor the Fuel
            // page uses; without it that estimate leans on an assumed 172 cm. Weight sits below it,
            // the two body figures together.
            metricRow("Height", vm.heightCm == nil ? "Add" : heightDisplay,
                      units: (["ft·in", "cm"], useMetricHeight ? 1 : 0, { vm.heightMetricChoice = $0 == 1 }),
                      keyboard: .numbersAndPunctuation,
                      typed: { commitTypedHeight($0) },
                      { adjustHeight(-1) }, { adjustHeight(1) }).onboardingEntrance(cascade(2))
            metricRow("Weight", vm.bodyMassKg == nil ? "Add" : "\(weightDisplayValue) \(useMetricWeight ? "kg" : "lb")",
                      units: (["lb", "kg"], useMetricWeight ? 1 : 0,
                              { vm.weightUnitChoice = ($0 == 1 ? WeightUnit.kg : WeightUnit.lb).rawValue }),
                      typed: { commitTypedWeight($0) },
                      { adjustWeight(useMetricWeight ? -2 : -5) }, { adjustWeight(useMetricWeight ? 2 : 5) }).onboardingEntrance(cascade(3))
        }
    }

    private func setAge(_ a: Int) { vm.birthYear = currentYear - min(90, max(13, a)) }

    /// Height display + entry, matching the FuelGoalsSheet format exactly (5′8″ imperial / 172 cm
    /// metric) and unit choice (follows weight). Always STORED in cm (SI); nil until the athlete
    /// enters or adjusts it. Continue requires an explicit value for every measurement.
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
        // Floating-point parsing lets the existing bounds handle an oversized paste without
        // overflowing integer multiplication while converting feet to inches.
        let parts = cleaned.split { !$0.isNumber }.compactMap { Double($0) }
        let inches: Double?
        switch parts.count {
        case 1: inches = parts[0] >= 36 ? parts[0] : parts[0] * 12   // "70" = inches; "5" = 5 feet
        case 2: inches = parts[0] * 12 + parts[1]                    // "5 10" / "5'10"
        default: inches = nil
        }
        guard let inches, inches.isFinite else { return }
        vm.heightCm = min(90, max(48, inches)) * 2.54
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
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Theme.Space.sm))
            : AnyLayout(HStackLayout(spacing: Theme.Space.sm))
        return layout {
            ForEach(BiologicalSex.allCases) { s in
                let on = vm.sex == s
                Button { pick { vm.sex = on ? nil : s } } label: {
                    Text(s.label)
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity).frame(minHeight: 50)
                        .padding(.vertical, typeSize.isAccessibilitySize ? 10 : 0)
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .background {
                            if on { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.ink) }
                        }
                        .modifier(SegmentRaise(on: on))
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
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Text(label).font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink)
                    if let units { unitToggle(units.options, selected: units.index, set: units.set) }
                    metricValueControls(label, value, keyboard: keyboard, typed: typed,
                                        minWidth: 54, minus: minus, plus: plus)
                }
            } else {
                HStack(spacing: units == nil ? 8 : 6) {
                    Text(label).font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).fixedSize()
                    if let units { unitToggle(units.options, selected: units.index, set: units.set).fixedSize() }
                    Spacer(minLength: 4)
                    metricValueControls(label, value, keyboard: keyboard, typed: typed,
                                        minWidth: units == nil ? 64 : 54, minus: minus, plus: plus)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onboardingCard()
    }

    private func metricValueControls(_ label: String, _ value: String, keyboard: UIKeyboardType,
                                     typed: ((String) -> Void)?, minWidth: CGFloat,
                                     minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            // Repeats on press-and-hold — a high-mileage athlete adjusting from the seeded default
            // to their real number shouldn't need dozens of taps.
            Button { Haptics.light(); minus() } label: { metricStep("minus") }
                .buttonStyle(RaisedPressStyle(scale: 0.94))
                .buttonRepeatBehavior(.enabled)
                .accessibilityLabel("Decrease \(label)")
            if let typed {
                TypableNumber(display: value, keyboard: keyboard,
                              minWidth: minWidth, axID: "onboarding.metric.\(label.lowercased())", commit: typed)
                    .accessibilityLabel("\(label), \(value)")
            } else {
                Text(value).font(.display(20, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    .modifier(NumericFeedback(value: value))
                    .frame(minWidth: 64)
                    .accessibilityLabel("\(label), \(value)")
            }
            Button { Haptics.light(); plus() } label: { metricStep("plus") }
                .buttonStyle(RaisedPressStyle(scale: 0.94))
                .buttonRepeatBehavior(.enabled)
                .accessibilityLabel("Increase \(label)")
        }
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
                        .foregroundStyle(on ? Theme.background : Theme.inkTertiary)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Capsule().fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.clear)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.tintedField))
    }

    private func metricStep(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44).background(Circle().fill(Theme.tintedField))
    }

    // MARK: Commitment (the investment beat — hold the iridescent ring to commit)

    /// Hybrid athletes: where the week's emphasis sits (biases the run/lift day split) — the question
    /// that makes momentum understand a run-*and*-lift athlete instead of guessing from the goal.
    /// How the lifting week composes (2026-08-20) — same card grammar as the focus step. The
    /// coach's pick leads: most athletes should let the day count decide, and the explicit splits
    /// are there for the ones who know exactly how they like to train.
    private var strengthSplitStep: some View {
        questionScaffold("How do you like to split your lifting?") { strengthSplitChoices }
    }

    private var strengthSplitTitle: String {
        switch vm.strengthSplit {
        case .coach: "Coach's pick"
        case .fullBody: "Full body"
        case .upperLower: "Upper / lower"
        case .pushPullLegs: "Push / pull / legs"
        }
    }

    private var strengthSplitChoices: some View {
        let opts: [(StrengthSplitStyle, String, String, String)] = [
            (.coach, "Coach's pick", "Full body, splitting as your lift days grow", "wand.and.stars"),
            (.fullBody, "Full body", "Every lift day trains everything", "figure.strengthtraining.traditional"),
            (.upperLower, "Upper · Lower", "Alternating upper and lower days", "figure.arms.open"),
            (.pushPullLegs, "Push · Pull · Legs", "The classic three-day rotation", "dumbbell.fill")]
        return VStack(spacing: Theme.Space.sm) {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                ChoiceCard(title: o.1, subtitle: o.2, systemImage: o.3, isSelected: vm.strengthSplit == o.0) {
                    pick { vm.strengthSplit = o.0 }
                }
                .onboardingEntrance(cascade(i))
            }
        }
    }

    private var hybridFocusStep: some View {
        let opts: [(HybridPriority, String, String, String)] = [
            (.running, "Running comes first", "Lift to support the miles", "figure.run"),
            (.balanced, "Balanced runner", "More strength, with running still leading", "figure.run.circle"),
            (.lifting, "More strength support", "Near-even split; the extra day stays a run", "dumbbell.fill")]
        return questionScaffold("How should strength support your running?",
                                subtitle: "Every option stays a running plan. Change it anytime.") {
            ForEach(Array(opts.enumerated()), id: \.element.0) { i, o in
                ChoiceCard(title: o.1, subtitle: o.2, systemImage: o.3, isSelected: vm.hybridPriority == o.0) {
                    pick { vm.hybridPriority = o.0 }
                }
                .onboardingEntrance(cascade(i))
            }
        }
    }

    /// Race goal time — the target the athlete is chasing (drives the reveal + the race outlook).
    private var raceGoalTimeStep: some View {
        questionScaffold("Chasing a time?", subtitle: "Optional. We'll assess it against your starting point.") {
            raceGoalTimeControls
        }
    }

    private var raceGoalTimeControls: some View {
        VStack(spacing: Theme.Space.md) {
            metricRow("Hours", "\(vm.goalHours)",
                      typed: { if let h = Int($0.filter(\.isNumber)) { vm.goalHours = min(9, max(0, h)) } },
                      { vm.goalHours = max(0, vm.goalHours - 1) }, { vm.goalHours = min(9, vm.goalHours + 1) }).onboardingEntrance(cascade(0))
            metricRow("Minutes", String(format: "%02d", vm.goalMinutes),
                      typed: { if let m = Int($0.filter(\.isNumber)) { vm.goalMinutes = min(59, max(0, m)) } },
                      // Carry through the hour instead of wrapping in place: at 3:55, "+" means
                      // 4:00, not a jump back to 3:00 (and "−" at 4:00 means 3:55).
                      { if vm.goalMinutes >= 5 { vm.goalMinutes -= 5 }
                        else if vm.goalHours > 0 { vm.goalHours -= 1; vm.goalMinutes = 55 } },
                      { if vm.goalMinutes <= 50 { vm.goalMinutes += 5 }
                        else if vm.goalHours < 9 { vm.goalHours += 1; vm.goalMinutes = 0 } }).onboardingEntrance(cascade(1))
            if let t = vm.goalFinishTimeS, let m = vm.raceDistance?.meters, m > 0 {
                Text("Target pace: \(Formatters.pace(secPerKm: t / (m / 1000), unit: useMetricDistance ? .metric : .imperial)). We'll check how this fits your starting point.")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).onboardingEntrance(cascade(2))
            }
        }
    }

    /// Reminder opt-in — a permission hero (glass pass 2026-08-27): the glowing bell, what a
    /// reminder from us actually is, and the phone showing one, dissolving into the buttons.
    /// "Maybe later" stays: Apple flagged only HealthKit's skip, and reminders are optional by
    /// nature; if a future review names it, apply the 5.1.1(iv) shape from the Health beat.
    private var notificationsStep: some View {
        OnboardingHeroPage {
            Spacer(minLength: Theme.Space.md)
            GlowGlyph(systemName: "bell.fill", tint: Theme.iridescent[1])
                .onboardingEntrance(0.02, lift: 10)
            OnboardingHeading(title: "A nudge before each run",
                              subtitle: "One reminder ahead of every planned session, a heads-up when your week adapts, and a refuel nudge after a hard one. Nothing else.", alignment: .center)
                .padding(.top, Theme.Space.md)
                .padding(.horizontal, Theme.Space.sm)
                .onboardingEntrance(0.08)
            Spacer(minLength: Theme.Space.lg)
            // Only the phone's top half is drawn; the lower half dissolves straight into the buttons.
            phoneNotificationMockup
                .frame(maxWidth: .infinity)
                .frame(height: 330, alignment: .top)
                .bottomFade(from: 0.45)
                .onboardingEntrance(0.16, lift: 26)
            Spacer(minLength: 0)
        } actions: {
            VStack(spacing: Theme.Space.xs) {
                // Same reasoning as the Health beat: the notification prompt is a system
                // round-trip the athlete can't see into.
                OnboardingCTA(title: "Turn on reminders", inFlight: remindersAdvanced) {
                    // One-shot — a fast double-tap called goNext() twice and skipped a step.
                    guard !remindersAdvanced else { return }
                    remindersAdvanced = true
                    // Advance only AFTER the notifications prompt is dismissed, so the next page's
                    // location prompt lands on a settled screen instead of stacking on this one.
                    services.notifications.requestAuthorization(openSettingsIfDenied: true) { granted in
                        NotificationPrefs.setOnboardingChoice(enabled: granted)
                        services.analytics.log(.onboardingPermission(
                            kind: "notifications", status: granted ? "granted" : "denied"))
                        goNext()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { remindersAdvanced = false }
                    }
                }
                OnboardingSecondary(title: "Maybe later") {
                    // Same one-shot latch as "Turn on reminders" — during the settings round-trip
                    // before the system alert presents, this button used to stay live, and tapping
                    // it advanced once immediately and AGAIN from the alert's completion, skipping
                    // the location primer and stacking its prompt over the beat after it.
                    guard !remindersAdvanced else { return }
                    remindersAdvanced = true
                    NotificationPrefs.setOnboardingChoice(enabled: false)
                    services.analytics.log(.onboardingPermission(
                        kind: "notifications", status: "skipped"))
                    goNext()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { remindersAdvanced = false }
                }
            }
            .onboardingEntrance(0.26)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            notificationPopped = false
            // This task belongs to the page: leaving cancels the delayed banner entrance.
            do { try await Task.sleep(for: .seconds(0.6)) } catch { return }
            guard !Task.isCancelled, vm.step == .notifications else { return }
            withAnimation(reduceMotion ? Motion.crossfade
                                       : .spring(response: 0.5, dampingFraction: 0.86)) {
                notificationPopped = true
            }
        }
        .onDisappear { notificationPopped = false }
    }


    /// A realistic iPhone caught mid-notification — Dynamic Island, a real status bar, and the momentum
    /// reminder as a frosted lock-screen banner at the top of the screen, on a dark wallpaper. Rendered
    /// at full height; the step masks the lower half so the device dissolves into the copy below.
    // A lock-screen-clock variant (big 9:41 + date, banner beneath) was built and REVERTED the same
    // day (owner call 2026-08-11) — the owner prefers this original staging; don't re-propose it.
    private var phoneNotificationMockup: some View {
        let unit = DistanceUnit.auto.resolved() == .imperial ? "3 mi" : "5 km"
        // Warm-graphite wallpaper (owner call 2026-08-27: black, not lavender): deep charcoal at
        // the top so the banner reads crisp, lifting toward the canvas so the screen dissolves
        // into the page instead of ending on a hard dark edge.
        let wallpaper = LinearGradient(stops: [
            .init(color: Color(red: 0.12, green: 0.11, blue: 0.10), location: 0.0),
            .init(color: Color(red: 0.24, green: 0.23, blue: 0.22), location: 0.30),
            .init(color: Color(red: 0.52, green: 0.51, blue: 0.50), location: 0.62),
            // Ends on the canvas itself (white since the 2026-09-05 palette pass; it was the old
            // F5F5F7 grey), so the phone dissolves into the page with no tinted seam.
            .init(color: .white, location: 1.0),
        ], startPoint: .top, endPoint: .bottom)
        return DeviceFrame {
            Rectangle().fill(wallpaper)
                // A soft highlight behind the banner for depth.
                .overlay {
                    RadialGradient(colors: [Color.white.opacity(0.16), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.26), startRadius: 2, endRadius: 210)
                        .blendMode(.screen)
                }
                // Status bar, flanking the island.
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
                    .padding(.horizontal, 22).padding(.top, 18)
                }
                // The reminder slides down from above as ONE solid unit (hidden by the screen's
                // clip, not by fading) and settles with a gentle spring, like a real iOS banner.
                // Reduce Motion fades.
                .overlay(alignment: .top) {
                    lockNotification(unit)
                        .padding(.horizontal, 12).padding(.top, 62)
                        .offset(y: (notificationPopped || reduceMotion) ? 0 : -155)
                        .opacity(reduceMotion ? (notificationPopped ? 1 : 0) : 1)
                }
        }
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

    /// The location beat — a permission hero (glass pass 2026-08-27): the glowing arrow, why we
    /// ask, and the app's own Today map on a device, dissolving into the CTA. This beat is ONLY
    /// about location; checkout follows it (2026-09-12: review → Health → here → paywall), so
    /// the headline and CTA stay neutral and promise no ending.
    private var primersStep: some View {
        OnboardingHeroPage {
            Spacer(minLength: Theme.Space.md)
            // A device finding you: rings ping out from the glyph while the needle swings past
            // north and rocks to rest. Both finish in the first second; then the page is still.
            GlowGlyph(systemName: "location.north.fill", tint: Theme.iridescent[0])
                .compassSettle()
                .background { LocatingPing(tint: Theme.purple, diameter: 82) }
                .onboardingHover(amplitude: 3, tilt: 0, period: 3.6)
                .onboardingEntrance(0.02, lift: 10)
            OnboardingHeading(title: "Map your runs",
                              subtitle: "Your location traces every route and opens the map right where you are. Only while you're recording.", alignment: .center)
                .padding(.top, Theme.Space.md)
                .padding(.horizontal, Theme.Space.sm)
                .onboardingEntrance(0.08)
            Spacer(minLength: Theme.Space.md)
            // The app's own finished race: the Austin Marathon post-run (the same capture the
            // website's run detail uses), so the promise is a real traced route, not a stock map.
            DeviceFrame {
                Image("OnboardingShotPostRun")
                    .resizable().interpolation(.medium).scaledToFill()
            }
            // One pass of light across the glass, so the device reads as a screen rather than a
            // picture of one.
            .onboardingSheen(delay: 0.9)
            .frame(maxWidth: .infinity)
            // Tall enough that the whole traced course sits above the fade (owner note: the
            // marathon was cut off at 330); the heading above is short, so the page still fits.
            .frame(height: 420, alignment: .top)
            .bottomFade(from: 0.72)
            .onboardingEntrance(0.16, lift: 26)
            Spacer(minLength: 0)
        } actions: {
            // Permissions settle before generation. The personal reveal leads into checkout.
            OnboardingCTA(title: "Continue", inFlight: locationRequestInFlight) {
                guard !locationRequestInFlight else { return }
                locationRequestInFlight = true
                // The CTA owns the request so a fast tap can never outrun the prompt. Advance only
                // after iOS returns the athlete's real choice; the shared service retains the grant
                // for Today's map and every later GPS session.
                services.location.requestAuthorization { granted in
                    services.analytics.log(.onboardingPermission(
                        kind: "location", status: granted ? "granted" : "denied"))
                    locationRequestInFlight = false
                    leftPrimers = true
                    // The last beat: the athlete's answer (either way) opens checkout.
                    finishOnboarding()
                }
            }
                .padding(.top, Theme.Space.sm)
                .onboardingEntrance(0.26)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                // modals resolving on one frame is a stuck-screen bug this file works around
                // in several places.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { complete() }
            })
    }

    private var reviewPage: some View {
        OnboardingReviewView(ask: {
            guard vm.step == .review, !showPaywall, !completedOnce else { return }
            requestReview()
        }, raisesAsk: !Self.reviewAskSuppressed) { continueFromReview() }
    }

    /// The review page hands on to the two permission beats (Health, then location); checkout
    /// opens from the location beat. State, not a debounce, consumes the tap once.
    private func continueFromReview() {
        guard vm.step == .review, !showPaywall, !completedOnce else { return }
        services.analytics.log(.onboardingMilestone(action: "review_continue", step: "review", durationMs: nil))
        goingBack = false
        vm.advance()
    }

    private func continueFromReveal() {
        // State, rather than a timed debounce, consumes this CTA once. The next page is live
        // immediately, including when Reduce Motion removes the transition.
        guard vm.step == .reveal else { return }
        services.analytics.log(.onboardingMilestone(action: "reveal_continue", step: "reveal", durationMs: nil))
        goingBack = false
        // Retire the old page immediately so its outgoing layer cannot cover the new CTA.
        // The review artwork owns its own entrance; controls never participate in that motion.
        jumpCut = true
        vm.advance()
    }

    /// The location beat's answer opens checkout (or Today for entitled athletes). It is the last
    /// beat: by now the plan is saved, the review has been asked, Health is answered, and the map
    /// can open on the athlete.
    private func finishOnboarding() {
        guard !showPaywall, !completedOnce else { return }
        services.analytics.log(.onboardingMilestone(action: "primers_continue", step: "primers", durationMs: nil))
        leftPrimers = true   // defensive for deep links that jump past the location beat
        if paywall.isPro { complete(); return }
        // Arm the hard relaunch gate BEFORE presenting so a force-quit mid-wall re-opens checkout
        // from RootView instead of dropping the athlete into the app. `setPro(true)` clears it;
        // the narrow store-unreachable escape is intentionally only a one-launch deferral.
        paywall.onboardingGatePending = true
        showPaywall = true
    }

    /// Onboarding is over — clear the resume draft BEFORE handing off, or the stale draft
    /// (saved on every step change, including the post-plan beats) resurrects the tail of the
    /// flow the next time RootView sees no profile — e.g. right after Settings → Delete all
    /// data, which used to loop the athlete into a plan-less "Save your progress" forever
    /// (audit 2026-08-11).
    private func complete() {
        // One exit only: "Not now" on the account beat is the single unlatched advance in the
        // flow, and a fast double-tap ran the completion hand-off twice. Idempotent today, but
        // nothing downstream should have to stay that way by accident.
        guard !completedOnce else { return }
        completedOnce = true
        OnboardingDraftStore.clear()
        onComplete()
    }

    /// Tear down the onboarding presentation once, after verified purchase or Restore.
    private func exitPaywall() {
        paywallHandledExit = true
        complete()
    }

    // MARK: Scaffolding

    @ViewBuilder
    /// Insert the content and fade the flow up after the welcome's cue — or, through every
    /// other door, arrive at once.
    ///
    /// The fade is reserved for the hand-off from the welcome, where it plays under the burst and
    /// nothing is tappable yet. Everywhere else the content must be hittable the instant it exists:
    /// UIKit delivers no touches to a layer whose alpha is near zero, so a fade-from-nothing on a
    /// deep-linked reveal swallowed the tap on its own continue button (bisected 2026-09-05).
    private func reveal() {
        guard !revealed else { return }
        // Arriving from the welcome under motion, the burst's own frames call `revealNow` and
        // then clear `burstSpent` (`WelcomeHandoffBurst`) — never a timer of this view's own.
        guard reduceMotion || revealDelay <= 0 else { return }
        revealed = true
        burstSpent = true
    }

    /// The first question surfaces beneath the burst.
    private func revealNow() {
        guard !revealed else { return }
        withAnimation(.easeOut(duration: 0.6)) { revealed = true }
    }

    private func questionScaffold<C: View>(_ title: String, subtitle: String? = nil,
                                           @ViewBuilder _ content: () -> C) -> some View {
        // Keep generous type and illustrations on compact phones with overflow scrolling.
        // Continue stays pinned; optional detail lives in separate sheets.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if vm.step == .name || vm.step == .race {
                    OnboardingScene(vm: vm, step: vm.step)
                        .frame(height: typeSize.isAccessibilitySize ? 100 : 148)
                        .padding(.top, 8)
                }
                OnboardingHeading(title: title, subtitle: subtitle)
                    .padding(.top, 8)
                    .padding(.horizontal, Theme.Space.xs)
                    .onboardingEntrance(0.02, lift: 10)
                if ![.name, .race, .experience, .days, .intensity, .muscleFocus].contains(vm.step) {
                    OnboardingScene(vm: vm, step: vm.step)
                        .frame(height: typeSize.isAccessibilitySize ? 100 : (vm.step == .injuries ? 104 : 136))
                }
                VStack(spacing: 10) { content() }
                    // Room for the floating cards' drop shadows — the scroll view clips otherwise.
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Staggered entrance delay for the i-th element on a screen — the assemble cascade.
    private func cascade(_ i: Int) -> Double { 0.04 + Double(min(i, 4)) * 0.03 }

    /// Remember explicit choices so recommendations never overwrite a deliberate selection.
    private func pick(_ apply: () -> Void) {
        apply()
        touchedSteps.insert(vm.step)
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let dx: CGFloat = 20
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: goingBack ? -dx : dx)),
            removal: .opacity.combined(with: .offset(x: goingBack ? dx : -dx))
        )
    }

    /// Persist the real plan immediately. The loader reflects saving/ready, never a simulated
    /// analysis percentage. SwiftData writes stay on its owning actor and remain atomic.
    private func buildPlan() async {
        guard !Task.isCancelled, vm.step == .building, !generationInFlight else { return }
        generationInFlight = true
        defer { generationInFlight = false }
        await Task.yield()
        guard !Task.isCancelled, vm.step == .building else { return }
        if profile == nil {
            let started = ContinuousClock.now
            services.analytics.log(.onboardingMilestone(action: "generation_started", step: "building", durationMs: nil))
            // Arm recovery before saving: eviction between save and reveal must not bypass checkout.
            let previousGate = paywall.onboardingGatePending
            if !paywall.isPro { paywall.onboardingGatePending = true }
            do { profile = try vm.finish(in: context) }
            catch {
                paywall.onboardingGatePending = previousGate
                buildFailed = true
                services.analytics.log(.onboardingMilestone(action: "generation_failed", step: "building", durationMs: nil))
                return
            }
            let elapsed = started.duration(to: .now)
            let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            services.analytics.log(.onboardingMilestone(action: "generation_succeeded", step: "building", durationMs: ms))
            OnboardingDraftStore.clear()
            services.analytics.log(.planGenerated(disciplines: profile?.disciplines.count ?? 0))
            SKANConversion.record(.planBuilt)
        }
        buildCompleted = 1
        buildRing = 1
        guard !Task.isCancelled, vm.step == .building else { return }
        advanceAutomatically()
    }

}


/// Chips (benchmarks): raised white at rest; the ink fill when on carries its own weight.
private struct ChipRaise: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content } else { content.raised(Capsule()) }
    }
}

/// Sex segments: same rule as the chips, on the card radius.
private struct SegmentRaise: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content } else { content.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)) }
    }
}

/// Preferred-day discs: raised white at rest, raised ink when picked.
private struct DayDiscRaise: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.raised(Circle(), tone: .ink) } else { content.raised(Circle()) }
    }
}
