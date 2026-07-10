import SwiftUI
import SwiftData
import AuthenticationServices

/// Settings — currently the **subscription / billing** surface (PRD §10 honesty bar: status, plain
/// renewal terms, cancel in ≤2 taps, restore). Units / equipment / privacy / export land later.
struct SettingsView: View {
    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(AuthController.self) private var auth
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @State private var restoring = false
    @State private var exportFile: JSONExportFile?
    @State private var showExporter = false
    @State private var confirmDelete = false
    @State private var healthConnected = false
    @State private var connectingHealth = false
    @State private var importingHealth = false
    @State private var importMessage: String?
    @State private var showCoachChat = false

    /// App Store subscription management — one tap here, then cancel in the system sheet (≤2 taps).
    private let manageURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                section("SUBSCRIPTION") { paywall.isPro ? AnyView(proCard) : AnyView(freeCard) }
                section("COACH") { AnyView(coachCard) }
                section("APPLE HEALTH") { AnyView(healthCard) }
                section("DATA & PRIVACY") { AnyView(dataCard) }
                section("ACCOUNT") { AnyView(accountCard) }
                section("ABOUT") { AnyView(aboutCard) }
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { healthConnected = services.health.isAuthorized }
        .fullScreenCover(isPresented: $showCoachChat) {
            CoachChatView { showCoachChat = false }
        }
        .fileExporter(isPresented: $showExporter, document: exportFile,
                      contentType: .json, defaultFilename: "momentum-data") { _ in }
        .confirmationDialog("Delete all data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                DataManager.deleteAllUserData(in: context)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your profile, plan, and every workout from this device. This can’t be undone.")
        }
    }

    // MARK: Coach chat

    /// The immersive AI coach chat. It no longer occupies a tab (Profile took that slot); it lives
    /// here as an on-demand surface so the feature stays reachable without a permanent tab.
    private var coachCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Ask your coach anything — pace, programming, or how a session felt.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            actionRow("Open coach chat", icon: "sparkles") { showCoachChat = true }
        }
        .padding(Theme.Space.lg)
        .background(card)
    }

    // MARK: Apple Health

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if healthConnected {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "heart.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.pink).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("New workouts are saved to Apple Health.")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                Divider().overlay(Theme.hairline)
                Text("Import runs and rides from Apple Watch, Garmin, and anything else that syncs to Apple Health.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actionRow("Import from Apple Health", icon: "square.and.arrow.down", busy: importingHealth) {
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
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                }
            } else {
                Text("Save your runs, rides, and lifts to Apple Health.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                OversizedButton(title: "Connect Apple Health", systemImage: "heart.fill", isEnabled: !connectingHealth) {
                    Task {
                        connectingHealth = true
                        _ = await services.health.requestAuthorization()
                        healthConnected = services.health.isAuthorized
                        if healthConnected, let profile = profiles.first {
                            let metrics = await services.health.importedBodyMetrics()
                            if let kg = metrics.bodyMassKg { profile.bodyMassKg = kg }
                            if let rhr = metrics.restingHR { profile.restingHR = rhr }
                            try? context.save()
                        }
                        connectingHealth = false
                    }
                }
            }
        }
        .padding(Theme.Space.lg)
        .background(card)
    }

    // MARK: Account

    @ViewBuilder
    private var accountCard: some View {
        if auth.isGuest { guestAccountCard } else { signedInAccountCard }
    }

    /// A guest can keep everything they've logged by upgrading to Sign in with Apple — surfaced here
    /// as the back-up/sync prompt rather than ever blocking them.
    private var guestAccountCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "person.crop.circle").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guest").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Saved on this device only").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: 0)
            }
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
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            Text("Back up your training and sync across devices. Keeps everything you've logged so far.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.lg)
        .background(card)
    }

    private var signedInAccountCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "applelogo").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.displayName ?? "Signed in with Apple")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Sign in with Apple").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            Divider().overlay(Theme.hairline)
            Button { auth.signOut() } label: {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).frame(width: 24)
                    Text("Sign out").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.xs)
        .background(card)
    }

    // MARK: Data & privacy

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionRow("Export my data", icon: "square.and.arrow.up") {
                exportFile = JSONExportFile(data: DataManager.exportJSON(in: context))
                showExporter = true
            }
            Divider().overlay(Theme.hairline)
            Button(role: .destructive) { confirmDelete = true } label: {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "trash").font(.system(size: 15, weight: .semibold)).foregroundStyle(.red).frame(width: 24)
                    Text("Delete all data").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.xs)
        .background(card)
    }

    // MARK: Subscription

    private var proCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                BrandMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Momentum Pro").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Active").font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            Text("Manage or cancel anytime in the App Store — we’ll remind you before it renews.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.hairline)
            actionRow("Manage subscription", icon: "creditcard") { openURL(manageURL) }
            actionRow("Restore purchases", icon: "arrow.clockwise", busy: restoring) { restore() }
        }
        .padding(Theme.Space.lg)
        .background(card)
    }

    private var freeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("You’re on the free plan").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Unlock the AI coach, full multi-discipline plans, advanced analytics, and your full history.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            OversizedButton(title: "Go Pro", systemImage: "sparkles") { paywall.present(for: .aiCoach) }
                .padding(.top, 2)
            Button("Restore purchases") { restore() }
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity)
        }
        .padding(Theme.Space.lg)
        .background(card)
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("Version", value: appVersion)
            Divider().overlay(Theme.hairline)
            actionRow("Terms of Service", icon: "doc.text") { open("https://momentum.fit/terms") }
            Divider().overlay(Theme.hairline)
            actionRow("Privacy Policy", icon: "hand.raised") { open("https://momentum.fit/privacy") }
            Divider().overlay(Theme.hairline)
            // Map attribution (the on-map Mapbox/OSM credit is hidden, so it lives here).
            actionRow("Map data © Mapbox", icon: "map") { open("https://www.mapbox.com/about/maps/") }
            Divider().overlay(Theme.hairline)
            actionRow("Map data © OpenStreetMap", icon: "globe") { open("https://www.openstreetmap.org/copyright") }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.xs)
        .background(card)
    }

    // MARK: Building blocks

    private func section(_ title: String, @ViewBuilder _ content: () -> AnyView) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            content()
        }
    }

    private func actionRow(_ title: String, icon: String, busy: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).frame(width: 24)
                Text(title).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary) }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
            Spacer()
            Text(value).font(.rounded(Theme.FontSize.body, weight: .medium)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
        }
        .padding(.vertical, 10)
    }

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    private func restore() {
        Task { restoring = true; _ = await paywall.restore(); restoring = false }
    }
    private func open(_ s: String) { if let url = URL(string: s) { openURL(url) } }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(PaywallController(isPro: false))
        .environment(Services.live())
        .environment(AuthController(userID: "preview"))
}
