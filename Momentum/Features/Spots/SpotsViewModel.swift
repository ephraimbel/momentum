import Foundation
import Observation

/// Drives "Spots near you" (PRD §6): fetch real running/hiking spots near the athlete once, then rank
/// and filter them locally. The provider + popularity source are injected (same seam as the route
/// suggester), so previews/tests run without the network. Changing the Run/Hike filter never refetches
/// — it re-ranks the spots already in hand, so it's instant and costs nothing.
@MainActor
@Observable
final class SpotsViewModel {
    /// Explicit states so the View renders loading / results / "nothing nearby" deterministically.
    enum State: Equatable {
        case idle, loading, loaded([Spot]), empty
    }

    private(set) var state: State = .idle
    private(set) var activity: SpotActivity?       // nil == "All"
    var selectedID: Spot.ID?

    let origin: GeoPoint
    private let provider: any SpotsProviding
    private let popularitySource: any SpotPopularitySource
    private let onLoaded: ((Int) -> Void)?
    private let onSelected: ((SpotKind) -> Void)?

    /// All kinds; the activity filter narrows them at rank time.
    private let kinds = SpotKind.allCases
    private let perKind = 8

    private var rawSpots: [Spot] = []
    private var popularity: [String: SpotPopularity] = [:]

    init(origin: GeoPoint,
         provider: any SpotsProviding,
         popularitySource: any SpotPopularitySource = NoSpotPopularity(),
         activity: SpotActivity? = nil,
         onLoaded: ((Int) -> Void)? = nil,
         onSelected: ((SpotKind) -> Void)? = nil) {
        self.origin = origin
        self.provider = provider
        self.popularitySource = popularitySource
        self.activity = activity
        self.onLoaded = onLoaded
        self.onSelected = onSelected
    }

    var spots: [Spot] { if case .loaded(let s) = state { return s } else { return [] } }
    var selected: Spot? { spots.first { $0.id == selectedID } }

    /// Fetch once (idempotent while loading / already loaded). The caching provider makes a reopen free.
    func load() async {
        switch state {
        case .loading, .loaded: return
        case .idle, .empty: break
        }
        state = .loading
        let raw = await provider.nearbySpots(around: origin, kinds: kinds, limitPerKind: perKind)
        rawSpots = raw
        popularity = await popularitySource.popularity(for: raw)
        rerank()
        onLoaded?(spots.count)
    }

    /// Pull-to-retry from the empty state (bypasses the "already loaded" guard).
    func reload() async {
        state = .idle
        await load()
    }

    func setActivity(_ activity: SpotActivity?) {
        guard activity != self.activity else { return }
        self.activity = activity
        rerank()
    }

    func select(_ spot: Spot) {
        selectedID = spot.id
        onSelected?(spot.kind)
    }

    private func rerank() {
        let ranked = SpotRanker.rank(rawSpots, from: origin, activity: activity, popularity: popularity)
        state = ranked.isEmpty ? .empty : .loaded(ranked)
        if !ranked.contains(where: { $0.id == selectedID }) { selectedID = ranked.first?.id }
    }
}
