import SwiftUI
import SwiftData
import AuthenticationServices

/// Settings (PRD §10 honesty bar: status, plain renewal terms, cancel in ≤2 taps, restore).
/// One quiet row grammar throughout: 28pt icon chips, slim rows, inset hairlines, and explainer
/// copy demoted to section footers so the cards themselves stay lean. About is a centered colophon,
/// not a card — the page ends quietly.
struct SettingsView: View {
    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(AuthController.self) private var auth
    @Environment(CoachPresenter.self) private var coach
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @State private var restoring = false
    @State private var restoreMessage: String?   // only failure/no-op paths — success flips the card itself
    @State private var exportFile: JSONExportFile?
    /// A store the app failed to open on some earlier launch, moved aside rather than deleted
    /// (`PersistenceController.quarantineStore`). Nil on every healthy install.
    @State private var quarantine: PersistenceController.QuarantineRecord?
    /// The quarantined store, zipped so it can leave the app through the share sheet. Prepared off
    /// the main actor because a store carrying real GPS history is not small.
    @State private var quarantineZip: URL?
    @State private var showExporter = false
    @State private var exporting = false      // fetch+encode runs off-main; the row shows a spinner
    @State private var exportMessage: String?
    @State private var confirmDelete = false
    @State private var deletingData = false   // background wipe in flight; the row shows a spinner
    @State private var healthConnected = false
    @State private var connectingHealth = false
    @State private var healthDenied = false   // the permission sheet was declined — say so, don't dead-end
    @State private var importingHealth = false
    @State private var importMessage: String?
    @State private var showingSignInOptions = false   // guest upgrade via Google/email (the gate's page)
    @State private var confirmDeleteAccount = false
    @State private var deletingAccount = false
    @State private var deleteAccountFailed = false
    @State private var offerDeviceErase = false   // post-account-deletion: offer the local wipe

    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    /// Persisted mute for the run voice coach — the live service reads this same key, so flipping it
    /// takes effect on the very next cue, mid-run included.
    @AppStorage(VoiceCoachService.storageKey) private var voiceCoachEnabled = true

