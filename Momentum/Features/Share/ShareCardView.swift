import SwiftUI

/// Share composer (PRD §7.11): preview the card, pick a size, export. The momentum foil mark in
/// the corner is free distribution. Multiple swipeable style templates are a later enhancement.
struct ShareCardView: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto

    @Environment(\.dismiss) private var dismiss
    @Environment(Services.self) private var services
    @State private var format: ShareFormat = .story

    enum ShareFormat: String, CaseIterable, Identifiable {
        case story = "Story", square = "Square"
        var id: String { rawValue }
        var size: CGSize { self == .story ? CGSize(width: 1080, height: 1920) : CGSize(width: 1080, height: 1080) }
    }

    private var rendered: Image {
        Image(uiImage: ShareCardRenderer.render(
            ShareCardContent(workout: workout, weightUnit: weightUnit,
                             distanceUnit: distanceUnit, size: format.size),
            size: format.size))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.lg) {
                Picker("Format", selection: $format) {
                    ForEach(ShareFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                GeometryReader { geo in
                    let preview = format.size
                    let scale = min(geo.size.width / preview.width, geo.size.height / preview.height)
                    ShareCardContent(workout: workout, weightUnit: weightUnit,
                                     distanceUnit: distanceUnit, size: preview)
                        .scaleEffect(scale)
                        .frame(width: preview.width * scale, height: preview.height * scale)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ShareLink(item: rendered, preview: SharePreview("momentum", image: rendered)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
                        .foregroundStyle(Theme.background)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    services.analytics.log(.shareCreated(style: format.rawValue))
                })
            }
            .padding(Theme.Space.md)
            .background(Theme.background)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
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
