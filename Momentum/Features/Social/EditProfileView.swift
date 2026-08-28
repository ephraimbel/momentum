import SwiftUI
import SwiftData
import PhotosUI

/// Edit the athlete's profile — solo-first (2026-07-16): name, photo, bio, and the body basics
/// that tune the engines (sex → anatomy figure; height/weight → fueling floors + calorie burn).
/// The social matrix that used to live here (@handle, default visibility, sharing toggles,
/// location granularity) left with the community back-burner; it returns with the feed.
///
/// Edits are STAGED in local state and written to the SwiftData `UserProfile` only on Done —
/// editing the live model directly meant Cancel (and swipe-down) silently kept every change,
/// including sex/height/weight that feed the anatomy figure and fueling engines.
struct EditProfileView: View {
    let profile: UserProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services

    @State private var pickedAvatar: PhotosPickerItem?

    /// The preset chosen this visit (ring in the strip). Cleared when a photo is picked or removed.
    @State private var selectedPreset: AvatarPreset?
    @State private var saveFailed = false
    // The staged copies — seeded from the profile once per presentation (the sheet view is
    // created fresh each time it's shown, so State(initialValue:) is the right seed point).
    @State private var name: String
    @State private var handle: String
    @State private var bio: String
    /// Where you train out of — optional by design (see `SocialPrivacy.granularity(forCity:current:)`).
    @State private var city: String
    @State private var sex: String?
    @State private var birthYear: Int?
    @State private var heightCm: Double?
    @State private var bodyMassKg: Double?
    @State private var avatarData: Data?
    /// The sports on the profile chips — and what the plan engine builds around. Never empty:
    /// the last one can't be turned off.
    @State private var disciplines: Set<String>


