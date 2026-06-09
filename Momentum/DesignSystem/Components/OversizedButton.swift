import SwiftUI

/// The single oversized control used for primary actions (start / stop / finish / log) — PRD §5.5.
/// Press: scale → 0.97 with a light haptic (§6.2). Honors disabled.
struct OversizedButton: View {
    enum Kind { case filled, outline }

    let title: String
    var systemImage: String? = nil
    var kind: Kind = .filled
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var pressed = false

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
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(kind == .filled ? Theme.ink : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .stroke(Theme.ink, lineWidth: kind == .outline ? 1.5 : 0)
                    }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.97 : 1)
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .animation(Motion.lively, value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

#Preview {
    VStack(spacing: 16) {
        OversizedButton(title: "Start", systemImage: "play.fill") {}
        OversizedButton(title: "Finish", kind: .outline) {}
    }.padding()
}
