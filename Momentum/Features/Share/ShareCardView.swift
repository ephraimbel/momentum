import SwiftUI
import SwiftData
import PhotosUI
import Photos
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
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    /// This week's running reading for the Week template — computed once per workout, off the
    /// body (it fetches the week's other workouts). nil = no honest target, the card copes.
    @State private var weekReading: WeekRing.Reading?
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
    /// The template grid's second axis (2026-08-25). `--share-voice=clean|pills|line` in DEBUG.
    @State private var voice: ShareStatVoice = {
        #if DEBUG
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--share-voice=") }),
           let match = ShareStatVoice.allCases.first(where: {
               $0.rawValue.lowercased() == String(arg.dropFirst("--share-voice=".count)).lowercased()
           }) { return match }
        #endif
        return .grotesk
    }()
    @State private var showingTemplates = ProcessInfo.processInfo.arguments.contains("--share-templates")
    /// The editor's own state (2026-08-27, the Aura editor grammar): words, ink, layers. Composer
    /// only — never written back to the workout. `--share-edits` in DEBUG stages a styled card.
    @State private var edits: ShareEdits = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--share-edits") {
            var e = ShareEdits(); e.title = "Evening Run"; e.subtitle = "Austin, TX"; e.ink = .white; return e
        }
        #endif
        return ShareEdits()
    }()
    @State private var editingText = false
    @State private var saved = false
    @State private var saveError: String?

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
    /// "Copy" flips to "Copied" for a beat — the composer is a sheet, so the app toast would
    /// play underneath it.
    @State private var copied = false

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
        card(size: size, style: style, voice: voice, mediaHidden: mediaHidden)
    }

    /// Any (composition, voice) pair on the current media — the composer preview, the export, and
    /// every tile in the template grid go through here.
    @ViewBuilder
    private func card(size: CGSize, style: ShareStyle, voice: ShareStatVoice, mediaHidden: Bool = false) -> some View {
        switch style {
        case .classic:
            ShareCardContent(workout: workout, weightUnit: weightUnit,
                             distanceUnit: distanceUnit, size: size)
        case .photoTrio:
            PhotoTrioCard(workout: workout, stats: stats, media: media, size: size,
                          transform: transform, mediaAspect: mediaAspect,
                          overlayScale: overlayScale, mediaHidden: mediaHidden, voice: voice, edits: edits)
        case .photoStack:
            PhotoStackCard(workout: workout, stats: stats, media: media, size: size,
                           transform: transform, mediaAspect: mediaAspect,
                           overlayScale: overlayScale, mediaHidden: mediaHidden, voice: voice, edits: edits)
        case .photoMinimal:
            PhotoMinimalCard(workout: workout, stats: stats, media: media, size: size,
                             transform: transform, mediaAspect: mediaAspect,
                             overlayScale: overlayScale, mediaHidden: mediaHidden, voice: voice, edits: edits)
        case .photoBig:
            PhotoBigCard(workout: workout, stats: stats, media: media, size: size,
                         transform: transform, mediaAspect: mediaAspect,
                         overlayScale: overlayScale, mediaHidden: mediaHidden, edits: edits)
        case .paper:
            PaperCard(workout: workout, stats: stats, size: size, voice: voice, edits: edits)
        case .splits:
            SplitsCard(workout: workout, stats: stats, size: size, distanceUnit: distanceUnit, edits: edits)
        case .week:
            WeekCard(workout: workout, stats: stats, size: size, distanceUnit: distanceUnit, reading: weekReading, edits: edits)
        case .ticket:
            TicketCard(workout: workout, stats: stats, size: size, edits: edits)
        case .sticker:
            StickerCard(workout: workout, stats: stats, size: size, voice: voice, edits: edits)
        case .bubble:      BubbleSticker(workout: workout, stats: stats, size: size, edits: edits)
        case .verified:    VerifiedSticker(workout: workout, stats: stats, size: size, edits: edits)
        case .heart:       HeartSticker(workout: workout, stats: stats, size: size, edits: edits)
        case .highlighter: HighlighterSticker(workout: workout, stats: stats, size: size, edits: edits)
        case .sentence:    SentenceSticker(workout: workout, stats: stats, size: size, edits: edits)
        case .serifLine:   SerifLineSticker(workout: workout, stats: stats, size: size, edits: edits)
        case .dateStack:   DateStackSticker(workout: workout, stats: stats, size: size, edits: edits)
        case .condensed:   CondensedSticker(workout: workout, stats: stats, size: size, edits: edits)
        }
    }

    /// Re-render the export only when something the card actually draws changes.
    private struct ExportKey: Equatable {
        let style: ShareStyle
        let voice: ShareStatVoice
        let format: ShareFormat
        let media: ShareMedia?
        let transform: MediaTransform
        let overlayScale: CGFloat
        let edits: ShareEdits
    }
    private var exportKey: ExportKey {
        ExportKey(style: style, voice: voice, format: format,
                  media: style.usesPhoto ? media : nil,
                  transform: transform, overlayScale: overlayScale, edits: edits)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.md) {
                preview
                controls
            }
            .padding(Theme.Space.md)
            .background(Theme.background)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            // The composer is always a SHEET, and it opens from places that are themselves already
            // presented — the save editors inside the recorder overlay, a history detail. Nothing
            // underneath can raise a cover above this sheet, so the Pro-styles gate hosts its own
            // paywall here. Registered, so the host beneath stands down while this one is up.
            .nestedPaywallHost()
            .sheet(isPresented: $showingTemplates) { templatesSheet }
            .sheet(isPresented: $editingText) { textSheet }
            .alert("Couldn't save", isPresented: Binding(get: { saveError != nil },
                                                        set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
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
            .task(id: workout.id) {
                let profile = profiles.first
                weekReading = WeekRingReader.reading(for: workout, plan: profile?.plan, profile: profile, in: context)
            }
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
                                                       opaque: !style.isSticker)
            }
        }
        // The media room (2026-08-25): the composer is dark in both schemes — the athlete's photo
        // is the light source and every control is glass on charcoal. An environment override,
        // never `preferredColorScheme` on a modal (that leaks to the presenter).
        .environment(\.colorScheme, .dark)
    }

    // MARK: Templates — composition × voice as one grid of live tiles (the Aura sheet), replacing
    // the horizontal chip row (vertical-only rule, 2026-08-20).

    private var templatesPill: some View {
        Button { showingTemplates = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.system(size: 14, weight: .semibold))
                Text("Templates")
                Text("·").foregroundStyle(Theme.inkTertiary)
                Text(style.carriesVoice ? "\(style.rawValue) · \(voice.rawValue)" : style.rawValue).foregroundStyle(Theme.inkSecondary)
                Spacer()
                if styleLocked {
                    Text("PRO").font(.rounded(10, weight: .heavy)).tracking(1.4)
                        .foregroundStyle(Theme.inkOnFixedLight)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.proLavender))
                }
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .font(.rounded(Theme.FontSize.body, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.md)
            .frame(maxWidth: .infinity).frame(height: 48)
            .momentumGlass()
            .contentShape(Capsule())
        }
        .buttonStyle(PressableScaleStyle(scale: 0.98))
        .accessibilityLabel("Templates, \(style.rawValue)")
    }

    /// The library, three shelves (Aura's "Create" stat blocks + "Copy" stickers, plus our own
    /// opaque cards): every tile is its own design. The voice is a MODIFIER row above, not a
    /// second axis in the grid — it only reaches the templates that carry a stat block.
    private var templatesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    voiceRow
                    ForEach(ShareStyle.Family.allCases, id: \.self) { family in
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Text(family.rawValue.uppercased())
                                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                                .foregroundStyle(Theme.inkTertiary)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm),
                                                GridItem(.flexible(), spacing: Theme.Space.sm)],
                                      spacing: Theme.Space.sm) {
                                ForEach(ShareStyle.allCases.filter { $0.family == family }) { templateTile($0) }
                            }
                        }
                    }
                }
                .padding(Theme.Space.md)
            }
            .background(Theme.background)
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingTemplates = false } } }
        }
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Aura keeps a global "Aa" in its library header; ours is the voice — how the numbers speak
    /// on every template that has a stat block. Wraps, never scrolls sideways.
    private var voiceRow: some View {
        FlowLayout(spacing: Theme.Space.sm) {
            ForEach(ShareStatVoice.allCases) { v in
                Button {
                    withAnimation(.smooth(duration: 0.2)) { voice = v }
                    Haptics.selection()
                } label: {
                    Text(v.rawValue)
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(voice == v ? Theme.background : Theme.ink)
                        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.chipV + 1)
                        .background(Capsule().fill(voice == v ? Theme.ink : Theme.surface))
                        .overlay(Capsule().stroke(voice == v ? Theme.ink : Theme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(voice == v ? .isSelected : [])
            }
        }
    }

    private func templateTile(_ key: ShareStyle) -> some View {
        let locked = key.requiresPro && !paywall.isEntitled(to: .allShareTemplates)
        let selected = key == style
        let canvas = format.size
        return Button {
            withAnimation(.smooth(duration: 0.25)) { style = key }
            Haptics.selection()
            showingTemplates = false
        } label: {
            GeometryReader { geo in
                let scale = geo.size.width / canvas.width
                // Centre-anchored like the preview: scaleEffect leaves the LAYOUT at canvas size,
                // so the outer frame must centre on it — a top-leading anchor drew every tile
                // off its own bounds.
                card(size: canvas, style: key, voice: voice)
                    .background { if key.isSticker { stickerBackdrop } }
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: canvas.height * scale)
                    .clipped()
                    .allowsHitTesting(false)
            }
            .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(selected ? Theme.purple : Theme.hairline, lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(key.rawValue)
                        .font(.rounded(Theme.FontSize.label, weight: .bold))
                        .foregroundStyle(.white)
                    if locked {
                        Text("PRO").font(.rounded(9, weight: .heavy)).tracking(1.2)
                            .foregroundStyle(Theme.inkOnFixedLight)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.proLavender))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(Theme.Space.sm)
            }
        }
        .buttonStyle(PressableScaleStyle(scale: 0.97))
        .accessibilityLabel("\(key.rawValue)\(locked ? ", Pro" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Everything under the preview, split out of `body` so the type-checker has one expression
    /// per stack instead of one for the whole sheet (it timed out once the rail and Save landed).
    @ViewBuilder
    private var controls: some View {
        if style.usesPhoto { mediaControls }
        templatesPill
        Picker("Format", selection: $format) {
            ForEach(ShareFormat.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        if !styleLocked { quickActions }
        shareOrUnlock
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let canvas = format.size
            let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            card(size: canvas)
                .background { if style.isSticker { stickerBackdrop } }
                .scaleEffect(scale)
                .frame(width: canvas.width * scale, height: canvas.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                // Composer-only edge — the light Paper card otherwise melts into the sheet.
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
                .overlay(alignment: .top) { if editingMedia { cropHint } }
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .gesture(editingMedia ? cropGesture(previewScale: scale) : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The tool rail — Aura's pen · Aa · color · layers, minus the pen — sits in the
                // gutter BESIDE the card, not on it: Aura floats theirs over empty sky, but a
                // Story card carries stats down its right edge and a rail on top of them hid the
                // very row the athlete was judging (seen on Sticker). Dark glass so it still
                // reads as media-room chrome. Classic has nothing to edit, so no rail.
                .overlay(alignment: .trailing) { if style != .classic { toolRail } }
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
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
                        .raised(Capsule())
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
        if !style.usesPhoto { style = .photoTrio }
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

    // MARK: Copy (2026-08-25) — the card onto the clipboard, in-app only: the rendered card (a
    // transparent PNG for Sticker) is two taps from any story, in any app. No external hooks.

    // MARK: Tool rail — Aa · ink · layers (the Aura editor, in our theme)

    private var toolRail: some View {
        VStack(spacing: Theme.Space.sm) {
            Button { editingText = true } label: { railButton("textformat") }
                .accessibilityLabel("Edit text")
            Button {
                withAnimation(.smooth(duration: 0.2)) { edits.ink = edits.ink.next }
                Haptics.selection()
            } label: {
                ZStack {
                    railButton("circle.fill", tint: edits.ink.color)
                    Circle().stroke(.white.opacity(0.9), lineWidth: 1.5).frame(width: 16, height: 16)
                }
            }
            .accessibilityLabel("Text color, \(edits.ink.label)")
            .accessibilityHint("Cycles white, ink, lavender")
            Menu {
                Toggle("Title", isOn: $edits.showTitle)
                Toggle("Route", isOn: $edits.showRoute)
                Toggle("Stats", isOn: $edits.showStats)
                Toggle("Wordmark", isOn: $edits.showWordmark)
                Divider()
                Button("Reset edits", systemImage: "arrow.counterclockwise") {
                    withAnimation(.smooth(duration: 0.25)) { edits = ShareEdits() }
                }
            } label: { railButton("square.3.layers.3d") }
            .accessibilityLabel("Layers")
        }
        .padding(.trailing, Theme.Space.xs)
        .buttonStyle(PressableScaleStyle(scale: 0.94))
    }

    private func railButton(_ systemImage: String, tint: Color? = nil) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint ?? .white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(.black.opacity(0.42)))
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            .contentShape(Circle())
    }

    /// Title + subtitle, prefilled with what the card is already showing so the athlete edits
    /// rather than composes. Half-sheet: the card stays visible above it.
    private var textSheet: some View {
        NavigationStack {
            Form {
                Section("Headline") {
                    TextField(edits.resolvedTitle(for: workout), text: $edits.title)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                }
                Section("Small line") {
                    TextField(edits.resolvedSubtitle(for: workout), text: $edits.subtitle)
                        .font(.rounded(Theme.FontSize.body, weight: .medium))
                }
            }
            .navigationTitle("Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editingText = false } } }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var isVideoCard: Bool {
        if style.usesPhoto, case .video = media { return true }
        return false
    }

    /// Save to Photos — Aura's SAVE, our Copy's twin. A still saves at once; a clip exports first.
    private func saveToPhotos() {
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveError = "Allow photo access in Settings to save cards."
                return
            }
            do {
                if isVideoCard, case .video(let url) = media {
                    exportingVideo = true
                    defer { exportingVideo = false }
                    let overlay = ShareCardRenderer.render(card(size: format.size, mediaHidden: true),
                                                           size: format.size, opaque: false)
                    let out = try await ShareVideoExporter.export(videoURL: url, overlay: overlay,
                                                                  transform: transform, canvas: format.size)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: out)
                    }
                } else if let exportImage {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: exportImage)
                    }
                } else { return }
                Haptics.success()
                services.analytics.log(.shareCreated(style: "\(style.rawValue)-\(format.rawValue)-save"))
                withAnimation(.easeOut(duration: 0.15)) { saved = true }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.2)) { saved = false }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        if exportImage != nil || isVideoCard {
            HStack(spacing: Theme.Space.sm) {
                copyPill
                Button { saveToPhotos() } label: {
                    HStack(spacing: 7) {
                        if exportingVideo {
                            ProgressView().tint(Theme.ink).controlSize(.small)
                        } else {
                            Image(systemName: saved ? "checkmark" : "arrow.down.to.line").font(.system(size: 14, weight: .semibold))
                        }
                        Text(saved ? "Saved" : "Save")
                    }
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .momentumGlass()
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableScaleStyle(scale: 0.97))
                .disabled(exportingVideo)
                .accessibilityLabel(saved ? "Saved to Photos" : "Save to Photos")
            }
        }
    }

    @ViewBuilder
    private var copyPill: some View {
        if let exportImage {
            Button {
                UIPasteboard.general.setData(exportImage.pngData() ?? Data(), forPasteboardType: "public.png")
                Haptics.success()
                services.analytics.log(.shareCreated(style: "\(style.rawValue)-\(format.rawValue)-copy"))
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(.easeOut(duration: 0.2)) { copied = false }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 14, weight: .semibold))
                    Text(copied ? "Copied" : "Copy")
                }
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity).frame(height: 48)
                .momentumGlass()
                .contentShape(Capsule())
            }
            .buttonStyle(PressableScaleStyle(scale: 0.97))
            .accessibilityLabel(copied ? "Copied to clipboard" : "Copy to clipboard")
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
