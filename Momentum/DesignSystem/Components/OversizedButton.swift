import SwiftUI

/// The single oversized control used for primary actions (start / stop / finish / log) — PRD §5.5.
/// Press: scale → 0.97 with a light haptic (§6.2). Honors disabled.
struct OversizedButton: View {
    /// `.glass` is `.outline` for controls that float over LIVE MEDIA — a map, a photo. Outline
    /// fills with `Color.clear`, so whatever is behind reads straight through the button: over the
    /// live-run map, Mapbox POI labels ran through the word "Pause" and made it unreadable (audit
    /// 2026-08-22). Glass blurs what's behind instead, using the same treatment every other
    /// floating control in the app already uses. On a solid background the two look near-identical,
    /// so only the map-floating call sites were switched.
    enum Kind { case filled, outline, glass }

    let title: String
    var systemImage: String? = nil
    var kind: Kind = .filled
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: Theme.Space.sm) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.rounded(Theme.FontSize.body, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(kind == .filled ? Theme.background : Theme.ink)
            .background { backdrop }
        }
        .buttonStyle(PressableScaleStyle())
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.card) }

    @ViewBuilder private var backdrop: some View {
        switch kind {
        case .filled:
            shape.fill(Theme.ink)
        case .outline:
            shape.fill(Color.clear).overlay { shape.stroke(Theme.ink, lineWidth: 1.5) }
        case .glass:
            shape.fill(Color.clear)
                .momentumGlass(in: shape)
                .overlay { shape.stroke(Theme.ink, lineWidth: 1.5) }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        OversizedButton(title: "Start", systemImage: "play.fill") {}
        OversizedButton(title: "Finish", kind: .outline) {}
    }.padding()
}
