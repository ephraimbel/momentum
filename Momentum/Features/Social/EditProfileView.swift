import SwiftUI
import SwiftData
import PhotosUI

/// Edit the social profile + the full privacy matrix (docs/SOCIAL-LAYER.md). Every control defaults
/// conservative; nothing is shared until the athlete opts in here. Writes straight to the SwiftData
/// `UserProfile` and saves on Done.
struct EditProfileView: View {
    @Bindable var profile: UserProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var handle: String = ""
    @State private var pickedAvatar: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    avatarPicker
                    section("YOU") { AnyView(identityCard) }
                    section("DEFAULT VISIBILITY") { AnyView(visibilityCard) }
                    section("SHARING") { AnyView(sharingCard) }
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
            .onAppear { handle = profile.handle }
            .onChange(of: pickedAvatar) { _, item in Task { await loadAvatar(item) } }
        }
    }

    // MARK: Avatar

    private var avatarPicker: some View {
        VStack(spacing: Theme.Space.sm) {
            PhotosPicker(selection: $pickedAvatar, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(photo: profile.avatarData, name: profile.displayName.isEmpty ? "You" : profile.displayName, size: 96)
                    Image(systemName: "camera.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.background)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.ink))
                        .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                }
            }
            Text(profile.avatarData == nil ? "Add a profile photo" : "Change photo")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            if profile.avatarData != nil {
                Button("Remove photo", role: .destructive) {
                    profile.avatarData = nil; try? context.save(); Haptics.medium()
                }
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadAvatar(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        profile.avatarData = WorkoutPhotoSection.downscaled(data, maxDimension: 512)
        try? context.save()
        Haptics.success()
    }

    // MARK: Identity

    private var identityCard: some View {
        VStack(spacing: 0) {
            field("Name", text: $profile.displayName, placeholder: "Your name")
            divider
            HStack(spacing: 0) {
                Text("@").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                TextField("handle", text: $handle)
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: handle) { _, new in handle = SocialPrivacy.normalizedHandle(new) }
            }
            .padding(.vertical, 12)
            divider
            field("City", text: $profile.city, placeholder: "Optional")
            divider
            field("Bio", text: $profile.bio, placeholder: "A line about you", axis: .vertical)
        }
        .padding(.horizontal, Theme.Space.lg)
        .background(card)
    }

    // MARK: Default visibility

    private var visibilityCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Picker("Default", selection: visibility) {
                ForEach(WorkoutPrivacy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("New workouts start at this visibility. You can change any single workout later.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.lg)
        .background(card)
    }

    // MARK: Sharing toggles

    private var sharingCard: some View {
        VStack(spacing: 0) {
            toggle("Appear on the map", "Show as a fuzzed dot while active. Never your exact location.",
                   isOn: $profile.appearOnMap)
            divider
            toggle("Public route maps", "Include trimmed, fuzzed routes on public posts.",
                   isOn: $profile.publicRouteMaps)
            divider
            toggle("Show exact numbers", "Pace and weights on your public posts.",
                   isOn: $profile.showExactNumbers)
            divider
            toggle("Discoverable", "Let others find you in search and suggestions.",
                   isOn: $profile.discoverable)
            divider
            HStack {
                Text("Location shown").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Picker("", selection: granularity) {
                    ForEach(LocationGranularity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).tint(Theme.inkSecondary)
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.xs)
        .background(card)
    }

    // MARK: Bindings + building blocks

    private var visibility: Binding<WorkoutPrivacy> {
        Binding(get: { WorkoutPrivacy(rawValue: profile.defaultWorkoutVisibility) ?? .private },
                set: { profile.defaultWorkoutVisibility = $0.rawValue })
    }
    private var granularity: Binding<LocationGranularity> {
        Binding(get: { LocationGranularity(rawValue: profile.locationGranularity) ?? .off },
                set: { profile.locationGranularity = $0.rawValue })
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, axis: Axis = .horizontal) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary).frame(width: 56, alignment: .leading)
            TextField(placeholder, text: text, axis: axis)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
        }
        .padding(.vertical, 12)
    }

    private func toggle(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.ink)
        .padding(.vertical, 10)
        .accessibilityLabel(title)
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
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    private func save() {
        profile.handle = SocialPrivacy.normalizedHandle(handle)
        profile.displayName = profile.displayName.trimmingCharacters(in: .whitespaces)
        profile.bio = profile.bio.trimmingCharacters(in: .whitespaces)
        profile.city = profile.city.trimmingCharacters(in: .whitespaces)
        try? context.save()
        dismiss()
    }
}
