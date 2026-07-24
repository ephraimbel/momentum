import SwiftUI

/// The human body "getting stronger" — an animated `MuscleMapView` whose muscles ignite one-by-one in
/// earned iridescence (heaviest-worked first). Used in onboarding's muscle-focus step, the building
/// beat, and the reveal. Honors Reduce Motion (everything lights at once, statically).
struct AnatomyGlowView: View {
    /// Target activation (which muscles, relative weight). Muscles with value 0 stay unlit anatomy.
    let activation: [MuscleGroup: Double]
    var sides: [BodySide] = [.front, .back]
    /// nil inherits the athlete's figure from the environment (see `MuscleMapView.sex`).
    var sex: BodySex? = nil
    /// Ignite muscles in sequence (vs. all at once).
    var sequential: Bool = true
    /// Loop the ignite continuously — the "building your plan" beat.
    var loops: Bool = false
    /// Seconds between each muscle lighting up.
    var step: Double = 0.2

    @State private var lit = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ordered: [(muscle: MuscleGroup, value: Double)] {
        activation.filter { $0.value > 0 }.sorted { $0.value > $1.value }
            .map { (muscle: $0.key, value: $0.value) }
    }
    private var shown: [MuscleGroup: Double] {
        Dictionary(uniqueKeysWithValues: ordered.prefix(lit).map { ($0.muscle, $0.value) })
    }
    /// Re-run the ignite whenever the target set changes (e.g. the user toggles a focus muscle).
    private var activationKey: String {
        ordered.map { "\($0.muscle.rawValue):\(Int($0.value * 100))" }.joined(separator: ",")
    }

    var body: some View {
        MuscleMapView(activation: shown, sides: sides, sex: sex)
            .animation(.easeOut(duration: 0.45), value: lit)
            .task(id: activationKey) { await ignite() }
    }

    private func ignite() async {
        let n = ordered.count
        guard n > 0 else { lit = 0; return }
        if reduceMotion || !sequential { lit = n; return }
        repeat {
            withAnimation(.easeOut(duration: 0.3)) { lit = 0 }
            for i in 1...n {
                try? await Task.sleep(for: .seconds(step))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.45)) { lit = i }
            }
            if loops {
                try? await Task.sleep(for: .seconds(1.3))
                if Task.isCancelled { return }
            }
        } while loops && !Task.isCancelled
    }
}
