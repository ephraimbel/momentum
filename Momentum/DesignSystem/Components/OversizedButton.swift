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
            Haptics.medium()   // the primary action has weight (glass pass 2026-08-27)
            action()
        } label: {
            HStack(spacing: Theme.Space.sm) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.rounded(Theme.FontSize.body + 1, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .foregroundStyle(kind == .filled ? .white : Theme.ink)
            .modifier(Backdrop(kind: kind))
            .contentShape(Capsule())
        }
        .buttonStyle(RaisedPressStyle())
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
    }

    /// Capsules, all three (the pill law): filled = the raised ink capsule; outline and glass keep
    /// their see-through / blurred grounds for the map-floating sites, with an ink hairline.
    private struct Backdrop: ViewModifier {
        let kind: Kind
        func body(content: Content) -> some View {
            switch kind {
            case .filled:
                content.raised(Capsule(), tone: .ink)
            case .outline:
                content.background(Capsule().fill(Color.clear))
                    .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1.5))
            case .glass:
                content.background(Capsule().fill(Color.clear).momentumGlass(in: Capsule()))
                    .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1.5))
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        OversizedButton(title: "Start", systemImage: "play.fill") {}
        OversizedButton(title: "Finish", kind: .outline) {}
    }.padding()
}