    /// App Store subscription management — one tap here, then cancel in the system sheet (≤2 taps).
    private let manageURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                identityHeader
                section("MEMBERSHIP", footer: membershipFooter) { membershipCard }
                section("PREFERENCES", footer: preferencesFooter) { preferencesCard }
                section("APPLE HEALTH", footer: healthFooter) { healthCard }
                section("DATA & PRIVACY") { dataCard }
                section("ACCOUNT", footer: accountFooter) { accountCard }
                colophon
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        #if DEBUG
        // Screenshot verification: open pre-scrolled to the page's end (colophon).
        .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("--settings-bottom") ? .bottom : .top)
        #endif
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { healthConnected = services.health.isAuthorized }
        // Load the quarantine record, and — only if there is one — zip the set-aside store so the
        // share sheet has something to hand over. Off the main actor: this is file IO over a store
        // that may carry a season of GPS samples, and Settings must not hitch to find out there is
        // nothing to do. On a healthy install the guard falls through immediately.
        .task {
            quarantine = PersistenceController.quarantineRecord
            guard let record = quarantine, record.recovered, quarantineZip == nil else { return }
            let path = record.path
            quarantineZip = await Task.detached { archiveForSharing(URL(fileURLWithPath: path)) }.value
        }
        .fileExporter(isPresented: $showExporter, document: exportFile,
                      contentType: .json, defaultFilename: "momentum-data") { result in
            if case .failure = result { exportMessage = "Couldn't save the export — try again." }
        }
        .fullScreenCover(isPresented: $showingSignInOptions) {
            SignInView(startOnSignInPage: true)
        }
        .confirmationDialog("Delete all data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                // Background chunked wipe — the synchronous version froze the UI for seconds on
                // real histories (every GPS fix row cascade-deleted on the main context). The
                // profile goes last, so RootView flips to onboarding only once everything's gone.
                deletingData = true
                Task {
                    await DataManager.deleteAllUserData(container: context.container)
                    deletingData = false   // normally moot (RootView re-onboards) — never spin forever
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The consequence AND the landing: a reset athlete goes back through setup, where the
            // coach rebuilds their plan — they don't wander a gutted app wondering what's next.
            Text("This permanently removes everything on this device — profile, plan, workouts, meals, and awards. It can't be undone, so Export my data first if you want a copy. You'll stay signed in and go back through setup, where your coach builds you a fresh plan. Only want a new plan? Do that from the Plan tab — nothing gets deleted.")
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
            Button("Delete my account", role: .destructive) {
                Task {
                    deletingAccount = true
                    deleteAccountFailed = false
                    let ok = await auth.deleteAccount()
                    deletingAccount = false
                    deleteAccountFailed = !ok
                    // Second half of the hand-hold: the server side is gone — now offer the
                    // device. Two separate decisions, each with its own consent.
                    if ok { offerDeviceErase = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your account and backups from momentum's servers, then signs you out. It can't be undone. Data on this device stays — you'll choose what to do with it next.")
        }
        .alert("Account deleted", isPresented: $offerDeviceErase) {
            Button("Erase this device too", role: .destructive) {
                deletingData = true
                Task {
                    await DataManager.deleteAllUserData(container: context.container)
                    deletingData = false
                }
            }
            Button("Keep my data", role: .cancel) {}
        } message: {
            Text("Everything on momentum's servers is gone. The workouts and meals on this phone are still here — keep training as a guest, or erase them too and start completely fresh from setup.")
        }
    }

    // MARK: Identity header

    /// Who this is — their actual profile photo (the same identity Profile and the feed show), name,
    /// how they're signed in. Reads before any card does. No photo → the quiet monochrome monogram
    /// (deliberately not AvatarView's pastel chip — that's a feed device for telling many people
    /// apart; Settings stays monochrome).
    private var identityHeader: some View {
        HStack(spacing: Theme.Space.md) {
            if let photo = profiles.first?.avatarData {
                AvatarView(photo: photo, name: identityTitle, size: 52)
            } else {
                monogramCircle
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(identityTitle)
                    .font(.display(Theme.FontSize.headline, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(identitySubtitle)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var monogramCircle: some View {
        ZStack {
            Circle().fill(Theme.surface)
            Circle().stroke(Theme.hairline)
            if auth.isGuest {
                Image(systemName: "person.fill")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            } else {
                Text(monogram).font(.display(20, weight: .semibold)).foregroundStyle(Theme.ink)
            }
        }
        .frame(width: 52, height: 52)
    }

    /// The athlete's chosen profile name — the identity shown everywhere else (Profile, feed). Settings
    /// mirrors it so the account row never diverges from the app, and never surfaces a raw auth default.
    private var profileName: String? {
        let n = (profiles.first?.displayName ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }
    private var monogram: String {
        String((profileName ?? auth.displayName ?? auth.email ?? "?").trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
    private var identityTitle: String {
        auth.isGuest ? "Guest" : (profileName ?? auth.displayName ?? auth.email ?? "Signed in")
    }
    private var identitySubtitle: String {
        auth.isGuest ? "Saved on this device only" : accountProvider.label
    }

    /// The account row reflects how they actually signed in — Apple / Google / email.
    private var accountProvider: (icon: String, label: String) {
        let id = auth.userID ?? ""
        if id.hasPrefix("email:") { return ("envelope.fill", "Email account") }
        if id.hasPrefix("google:") { return ("globe", "Google account") }
        return ("applelogo", "Sign in with Apple")
    }

    // MARK: Membership

    @ViewBuilder
    private var membershipCard: some View {
        if paywall.isPro { proCard } else { freeCard }
    }

    private var membershipFooter: String? {
        paywall.isPro
            // No invented promises in review-visible copy: the app sends no renewal reminder
            // (Apple does, by email) — claim only what we do. Cancel stays the honest ≤2 taps.
            ? "Manage or cancel anytime in the App Store — two taps, no hoops."
            : "Unlock the AI coach, full multi-discipline plans, advanced analytics, and your full history."
    }

    private var proCard: some View {
        card {
            HStack(spacing: Theme.Space.md) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Momentum Pro").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    HStack(spacing: 5) {
                        Circle().fill(Theme.success).frame(width: 6, height: 6)
                        Text("Active").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 11)
            inset
            actionRow("Manage subscription", icon: "creditcard") { openURL(manageURL) }
            inset
            actionRow("Restore purchases", icon: "arrow.clockwise", busy: restoring) { restore() }
            restoreOutcome
        }
    }

    /// Failure/no-op feedback under the restore row — a successful restore speaks for itself
    /// (the card flips to "Active"), but silence on the other paths read as a broken button.
    @ViewBuilder
    private var restoreOutcome: some View {
        if let restoreMessage {
            Text(restoreMessage)
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .padding(.leading, 40).padding(.bottom, 10)
        }
    }

    private var freeCard: some View {
        card {
            Button {
                Haptics.light()
                paywall.present(for: .aiCoach)
            } label: {
                HStack(spacing: Theme.Space.md) {
                    BrandMark(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Momentum Pro").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("Coach, plans, analytics").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("Upgrade")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.background)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.ink))
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            inset
            actionRow("Restore purchases", icon: "arrow.clockwise", busy: restoring) { restore() }
            restoreOutcome
        }
    }

    // MARK: Preferences

    private var preferencesCard: some View {
        card {
            HStack(spacing: Theme.Space.md) {
                iconChip("circle.lefthalf.filled")
                Text("Appearance").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: Theme.Space.sm)
                appearancePicker
            }
            .padding(.vertical, 9)
            inset
            // Measurement units — so athletes outside the US aren't stuck reading miles. Distance,
            // pace, and speed everywhere follow this; "Auto" tracks the device region.
            unitRow(icon: "ruler", label: "Distance", a11yNoun: "distance",
                    options: [("auto", "Auto"), ("imperial", "Miles"), ("metric", "Km")],
                    selected: profiles.first?.distanceUnit ?? "auto") { setDistanceUnit($0) }
            inset
            unitRow(icon: "scalemass", label: "Weight", a11yNoun: "weight",
                    options: [("kg", "Kg"), ("lb", "Lb")],
                    selected: profiles.first?.weightUnit ?? WeightUnit.default().rawValue) { setWeightUnit($0) }
            inset
            actionRow("Coach chat", icon: "sparkles") { coach.open() }
            // The mute only makes sense once the voice coach exists for this user (it's Pro).
            if services.paywall.isEntitled(to: .voiceCoach) {
                inset
                HStack(spacing: Theme.Space.md) {
                    iconChip("waveform")
                    Toggle(isOn: $voiceCoachEnabled) {
                        Text("Voice coach").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.ink)
                }
                .padding(.vertical, 9)
                .accessibilityLabel("Voice coach")
            }
        }
    }

    private var preferencesFooter: String? {
        services.paywall.isEntitled(to: .voiceCoach)
            ? "The voice coach speaks splits, step changes, and pace cues on guided runs."
            : nil
    }

    /// A compact monochrome segmented control — System · Light · Dark. One tap, app-wide.
    private var appearancePicker: some View {
        HStack(spacing: 2) {
            ForEach(AppAppearance.allCases) { option in
                let on = appearanceRaw == option.rawValue
                Button {
                    Haptics.selection()
                    withAnimation(.easeOut(duration: 0.2)) { appearanceRaw = option.rawValue }
                } label: {
                    Text(option.label)
                        .font(.rounded(12, weight: .semibold))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Theme.background : Theme.inkSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background { if on { Capsule().fill(Theme.ink) } }
                        // The visible pill is ~24pt tall — well under the 44pt minimum. Extend the
                        // hit region vertically only (never horizontally — the segments sit 2pt
                        // apart), keeping the control's look exactly as shipped.
                        .contentShape(VerticalHitPad(dy: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label) appearance")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            Capsule().fill(Theme.background)
            Capsule().stroke(Theme.hairline)
        }
    }

    /// A units row: labelled icon + the same compact segmented control as Appearance.
    private func unitRow(icon: String, label: String, a11yNoun: String,
                         options: [(value: String, label: String)],
                         selected: String, onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: Theme.Space.md) {
            iconChip(icon)
            Text(label).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .lineLimit(1).fixedSize()
            Spacer(minLength: Theme.Space.sm)
            unitPicker(options, selected: selected, a11yNoun: a11yNoun, onSelect: onSelect)
        }
        .padding(.vertical, 9)
    }

    /// The Appearance segmented control, generalized over a list of (stored value, label) options.
    private func unitPicker(_ options: [(value: String, label: String)], selected: String,
                            a11yNoun: String, onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selected
                Button {
                    Haptics.selection()
                    onSelect(option.value)
                } label: {
                    Text(option.label)
                        .font(.rounded(12, weight: .semibold))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Theme.background : Theme.inkSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background { if on { Capsule().fill(Theme.ink) } }
                        .contentShape(VerticalHitPad(dy: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label) \(a11yNoun)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            Capsule().fill(Theme.background)
            Capsule().stroke(Theme.hairline)
        }
    }

    private func setDistanceUnit(_ value: String) {
        guard let p = profiles.first, p.distanceUnit != value else { return }
        withAnimation(.easeOut(duration: 0.2)) { p.distanceUnit = value }
        try? context.save()
    }

    private func setWeightUnit(_ value: String) {
        guard let p = profiles.first, p.weightUnit != value else { return }
        withAnimation(.easeOut(duration: 0.2)) { p.weightUnit = value }
        try? context.save()
    }

    // MARK: Apple Health

    private var healthCard: some View {
        card {
            if healthConnected {
                HStack(spacing: Theme.Space.md) {
                    iconChip("heart.fill", tint: .pink)
                    Text("Apple Health").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Circle().fill(Theme.success).frame(width: 6, height: 6)
                        Text("Connected").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                .padding(.vertical, 11)
                inset
                actionRow("Import workouts", icon: "square.and.arrow.down", busy: importingHealth) {
                    Task {
                        importingHealth = true
                        importMessage = nil
                        let n = await services.health.importExternalWorkouts(into: context, since: nil)
                        importMessage = n == 0 ? "No new workouts to import."
                            : "Imported \(n) workout\(n == 1 ? "" : "s")."
                        importingHealth = false
                    }
                }
                if let importMessage {
                    Text(importMessage)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .padding(.leading, 40).padding(.bottom, 10)
                }
            } else {
                Button {
                    Haptics.light()
                    Task {
                        connectingHealth = true
                        healthDenied = false
                        _ = await services.health.requestAuthorization()
                        healthConnected = services.health.isAuthorized
                        if healthConnected, let profile = profiles.first {
                            let metrics = await services.health.importedBodyMetrics()
                            if let kg = metrics.bodyMassKg { profile.bodyMassKg = kg }
                            if let rhr = metrics.restingHR { profile.restingHR = rhr }
                            try? context.save()
                            // Connect = filled, not connect-then-find-the-import-button: pull the
                            // history their devices already mirrored into Health, right now.
                            let n = await services.health.importExternalWorkouts(into: context, since: nil)
                            if n > 0 { importMessage = "Imported \(n) workout\(n == 1 ? "" : "s") from Health." }
                        } else if !healthConnected {
                            // HealthKit only shows its sheet while permission is undetermined —
                            // after one decline every later tap is a spinner then nothing, so
                            // the athlete must be told where to flip it back on.
                            healthDenied = true
                        }
                        connectingHealth = false
                    }
                } label: {
                    HStack(spacing: Theme.Space.md) {
                        iconChip("heart.fill", tint: .pink)
                        Text("Apple Health").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        if connectingHealth {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Connect")
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.background)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(Theme.ink))
                        }
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(connectingHealth)
                if healthDenied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Health access is off for momentum. Turn it on in the Health app — Profile → Apps → momentum — then tap Connect again.")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Health") { open("x-apple-health://") }
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    .padding(.leading, 40).padding(.bottom, 10)
                }
            }
        }
    }

    private var healthFooter: String? {
        healthConnected
            ? "New workouts save to Apple Health. Import brings in runs and rides from Apple Watch, Garmin, and anything else that syncs there."
            : "Save your runs, rides, and lifts to Apple Health — and import from Apple Watch, Garmin, and more."
    }

    // MARK: Data & privacy

    private var dataCard: some View {
        card {
            // The rarest block in the app and the most important when it appears: a previous launch
            // could not open the store and moved it aside instead of deleting it. Never red — a
            // corrupt store is not the athlete's fault — and never a launch-time alert, which on a
            // broken app is a trap. It stays here until they dismiss it themselves.
            if let quarantine, quarantine.recovered {
                VStack(alignment: .leading, spacing: 6) {
                    Text("We couldn't open your training data")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    // No support clause: there is no contact route in the app and no import path,
                    // so promising "send it to support to get it back" would name a destination
                    // that does not exist. Say only what is true — the file is still here, and it
                    // can leave the phone. Widen this the day a contact row and an importer ship.
                    Text("On \(quarantine.at.formatted(date: .abbreviated, time: .shortened)) this app started with an empty library. Your previous data was set aside rather than deleted, and you can save a copy of it here.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 11)
                if let quarantineZip {
                    ShareLink(item: quarantineZip) {
                        HStack(spacing: Theme.Space.md) {
                            iconChip("arrow.down.doc")
                            Text("Save a copy")
                                .font(.rounded(Theme.FontSize.body, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    actionRow("Preparing your copy", icon: "arrow.down.doc", busy: true) {}
                }
                inset
                actionRow("Dismiss", icon: "xmark") {
                    PersistenceController.quarantineRecord = nil
                    self.quarantine = nil
                    self.quarantineZip = nil
                }
                inset
            }
            // Fetch + pretty-print encode off the main thread — synchronously in the tap it was a
            // perceptible hitch at real history sizes (every workout's gps/strength row faulted).
            actionRow("Export my data", icon: "square.and.arrow.up", busy: exporting) {
                guard !exporting else { return }
                exporting = true
                exportMessage = nil
                Task {
                    let data = await DataManager.exportJSON(container: context.container)
                    exporting = false
                    // Empty Data is the encoder's swallowed-failure sentinel — refuse to hand
                    // the athlete a 0-byte "export" as if it worked.
                    guard !data.isEmpty else {
                        exportMessage = "Couldn't prepare your export — try again."
                        return
                    }
                    exportFile = JSONExportFile(data: data)
                    showExporter = true
                }
            }
            if let exportMessage {
                Text(exportMessage)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .padding(.leading, 40).padding(.bottom, 10)
            }
            inset
            actionRow("Delete all data", icon: "trash", tint: .red, busy: deletingData) {
                guard !deletingData else { return }
                confirmDelete = true
            }
            inset
            // App Review 1.4.1: the sports-science citations behind every computed number,
            // one obvious tap from Settings.
            NavigationLink { ScienceSourcesView() } label: {
                HStack(spacing: Theme.Space.md) {
                    iconChip("text.book.closed")
                    Text("Science & sources")
                        .font(.rounded(Theme.FontSize.body, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Account

    @ViewBuilder
    private var accountCard: some View {
        if auth.isGuest { guestAccountCard } else { signedInAccountCard }
    }

    private var accountFooter: String? {
        // No cross-device claim: sync is upload-only — there is no download/restore path yet, so
        // "sync across devices" was a promise the app can't keep. Same wording as the account beat
        // at the end of onboarding (AccountOptionsView.subtitle) — keep the two honest together.
        auth.isGuest
            ? "Keep a backup of your training off this phone. Everything you've logged so far comes with you."
            : nil
    }

    /// A guest can keep everything they've logged by upgrading to Sign in with Apple — surfaced here
    /// as the back-up/sync prompt rather than ever blocking them.
    private var guestAccountCard: some View {
        card {
            SignInWithAppleButton(.signIn) { request in
                auth.prepareAppleSignIn(request)   // scopes + Supabase nonce when configured
            } onCompletion: { result in
                if case .success(let authResult) = result,
                   let credential = authResult.credential as? ASAuthorizationAppleIDCredential {
                    // Upgrading from guest keeps all local data (see AuthController.signIn);
                    // when Supabase is configured this also bridges to a cloud session (JWT).
                    auth.signIn(credential: credential)
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .padding(.vertical, Theme.Space.md)
            Button {
                Haptics.light()
                showingSignInOptions = true
            } label: {
                Text("More ways to sign in — Google or email")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Theme.Space.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var signedInAccountCard: some View {
        card {
            actionRow("Sign out", icon: "rectangle.portrait.and.arrow.right") { auth.signOut() }
            inset
            // App Store 5.1.1(v): account deletion, in-app, no support-ticket detour.
            actionRow("Delete account", icon: "person.crop.circle.badge.xmark", tint: .red,
                      busy: deletingAccount) { confirmDeleteAccount = true }
            if deleteAccountFailed {
                // Covers both failure shapes honestly: a network error, AND the stale-session
                // case (signed in offline, the Supabase bridge never re-ran) where retrying
                // with connectivity can never succeed until a fresh sign-in.
                Text("Couldn't delete the account — check your connection, or sign out and back in, then try again.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .padding(.leading, 40).padding(.bottom, 10)
            }
        }
    }

    // MARK: Colophon

    /// The quiet end of the page — mark, version, legal. Attribution lives here because the on-map
    /// Mapbox/OSM credit is hidden.
    private var colophon: some View {
        VStack(spacing: Theme.Space.sm) {
            BrandMark(size: 28)
            Text("Version \(appVersion)")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
            HStack(spacing: Theme.Space.xs) {
                NavigationLink { ScienceSourcesView() } label: {
                    Text("Sources").font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .underline()
                        .contentShape(VerticalHitPad(dy: 16))
                }
                .buttonStyle(.plain)
                dot
                colophonLink("Terms", url: "https://momentumco.app/terms")
                dot
                colophonLink("Privacy", url: "https://momentumco.app/privacy")
                dot
                colophonLink("© Mapbox", url: "https://www.mapbox.com/about/maps/")
                dot
                colophonLink("© OpenStreetMap", url: "https://www.openstreetmap.org/copyright")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.md)
    }

    private var dot: some View {
        Text("·").font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
    }

    private func colophonLink(_ title: String, url: String) -> some View {
        Button { open(url) } label: {
            Text(title).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .underline()
                // ~13pt of text is the whole hit target otherwise — pad the region invisibly
                // (vertical only; the links sit close together horizontally).
                .contentShape(VerticalHitPad(dy: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: Building blocks

    /// The one card shell: soft surface, hairline edge, content inset to the shared grid.
    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
    }

    /// A hairline between rows, inset past the icon chips so titles align through it.
    private var inset: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 40)
    }

    /// The 28pt icon chip that leads every row — background-on-surface for a quiet two-tone depth.
    private func iconChip(_ systemName: String, tint: Color = Theme.ink) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.background)
                RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)
            }
    }

    private func section(_ title: String, footer: String? = nil,
                         @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title)
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.leading, Theme.Space.md)
            content()
            if let footer {
                Text(footer)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.md)
            }
        }
    }

    private func actionRow(_ title: String, icon: String, tint: Color = Theme.ink,
                           busy: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: Theme.Space.md) {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    iconChip(icon, tint: tint)
                }
                Text(title).font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(tint == .red ? .red : Theme.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    private func restore() {
        Task {
            restoring = true
            restoreMessage = nil
            let ok = await paywall.restore()
            restoring = false
            // Success flips the membership card to "Active" on its own — words only for the
            // paths that would otherwise be silent (mirrors PaywallView's post-restore check).
            if !paywall.isPro {
                restoreMessage = ok ? "Nothing to restore on this Apple ID."
                                    : "Couldn't reach the App Store — try again."
            }
        }
    }
    private func open(_ s: String) { if let url = URL(string: s) { openURL(url) } }
}

/// A hit-test region taller than the view it's attached to — for controls whose *visible* height
/// sits under the 44pt minimum but whose look shouldn't change (colophon links, the compact
/// appearance segments). Vertical only: expanding horizontally would overlap packed neighbors.
private struct VerticalHitPad: Shape {
    var dy: CGFloat
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: 0, dy: -dy)) }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(PaywallController(isPro: false))
        .environment(Services.live())
        .environment(AuthController(userID: "preview"))
}

/// Zip a quarantined store directory so it can leave the app through the share sheet.
/// `NSFileCoordinator`'s `.forUploading` option is the dependency-free way to archive a directory:
/// it hands back a temporary zip that is only guaranteed to exist inside the coordination block, so
/// the copy out is not optional. Returns nil rather than throwing — a failed rescue must not become
/// a second failure on top of the first.
private func archiveForSharing(_ directory: URL) -> URL? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else { return nil }
    var coordinationError: NSError?
    var archived: URL?
    NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading,
                                   error: &coordinationError) { zip in
        let destination = fm.temporaryDirectory
            .appendingPathComponent("momentum-recovered-\(directory.lastPathComponent).zip")
        try? fm.removeItem(at: destination)
        do {
            try fm.copyItem(at: zip, to: destination)
            archived = destination
        } catch {
            archived = nil
        }
    }
    return coordinationError == nil ? archived : nil
}
