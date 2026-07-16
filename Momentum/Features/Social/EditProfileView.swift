import SwiftUI
import SwiftData
import PhotosUI

/// Edit the athlete's profile — solo-first (2026-07-16): name, photo, bio, and the body basics
/// that tune the engines (sex → anatomy figure; height/weight → fueling floors + calorie burn).
/// The social matrix that used to live here (@handle, default visibility, sharing toggles,
/// location granularity) left with the community back-burner; it returns with the feed.
/// Writes straight to the SwiftData `UserProfile` and saves on Done.
struct EditProfileView: View {
    @Bindable var profile: UserProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var pickedAvatar: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    avatarPicker
                    section("YOU") { AnyView(identityCard) }
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
            field("Bio", text: $profile.bio, placeholder: "A line about you", axis: .vertical)
        }
        .padding(.horizontal, Theme.Space.lg)
        .background(card)
    }

    // MARK: About you (sex drives the anatomy figure; height/weight tune your targets)

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("SEX").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
            HStack(spacing: Theme.Space.sm) {
                ForEach(BiologicalSex.allCases) { s in
                    let on = profile.sex == s.rawValue
                    Button { Haptics.selection(); profile.sex = on ? nil : s.rawValue } label: {
                        Text(s.label)
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.background))
                                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
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

    private var heightInches: Double { (profile.heightCm ?? 172.72) / 2.54 }
    private var heightLabel: String { let t = Int(heightInches.rounded()); return "\(t / 12)'\(t % 12)\"" }
    private func bumpHeight(_ up: Bool) {
        let inch = min(84, max(48, heightInches.rounded() + (up ? 1 : -1)))
        profile.heightCm = inch * 2.54
    }

    private var isLb: Bool { profile.weightUnit == WeightUnit.lb.rawValue }
    private var weightLabel: String {
        let kg = profile.bodyMassKg ?? 72.5748
        return isLb ? "\(Int((kg * Formatters.lbPerKg).rounded())) lb" : "\(Int(kg.rounded())) kg"
    }
    private func bumpWeight(_ up: Bool) {
        let kg = profile.bodyMassKg ?? 72.5748
        if isLb {
            let lb = (kg * Formatters.lbPerKg).rounded() + (up ? 5 : -5)
            profile.bodyMassKg = min(400, max(80, lb)) * Formatters.kgPerLb
        } else {
            profile.bodyMassKg = min(180, max(35, kg.rounded() + (up ? 1 : -1)))
        }
    }

    // MARK: Building blocks

    private func field(_ label: String, text: Binding<String>, placeholder: String, axis: Axis = .horizontal) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary).frame(width: 56, alignment: .leading)
            TextField(placeholder, text: text, axis: axis)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
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
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    private func save() {
        profile.displayName = profile.displayName.trimmingCharacters(in: .whitespaces)
        profile.bio = profile.bio.trimmingCharacters(in: .whitespaces)
        try? context.save()
        dismiss()
    }
}