    init(profile: UserProfile) {
        self.profile = profile
        _name = State(initialValue: profile.displayName)
        _handle = State(initialValue: profile.handle)
        _bio = State(initialValue: profile.bio)
        _city = State(initialValue: profile.city)
        _sex = State(initialValue: profile.sex)
        _birthYear = State(initialValue: profile.birthYear)
        _heightCm = State(initialValue: profile.heightCm)
        _bodyMassKg = State(initialValue: profile.bodyMassKg)
        _avatarData = State(initialValue: profile.avatarData)
        _disciplines = State(initialValue: Set(profile.disciplines))

    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    avatarPicker
                    section("YOU") { AnyView(identityCard) }
                    section("SPORTS") { AnyView(sportsCard) }
                    section("ABOUT YOU") { AnyView(aboutCard) }
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() }.fontWeight(.semibold) }
            }
            .alert("Couldn't save your profile", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Something went wrong writing to storage. Your edits are still here — try Done again.")
            }
            .onChange(of: pickedAvatar) { _, item in Task { await loadAvatar(item) } }

            #if DEBUG
            // --pick-preset <case> [--pick-preset-save]: stage a preset look (and optionally Done)
            // for sim verification — the sheet's tiles are unreachable by simctl, and the window's
            // device bezels defeat coordinate clicking.
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard let i = args.firstIndex(of: "--pick-preset"), i + 1 < args.count,
                      let preset = AvatarPreset(rawValue: args[i + 1]) else { return }
                try? await Task.sleep(for: .milliseconds(600))
                avatarData = AvatarPreset.bake(preset, name: name.isEmpty ? "You" : name)
                selectedPreset = preset
                if args.contains("--pick-preset-save") {
                    try? await Task.sleep(for: .milliseconds(900))
                    save()
                }
            }
            #endif
        }
    }

    // MARK: Avatar

    private var avatarPicker: some View {
        VStack(spacing: Theme.Space.sm) {
            PhotosPicker(selection: $pickedAvatar, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(photo: avatarData, name: name.isEmpty ? "You" : name, size: 96)
                    Image(systemName: "camera.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.background)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.ink))
                        .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                }
            }
            Text(avatarData == nil ? "Add a profile photo" : "Change photo")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            if avatarData != nil {
                Button("Remove photo", role: .destructive) {
                    avatarData = nil; selectedPreset = nil; Haptics.medium()
                }
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
            }
            presetStrip
        }
        .frame(maxWidth: .infinity)
    }

    /// The curated looks — one tap stages the baked PNG exactly like a picked photo, so Cancel
    /// discards it and Done persists it with zero extra plumbing. The ring marks the tile chosen
    /// THIS visit; a photo pick clears it (the photo wins).
    private var presetStrip: some View {
        VStack(spacing: Theme.Space.sm) {
            Text("OR PICK A LOOK")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.top, Theme.Space.sm)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm),
                                     count: 4),
                      spacing: Theme.Space.sm) {
                ForEach(AvatarPreset.allCases) { preset in
                    Button {
                        guard let png = AvatarPreset.bake(preset, name: name.isEmpty ? "You" : name)
                        else { return }
                        avatarData = png
                        selectedPreset = preset
                        Haptics.selection()
                    } label: {
                        PresetAvatarView(preset: preset,
                                         name: name.isEmpty ? "You" : name, size: 56)
                            .overlay {
                                if selectedPreset == preset {
                                    Circle().stroke(Theme.ink, lineWidth: 2).padding(-3)
                                }
                            }
                    }
                    .buttonStyle(PressableScaleStyle(scale: 0.94))
                    .accessibilityLabel("Avatar look \(preset.rawValue)")
                }
            }
        }
    }

    private func loadAvatar(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        avatarData = WorkoutPhotoSection.downscaled(data, maxDimension: 512)
        selectedPreset = nil   // the photo wins over any preset picked earlier this visit
        Haptics.success()
    }

    // MARK: Identity

    private var identityCard: some View {
        VStack(spacing: 0) {
            field("Name", text: $name, placeholder: "Your name")
            divider
            // The @handle — same field onboarding claims with (live Supabase availability +
            // suggestions); the unique index at save time is the real arbiter, and a lost race
            // posts the deduped "handle taken" notification from claimProfile.
            HandleField(handle: $handle, backend: services.social,
                        suggestions: HandleSuggester.candidates(name: name, email: nil, seed: 7))
            divider
            field("Bio", text: $bio, placeholder: "A line about you", axis: .vertical)
            divider
            // Where you train out of — it rides in your byline ("@handle · Austin, TX") on your own
            // posts and on your profile. Blank is a real answer: filling this in IS the opt-in
            // (SocialPrivacy.granularity), so no city ever ships on a default nobody chose.
            field("Location", text: $city, placeholder: "City (optional)")
        }
        .padding(.horizontal, Theme.Space.lg)
        .background(card)
    }

    // MARK: About you (sex drives the anatomy figure; height/weight tune your targets)

    /// The chips the profile hero shows (owner ask 2026-08-27: "users should be able to edit those").
    /// Same capsule look as the hero's chips, ink-filled when on. Wraps; never a scroller.
    private var sportsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            FlowLayout(spacing: Theme.Space.sm) {
                ForEach(Discipline.allCases, id: \.self) { d in
                    let on = disciplines.contains(d.rawValue)
                    Button {
                        if on {
                            // Keep at least one: a plan with no sport is not a plan.
                            guard disciplines.count > 1 else { Haptics.medium(); return }
                            disciplines.remove(d.rawValue)
                        } else {
                            disciplines.insert(d.rawValue)
                        }
                        Haptics.selection()
                    } label: {
                        Text(d.rawValue.capitalized)
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                            .foregroundStyle(on ? Theme.background : Theme.inkSecondary)
                            .padding(.horizontal, Theme.Space.md - 2).padding(.vertical, Theme.Space.chipV + 1)
                            .background(Capsule().fill(on ? Theme.ink : Theme.surface))
                            .overlay(Capsule().stroke(on ? Theme.ink : Theme.hairline, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableScaleStyle(scale: 0.96))
                    .accessibilityLabel("\(d.rawValue.capitalized), \(on ? "on" : "off")")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text("These show on your profile and shape your plan.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .padding(Theme.Space.md)
        .background(card)
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("SEX").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
            HStack(spacing: Theme.Space.sm) {
                ForEach(BiologicalSex.allCases) { s in
                    let on = sex == s.rawValue
                    Button { Haptics.selection(); sex = on ? nil : s.rawValue } label: {
                        Text(s.label)
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .foregroundStyle(on ? .white : Theme.ink)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.purple) : AnyShapeStyle(Theme.background))
                                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            divider
            stepperRow("Age", value: ageLabel, dec: { bumpAge(false) }, inc: { bumpAge(true) })
            divider
            stepperRow("Height", value: heightLabel, dec: { bumpHeight(false) }, inc: { bumpHeight(true) })
            divider
            stepperRow("Weight", value: weightLabel, dec: { bumpWeight(false) }, inc: { bumpWeight(true) })
        }
        .padding(Theme.Space.lg)
        .background(card)
    }

    private func stepperRow(_ label: String, value: String, dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Button { Haptics.light(); dec() } label: { stepGlyph("minus") }.buttonStyle(.plain)
                .accessibilityLabel("Decrease \(label)")
            Text(value).font(.display(18, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                .frame(minWidth: 78).contentTransition(.numericText())
                .accessibilityLabel("\(label), \(value)")
            Button { Haptics.light(); inc() } label: { stepGlyph("plus") }.buttonStyle(.plain)
                .accessibilityLabel("Increase \(label)")
        }
        .padding(.vertical, 6)
        .animation(.snappy(duration: 0.2), value: value)
    }

    private func stepGlyph(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
            .frame(width: 40, height: 40).background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
    }

    // Age is stored as birth year (SI-of-time rule: derive display at render). "—" until set —
    // the VO₂max norms rating and fueling floors stay honestly un-personalized without it.
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var ageValue: Int? { birthYear.map { max(13, currentYear - $0) } }
    private var ageLabel: String { ageValue.map(String.init) ?? "—" }
    private func bumpAge(_ up: Bool) {
        let a = min(90, max(13, (ageValue ?? 30) + (up ? 1 : -1)))
        birthYear = currentYear - a
    }

    private var heightInches: Double { (heightCm ?? 172.72) / 2.54 }
    private var heightLabel: String { let t = Int(heightInches.rounded()); return "\(t / 12)'\(t % 12)\"" }
    private func bumpHeight(_ up: Bool) {
        let inch = min(84, max(48, heightInches.rounded() + (up ? 1 : -1)))
        heightCm = inch * 2.54
    }

    private var isLb: Bool { profile.weightUnit == WeightUnit.lb.rawValue }
    private var weightLabel: String {
        let kg = bodyMassKg ?? 72.5748
        return isLb ? "\(Int((kg * Formatters.lbPerKg).rounded())) lb" : "\(Int(kg.rounded())) kg"
    }
    private func bumpWeight(_ up: Bool) {
        let kg = bodyMassKg ?? 72.5748
        if isLb {
            let lb = (kg * Formatters.lbPerKg).rounded() + (up ? 5 : -5)
            bodyMassKg = min(400, max(80, lb)) * Formatters.kgPerLb
        } else {
            bodyMassKg = min(180, max(35, kg.rounded() + (up ? 1 : -1)))
        }
    }

    // MARK: Building blocks

    private func field(_ label: String, text: Binding<String>, placeholder: String, axis: Axis = .horizontal) -> some View {
        HStack(alignment: .top) {
            // 72pt fits the longest label ("Location") without truncating; every row shares the
            // gutter so the fields stay in one column.
            Text(label).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary).frame(width: 72, alignment: .leading)
            TextField(placeholder, text: text, axis: axis)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                // A stable handle for tests: a TextField's accessibility label is its placeholder
                // only while it's EMPTY — once it holds a value, the placeholder query stops
                // matching, so a round-trip test passes on a fresh install and fails on a second
                // run (2026-07-30). The identifier doesn't move.
                .accessibilityIdentifier("field-\(label)")
        }
        .padding(.vertical, 12)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> AnyView) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            content()
        }
    }

    private var divider: some View { Divider().overlay(Theme.hairline) }
    private var card: some View {
        ZStack {
            Color.clear.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    /// The ONLY place staged edits touch the model — Cancel and interactive dismiss never reach it.
    private func save() {
        profile.displayName = name.trimmingCharacters(in: .whitespaces)
        profile.handle = SocialPrivacy.normalizedHandle(handle)
        profile.bio = bio.trimmingCharacters(in: .whitespaces)
        let trimmedCity = city.trimmingCharacters(in: .whitespaces)
        profile.city = trimmedCity
        // Typing a location opts you in at city precision; clearing it takes it back off the wire.
        profile.locationGranularity = SocialPrivacy
            .granularity(forCity: trimmedCity, current: profile.locationGranularity).rawValue
        profile.sex = sex
        profile.birthYear = birthYear
        profile.heightCm = heightCm
        profile.bodyMassKg = bodyMassKg
        profile.avatarData = avatarData
        // Written in the enum's order so the chips read the same on every profile.
        profile.disciplines = Discipline.allCases.map(\.rawValue).filter { disciplines.contains($0) }

        // A failed write must not dismiss as if it saved — the staged edits would silently
        // revert on next launch while the sheet closed looking done.
        do { try context.save() } catch {
            context.rollback()
            saveFailed = true
            return
        }
        // The public projection follows the edit (name, bio, avatar — including a freshly-picked
        // preset bake): re-claim on the backend so other athletes see the change now, not at the
        // next cold launch. Fire-and-forget; guests/dark builds no-op inside.
        if CommunityAccess.enabled {
            let saved = profile
            let ctx = context
            Task { await services.social.claimProfile(saved, in: ctx) }
        }
        Haptics.success()
        dismiss()
    }
}
