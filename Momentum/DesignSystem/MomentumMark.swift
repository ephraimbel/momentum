import SwiftUI

/// The momentum mark — an angular "M" read as two upward peaks (the app icon, §5.2). Drawn as a
/// thick rounded stroke so it can be filled with iridescence (the earned brand accent) or solid
/// ink. Reused on the cold open, empty states, the building/reveal beats, and share cards.
struct MShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        path.move(to: pt(0.07, 0.90))     // bottom-left foot
        path.addLine(to: pt(0.30, 0.12))  // tall left peak
        path.addLine(to: pt(0.52, 0.58))  // middle valley
        path.addLine(to: pt(0.73, 0.22))  // shorter right peak
        path.addLine(to: pt(0.93, 0.90))  // bottom-right foot
        return path
    }
}

struct MomentumMark: View {
    var iridescent: Bool = true
    /// Stroke thickness as a fraction of the mark's size.
    var lineWidthRatio: CGFloat = 0.16

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = StrokeStyle(lineWidth: side * lineWidthRatio, lineCap: .round, lineJoin: .round)
            ZStack {
                if iridescent {
                    IridescentView(intensity: 0.95)
                        .mask { MShape().stroke(style: stroke) }
                } else {
                    MShape().stroke(style: stroke).foregroundStyle(Theme.ink)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 24) {
            MomentumMark().frame(width: 120, height: 120)
            MomentumMark(iridescent: false).frame(width: 60, height: 60)
        }
    }
}
