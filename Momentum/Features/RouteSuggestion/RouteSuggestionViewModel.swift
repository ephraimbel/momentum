import Foundation
import Observation

/// Drives the "suggest a loop" screen: holds the candidate loops, the selection, and the target
/// distance, and talks to `RouteSuggestionEngine`. The directions provider is injected so previews
/// (and tests) can run without the network.
@MainActor
@Observable
final class RouteSuggestionViewModel {
    let start: GeoPoint
    let distanceUnit: DistanceUnit

    private(set) var candidates: [SuggestedLoop] = []
    private(set) var isLoading = false
    /// True when a search returned nothing (unroutable area) — drives the empty state.
    private(set) var didFail = false
    private(set) var targetM: Double
    var selectedID: SuggestedLoop.ID?

    private let engine: RouteSuggestionEngine
    private var shuffleRound = 0

    init(start: GeoPoint, targetM: Double = 5000, distanceUnit: DistanceUnit = .auto,
         directions: DirectionsProviding = MapKitDirectionsProvider()) {
        self.start = start
        self.targetM = targetM
        self.distanceUnit = distanceUnit
        self.engine = RouteSuggestionEngine(directions: directions)
    }

    var selected: SuggestedLoop? { candidates.first { $0.id == selectedID } }

    func suggest() async {
        await load(seedOffset: 0)
    }

    /// Re-search at the same distance with rotated seeds — a different batch of loops.
    func shuffle() async {
        shuffleRound += 1
        await load(seedOffset: Double(shuffleRound) * 0.7)
    }

    func setDistance(_ meters: Double) async {
        guard meters != targetM else { return }
        targetM = meters
        shuffleRound = 0
        await load(seedOffset: 0)
    }

    private func load(seedOffset: Double) async {
        isLoading = true
        didFail = false
        let loops = await engine.suggestLoops(from: start, targetM: targetM, count: 3, seedOffset: seedOffset)
        candidates = loops
        selectedID = loops.first?.id
        didFail = loops.isEmpty
        isLoading = false
    }
}
