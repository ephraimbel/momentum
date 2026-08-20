import SwiftUI
import PhotosUI
import AVFoundation

/// Share composer (PRD §7.11/§25): swipe a style, drop in a photo or a clip, crop it, size the
/// overlay, export. Classic is free; the styled set rides `Feature.allShareTemplates`. Every style
/// previews for everyone — the paywall moment is the Share button, never the mirror.
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

    // MARK: Media
    @State private var pickerItem: PhotosPickerItem?
    /// What the card is wearing: an explicit pick, else the workout's own photo.
    @State private var media: ShareMedia?
    @State private var mediaAspect: CGFloat = 1
    @State private var transform: MediaTransform = .identity
    /// Captured at gesture start so a drag and a pinch compose from the same origin instead of
    /// integrating each other's output.
    @State private var gestureBase: MediaTransform?
    @State private var overlayScale: CGFloat = 1
    @State private var showingCamera = false
    @State private var loadingMedia = false
    /// The crop hint shows itself once and then stops competing with the card.
    @State private var hintRetired = false

    // MARK: Export
    /// The exported still, re-rendered off the body path and debounced — a 1080×1920 card at 3×
    /// re-rendered on every frame of a drag would make the crop unusable.
    @State private var exportImage: UIImage?
    @State private var exportedVideo: ExportedVideo?
    @State private var exportingVideo = false
    @State private var exportError: String?

    enum ShareFormat: String, CaseIterable, Identifiable {
        case story = "Story", square = "Square"
        var id: String { rawValue }
        var size: CGSize { self == .story ? CGSize(width: 1080, height: 1920) : CGSize(width: 1080, height: 1080) }
    }

    private struct ExportedVideo: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var stats: ShareStats {
        ShareStats(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit)
    }

    private var styleLocked: Bool {
        style.requiresPro && !paywall.isEntitled(to: .allShareTemplates)
    }

    /// Only photo styles wear media, and only they get the crop and overlay controls.
    private var editingMedia: Bool { style.usesPhoto && media != nil }

    @ViewBuilder
    private func card(size: CGSize, mediaHidden: Bool = false) -> some View {
        switch style {
        case .classic:
            ShareCardContent(workout: workout, weightUnit: weightUnit,
                             distanceUnit: distanceUnit, size: size)
        case .photoTrio:
            PhotoTrioCard(workout: workout, stats: stats, media: media, size: size,
                          transform: transform, mediaAspect: mediaAspect,
                          overlayScale: overlayScale, mediaHidden: mediaHidden)
        case .photoStack:
            PhotoStackCard(workout: workout, stats: stats, media: media, size: size,
                           transform: transform, mediaAspect: mediaAspect,
                           overlayScale: overlayScale, mediaHidden: mediaHidden)
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
        let media: ShareMedia?
        let transform: MediaTransform
        let overlayScale: CGFloat
    }
    private var exportKey: ExportKey {
        ExportKey(style: style, format: format,
                  media: style.usesPhoto ? media : nil,
                  transform: transform, overlayScale: overlayScale)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.md) {
                preview
                if style.usesPhoto { mediaControls }
                styleRow
                Picker("Format", selection: $format) {
                    ForEach(ShareFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                shareOrUnlock
            }
            .padding(Theme.Space.md)
            .background(Theme.background)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { image in adopt(.image(image)) }
                    .ignoresSafeArea()
            }
            .sheet(item: $exportedVideo) { video in
                ActivityView(items: [video.url])
            }
            .alert("Couldn't make that video",
                   isPresented: Binding(get: { exportError != nil },
                                        set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "") }
            .task(id: pickerItem) { await loadPickedItem() }
            // The workout's own photo is the default backdrop — the athlete already chose it once.
            .task(id: workout.id) {
                #if DEBUG
                // `--share-media`: preload a still so the crop gestures, the overlay slider and the
                // photo styles are screenshot-verifiable on a sim, which can't drive the system
                // Photos picker. The video path is covered by ShareVideoExportTests instead.
                if ProcessInfo.processInfo.arguments.contains("--share-media"),
                   let demo = UIImage(named: "WelcomeBackground") {
                    adopt(.image(demo))
                    return
                }
                #endif
                guard media == nil, let data = workout.orderedPhotosData.first,
                      let image = UIImage(data: data) else { return }
                adopt(.image(image))
            }
            // Debounced so a drag doesn't re-render a 3× card every frame; the task is cancelled and
            // restarted on each change, so this renders once, ~a quarter second after things settle.
            .task(id: exportKey) {
                guard !(media?.isVideo ?? false) || !style.usesPhoto else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                exportImage = ShareCardRenderer.render(card(size: format.size),
                                                       size: format.size,
                                                       opaque: style != .sticker)
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let canvas = format.size
            let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            card(size: canvas)
                .background { if style == .sticker { stickerBackdrop } }
                .scaleEffect(scale)
                .frame(width: canvas.width * scale, height: canvas.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                // Composer-only edge — the light Paper card otherwise melts into the sheet.
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
                .overlay(alignment: .top) { if editingMedia { cropHint } }
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .gesture(editingMedia ? cropGesture(previewScale: scale) : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Makes the crop discoverable without a coach mark, then gets out of the way.
    ///
    /// Pinned to the TOP: both photo styles keep their upper band clear (Trio floats the route from
    /// 12% down, Stacked composes about the centre), whereas the bottom is exactly where the stat
    /// row sits — anchoring it there laid the hint straight across DISTANCE · PACE · TIME. It also
    /// retires on its own, so it can't linger over a card the athlete is trying to judge.
    private var cropHint: some View {
        Text("Drag to move · pinch to zoom")
            .font(.rounded(11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.black.opacity(0.45)))
            .padding(.top, Theme.Space.sm)
            .opacity(transform.isIdentity && !hintRetired ? 1 : 0)
            .animation(.easeOut(duration: 0.3), value: transform.isIdentity)
            .animation(.easeOut(duration: 0.6), value: hintRetired)
            .allowsHitTesting(false)
            .task {
                try? await Task.sleep(for: .seconds(4))
                hintRetired = true
            }
    }

    /// Pan and pinch, in canvas units so the preview and the export crop identically.
    private func cropGesture(previewScale: CGFloat) -> some Gesture {
        let drag = DragGesture()
            .onChanged { value in
                let base = gestureBase ?? transform
                gestureBase = base
                var next = base
                next.offset = CGSize(width: base.offset.width + value.translation.width / previewScale,
                                     height: base.offset.height + value.translation.height / previewScale)
                transform = next.clamped(aspect: mediaAspect, canvas: format.size)
            }
            .onEnded { _ in gestureBase = nil }

        let zoom = MagnifyGesture()
            .onChanged { value in
                let base = gestureBase ?? transform
                gestureBase = base
                var next = base
                next.scale = base.scale * value.magnification
                transform = next.clamped(aspect: mediaAspect, canvas: format.size)
            }
            .onEnded { _ in gestureBase = nil }

        return drag.simultaneously(with: zoom)
    }

    // MARK: Media controls

    @ViewBuilder
    private var mediaControls: some View {
        if media == nil {
            mediaMenu {
                Label(loadingMedia ? "Loading…" : "Add a photo or video", systemImage: "photo.badge.plus")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
            }
        } else {
            HStack(spacing: Theme.Space.sm) {
                // One slider, one menu — the two things an athlete actually wants here, on one row,
                // because the sheet already carries a preview, a style rail, a format picker and a
                // primary action and a fifth stacked row squeezes the preview off short phones.
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
                Slider(value: $overlayScale, in: 0.7...1.3)
                    .accessibilityLabel("Overlay size")
                    .accessibilityValue("\(Int(overlayScale * 100)) percent")
                mediaMenu {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 32)
                        .background(Capsule().fill(Theme.surface)
                            .overlay(Capsule().stroke(Theme.hairline)))
                }
            }
            .frame(height: 44)
        }
    }

    private func mediaMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            PhotosPicker("Photo or video from library", selection: $pickerItem,
                         matching: .any(of: [.images, .videos]))
            if CameraPicker.isAvailable {
                Button("Take a photo", systemImage: "camera") { showingCamera = true }
            }
            if media != nil {
                if !transform.isIdentity || overlayScale != 1 {
                    Button("Reset crop and size", systemImage: "arrow.counterclockwise") {
                        withAnimation(.smooth(duration: 0.25)) {
                            transform = .identity
                            overlayScale = 1
                        }
                    }
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    withAnimation(.smooth(duration: 0.25)) {
                        media = nil
                        transform = .identity
                        overlayScale = 1
                    }
                }
            }
        } label: { label() }
    }

    // MARK: Loading

    private func loadPickedItem() async {
        guard let pickerItem else { return }
        loadingMedia = true
        defer { loadingMedia = false }

        // Video first: a movie also vends Data, so asking for an image would silently succeed on a
        // clip's poster frame and quietly drop the motion the athlete picked.
        if let movie = try? await pickerItem.loadTransferable(type: SharedMovie.self) {
            adopt(.video(movie.url))
        } else if let data = try? await pickerItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) {
            adopt(.image(image))
        }
    }

    /// Adopt new media and reset the crop — a crop framed against the previous picture means nothing
    /// against this one, and inheriting it looks like a bug.
    private func adopt(_ new: ShareMedia) {
        media = new
        transform = .identity
        if style == .classic || style == .paper || style == .sticker { style = .photoTrio }
        Task {
            let aspect = await new.aspect()
            await MainActor.run { mediaAspect = aspect }
        }
    }

    // MARK: Chrome

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
            .background(Capsule().fill(style == s ? Theme.ink : (locked ? Theme.proLavender.opacity(0.16) : Theme.surface))
                .overlay(Capsule().stroke(style == s ? Theme.ink : (locked ? Theme.proLavender.opacity(0.45) : Theme.hairline))))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(style == s ? .isSelected : [])
    }

    // MARK: Share

    @ViewBuilder
    private var shareOrUnlock: some View {
        if styleLocked {
            Button { paywall.present(for: .allShareTemplates) } label: {
                HStack(spacing: 7) {
                    Text("PRO").font(.rounded(10, weight: .heavy)).tracking(1.4)
                        .foregroundStyle(Theme.inkOnFixedLight)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.proLavender))
                    Text("Unlock every style").font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.background)
                }
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
            }
            .buttonStyle(.plain)
        } else if style.usesPhoto, case .video(let url) = media {
            // A clip can't be pre-rendered the way a still can — the export takes seconds and would
            // restart on every crop nudge. Render it on demand, with the button carrying the wait.
            Button {
                Task { await exportVideo(url) }
            } label: {
                shareLabel(title: exportingVideo ? "Preparing video…" : "Share",
                           systemImage: exportingVideo ? nil : "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(exportingVideo)
            .opacity(exportingVideo ? 0.6 : 1)
        } else if let exportImage {
            let image = Image(uiImage: exportImage)
            ShareLink(item: image, preview: SharePreview("momentum", image: image)) {
                shareLabel(title: "Share", systemImage: "square.and.arrow.up")
            }
            .simultaneousGesture(TapGesture().onEnded {
                services.analytics.log(.shareCreated(style: "\(style.rawValue)-\(format.rawValue)"))
            })
        } else {
            // Export still rendering off the body path — hold the button until the image is ready.
            shareLabel(title: "Share", systemImage: "square.and.arrow.up").opacity(0.5)
        }
    }

    private func exportVideo(_ url: URL) async {
        exportingVideo = true
        defer { exportingVideo = false }
        // The overlay only — AVFoundation composites it over the athlete's own frames.
        let overlay = ShareCardRenderer.render(card(size: format.size, mediaHidden: true),
                                               size: format.size, opaque: false)
        do {
            let out = try await ShareVideoExporter.export(videoURL: url, overlay: overlay,
                                                          transform: transform, canvas: format.size)
            services.analytics.log(.shareCreated(style: "\(style.rawValue)-\(format.rawValue)-video"))
            exportedVideo = ExportedVideo(url: out)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func shareLabel(title: String, systemImage: String?) -> some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
            } else {
                ProgressView().tint(Theme.background)
            }
            Text(title)
        }
        .font(.rounded(Theme.FontSize.body, weight: .semibold))
        .frame(maxWidth: .infinity).frame(height: 56)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
        .foregroundStyle(Theme.background)
    }
}

/// A picked movie, copied out of the Photos sandbox into our temp directory — the URL Photos vends
/// is only valid for the duration of the transfer, so exporting from it later fails intermittently.
private struct SharedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("momentum-pick-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return SharedMovie(url: copy)
        }
    }
}

/// `UIActivityViewController` for the video path — `ShareLink` wants its payload up front, and a
/// clip's payload doesn't exist until the export finishes.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
