import SwiftUI
import PhotosUI

/// Share composer (PRD §7.11/§25): swipe a style, pick a size, drop in a photo, export.
/// Classic is free; the styled set rides `Feature.allShareTemplates`. Every style previews for
/// everyone — the paywall moment is the Share button, never the mirror.
struct ShareCardView: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto

    @Environment(\.dismiss) private var dismiss
    @Environment(Services.self) private var services
    @Environment(PaywallController.self) private var paywall
    @State private var format: ShareFormat = .story
    #if DEBUG
    // --share-style=classic|photo|stacked|paper|sticker: preselect for sim verification.
    @State private var style: ShareStyle = {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--share-style=") }),
              let match = ShareStyle.allCases.first(where: {
                  $0.rawValue.lowercased() == String(arg.dropFirst("--share-style=".count)).lowercased()
              }) else { return .classic }
        return match
    }()
    #else
    @State private var style: ShareStyle = .classic
    #endif
    @State private var photoItem: PhotosPickerItem?
    @State private var pickedPhoto: UIImage?
    /// The workout's own photo, decoded ONCE (a full-res JPEG) — not re-decoded on every
    /// style/format/size tap the way an inline `UIImage(data:)` in `photo` would be.
    @State private var workoutPhoto: UIImage?
    /// The exported 3× card, rendered ONCE per style/format/photo change off the body path — the
    /// ShareLink item and its SharePreview both read this single image, so the full-res card never
    /// renders twice on every body pass.
    @State private var exportImage: UIImage?

    enum ShareFormat: String, CaseIterable, Identifiable {
        case story = "Story", square = "Square"
        var id: String { rawValue }
        var size: CGSize { self == .story ? CGSize(width: 1080, height: 1920) : CGSize(width: 1080, height: 1080) }
    }

    private var stats: ShareStats {
        ShareStats(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit)
    }

    /// The photo a photo-style card wears: explicit pick first, else the workout's own photo
    /// (decoded once into `workoutPhoto`, never inline here on the render path).
    private var photo: UIImage? { pickedPhoto ?? workoutPhoto }

    private var styleLocked: Bool {
        style.requiresPro && !paywall.isEntitled(to: .allShareTemplates)
    }

    @ViewBuilder
    private func card(size: CGSize) -> some View {
        switch style {
        case .classic:
            ShareCardContent(workout: workout, weightUnit: weightUnit,
                             distanceUnit: distanceUnit, size: size)
        case .photoTrio:
            PhotoTrioCard(workout: workout, stats: stats, photo: photo, size: size)
        case .photoStack:
            PhotoStackCard(workout: workout, stats: stats, photo: photo, size: size)
        case .paper:
            PaperCard(workout: workout, stats: stats, size: size)
        case .sticker:
            StickerCard(workout: workout, stats: stats, size: size)
        }
    }

    /// Re-render the export only when something the card actually draws changes.
    private struct ExportKey: Equatable {
        let style: ShareStyle
        let format: ShareFormat
        let photoID: ObjectIdentifier?
    }
    private var exportKey: ExportKey {
        ExportKey(style: style, format: format,
                  photoID: style.usesPhoto ? photo.map(ObjectIdentifier.init) : nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.md) {
                GeometryReader { geo in
                    let preview = format.size
                    let scale = min(geo.size.width / preview.width, geo.size.height / preview.height)
                    card(size: preview)
                        .background { if style == .sticker { stickerBackdrop } }
                        .scaleEffect(scale)
                        .frame(width: preview.width * scale, height: preview.height * scale)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                        // Composer-only edge — the light Paper card otherwise melts into the sheet.
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                styleRow

                HStack(spacing: Theme.Space.sm) {
                    Picker("Format", selection: $format) {
                        ForEach(ShareFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if style.usesPhoto {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 44, height: 32)
                                .background(Capsule().fill(Theme.surface)
                                    .overlay(Capsule().stroke(Theme.hairline)))
                        }
                        .accessibilityLabel("Choose a photo")
                    }
                }

                shareOrUnlock
            }
            .padding(Theme.Space.md)
            .background(Theme.background)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: photoItem) {
                guard let photoItem,
                      let data = try? await photoItem.loadTransferable(type: Data.self) else { return }
                pickedPhoto = UIImage(data: data)
            }
            // Decode the workout's own photo once, off the render path (photo styles read `photo`).
            .task(id: workout.id) {
                if workoutPhoto == nil, let data = workout.orderedPhotosData.first {
                    workoutPhoto = UIImage(data: data)
                }
            }
            // Render the full-res export ONCE per change, off the synchronous body/render path.
            .task(id: exportKey) {
                exportImage = ShareCardRenderer.render(card(size: format.size),
                                                       size: format.size,
                                                       opaque: style != .sticker)
            }
        }
    }

    /// Sticker previews over neutral gray so "transparent" is legible, not a black void.
    private var stickerBackdrop: some View {
        LinearGradient(colors: [Color(white: 0.42), Color(white: 0.25)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var styleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(ShareStyle.allCases) { s in
                    styleChip(s)
                }
            }
        }
    }

    private func styleChip(_ s: ShareStyle) -> some View {
        let locked = s.requiresPro && !paywall.isEntitled(to: .allShareTemplates)
        return Button {
            withAnimation(.smooth(duration: 0.25)) { style = s }
        } label: {
            HStack(spacing: 5) {
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                }
                Text(s.rawValue)
                    .font(.rounded(Theme.FontSize.caption, weight: .bold))
            }
            .foregroundStyle(style == s ? Theme.background : Theme.ink)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(style == s ? Theme.ink : (locked ? Theme.route.opacity(0.16) : Theme.surface))
                .overlay(Capsule().stroke(style == s ? Theme.ink : (locked ? Theme.route.opacity(0.45) : Theme.hairline))))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(style == s ? .isSelected : [])
    }

    @ViewBuilder
    private var shareOrUnlock: some View {
        if styleLocked {
            Button { paywall.present(for: .allShareTemplates) } label: {
                HStack(spacing: 7) {
                    Text("PRO").font(.rounded(10, weight: .heavy)).tracking(1.4)
                        .foregroundStyle(Color(hex: "0E0E12"))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.route))
                    Text("Unlock every style").font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.background)
                }
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
            }
            .buttonStyle(.plain)
        } else if let exportImage {
            let image = Image(uiImage: exportImage)
            ShareLink(item: image, preview: SharePreview("momentum", image: image)) {
                shareLabel
            }
            .simultaneousGesture(TapGesture().onEnded {
                services.analytics.log(.shareCreated(style: "\(style.rawValue)-\(format.rawValue)"))
            })
        } else {
            // Export still rendering off the body path — hold the button until the image is ready.
            shareLabel.opacity(0.5)
        }
    }

    private var shareLabel: some View {
        Label("Share", systemImage: "square.and.arrow.up")
            .font(.rounded(Theme.FontSize.body, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
            .foregroundStyle(Theme.background)
    }
}

/// Toolbar entry that opens the share composer.
struct ShareButton: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Image(systemName: "square.and.arrow.up") }
            .sheet(isPresented: $showing) {
                ShareCardView(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit)
            }
    }
}
