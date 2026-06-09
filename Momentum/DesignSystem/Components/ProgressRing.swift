import SwiftUI

/// A progress ring that fills from a gray track (empty) to iridescent (complete) — PRD §5.2.
/// The filled arc is the only colored element; the track stays monochrome.
struct ProgressRing: View {
    var progress: Double                 // 0...1
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hairline, lineWidth: lineWidth)
            IridescentView(intensity: 0.95)
                .mask {
                    Circle()
                        .trim(from: 0, to: max(0.0001, min(1, progress)))
                        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
        }
        .animation(Motion.standard, value: progress)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ProgressRing(progress: 0.7).frame(width: 160, height: 160).padding()
    }
}
