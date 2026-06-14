import SwiftUI

/// A self-drawing iridescent trajectory — the onboarding reveal's "sold" payoff (docs/ONBOARDING-
/// MOTION-PLAN §4). It is the *same* pen + comet head as the welcome `RouteDrawMap`, now plotting a
/// line over an axis: the route you saw at "hello" becomes your trajectory at "let's go." The line
/// draws itself with the shared pen curve, a soft iridescent area fills beneath, and a glowing head
/// leads to an endpoint label.
///
/// `values` are real, caller-computed magnitudes (e.g. cumulative planned training hours) — this view
/// only *renders* them, it never fabricates numbers. Honors Reduce Motion (draws instantly).
struct ProjectionCurve: View {
    /// One magnitude per step (≥ 2). Plotted left→right, normalized to the tallest value.
    var values: [Double]
    /// Label pinned at the final point (e.g. "~36h").
    var endpointLabel: String
    /// Caption under the x-axis (e.g. "12 weeks").
    var weeksLabel: String

    @State private var progress = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let pts = densePoints(in: geo.size)
            let shown = min(pts.count, max(2, Int((progress * Double(pts.count)).rounded())))
            let head = pts.isEmpty ? .zero : pts[shown - 1]
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    guard pts.count > 1 else { return }
                    let drawn = Array(pts.prefix(shown))

                    // The trajectory — a clean iridescent line (the earned accent).
                    var line = Path()
                    line.move(to: drawn[0])
                    drawn.dropFirst().forEach { line.addLine(to: $0) }
                    ctx.stroke(line, with: .linearGradient(
                        Gradient(colors: Theme.iridescent),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                    // Solid black head dot — the clean "you are here" marker.
                    let r: CGFloat = 4.5
                    let dot = CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r)
                    ctx.fill(Path(ellipseIn: dot), with: .color(Theme.ink))
                }
                // Endpoint magnitude, pinned to the head.
                Text(endpointLabel)
                    .font(.display(Theme.FontSize.headline, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
                    .position(x: geo.size.width - 28, y: max(14, head.y - 16))
                    .opacity(progress > 0.9 ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: progress > 0.9)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text(weeksLabel)
                .font(.rounded(Theme.FontSize.label, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
        }
        .onAppear {
            guard !reduceMotion else { progress = 1; return }
            // Start after the card has revealed so the draw is clearly seen, then trace at a
            // deliberate pace.
            withAnimation(Motion.pen(1.8).delay(0.55)) { progress = 1 }
        }
        .accessibilityElement()
        .accessibilityLabel("Projected training over \(weeksLabel): \(endpointLabel)")
    }

    /// Project the magnitudes into the canvas, densified by linear interpolation so the pen draws
    /// smoothly rather than jumping point-to-point.
    private func densePoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let maxV = max(values.max() ?? 1, 0.0001)
        let padTop: CGFloat = 16, padBottom: CGFloat = 18, padLeft: CGFloat = 4, padRight: CGFloat = 48
        let plotW = max(1, size.width - padLeft - padRight)
        let plotH = max(1, size.height - padTop - padBottom)
        func point(_ i: Double) -> CGPoint {
            let lo = Int(floor(i)), hi = min(values.count - 1, lo + 1)
            let f = i - Double(lo)
            let v = values[lo] + (values[hi] - values[lo]) * f
            let x = padLeft + plotW * CGFloat(i) / CGFloat(values.count - 1)
            let y = padTop + plotH * CGFloat(1 - v / maxV)
            return CGPoint(x: x, y: y)
        }
        let perSeg = 6
        let total = (values.count - 1) * perSeg
        return (0...total).map { point(Double($0) / Double(perSeg)) }
    }
}

#Preview {
    ZStack {
        Color.white.ignoresSafeArea()
        ProjectionCurve(values: (1...12).map { Double($0) * 3 },
                        endpointLabel: "~36h", weeksLabel: "12 weeks")
            .frame(height: 120)
            .padding()
    }
}
