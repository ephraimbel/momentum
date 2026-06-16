import Foundation

/// Ephemeral "live now" presence for the globe (docs/SOCIAL-LAYER.md, Slice 4). Opt-in and fuzzed:
/// when the athlete has "Appear on the map" on, a short-TTL, coarse-cell heartbeat is published, and
/// the current live-now count is returned. Real multi-user presence needs **Supabase Realtime** — so
/// this is config-gated and returns 0 until the backend is configured (like sync/AI). No fabricated
/// live counts.
@MainActor
protocol PresenceServing: AnyObject {
    /// Publish our presence (when opted in) and return the current live-now count. 0 when offline.
    func refresh(appearOnMap: Bool) async -> Int
}

/// No-op presence for previews/tests — always 0 (honest: no live data without a backend).
@MainActor
final class StubPresenceService: PresenceServing {
    func refresh(appearOnMap: Bool) async -> Int { 0 }
}

/// Config-gated live presence. When Supabase is configured it will publish a fuzzed heartbeat and read
/// the live-now count via Realtime; until then it returns 0 so the globe never shows a fabricated
/// crowd. The wiring point exists so production lights up by setting the Info.plist keys.
@MainActor
final class LivePresenceService: PresenceServing {
    func refresh(appearOnMap: Bool) async -> Int {
        guard AIService.isServerConfigured else { return 0 }   // shares the Supabase config gate
        // TODO(Supabase Realtime): upsert a TTL'd fuzzed-cell heartbeat when `appearOnMap`, then read
        // the live-now count. Returns 0 until the presence channel is deployed (docs/SOCIAL-LAYER.md).
        return 0
    }
}
