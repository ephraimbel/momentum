import Foundation

/// Forwards the non-PII `AnalyticsEvent` stream to Supabase (`public.app_events`, migration
/// 20260725000001) over PostgREST + URLSession — the same no-SDK approach `SyncService` and
/// `AIService` use.
///
/// Offline-first, like everything else that touches the network here: events buffer locally, flush
/// in batches, and a failed flush is harmless — the batch goes back on the queue and rides along
/// with the next one. A no-op until `SupabaseURL` + `SupabaseAnonKey` are set, so an unconfigured
/// build behaves exactly as it always has (log-only).
///
/// **Never put PII in here.** The taxonomy in `AnalyticsEvent.parameters` is the contract: counts,
/// latencies, booleans, and short enum-ish strings. No routes, names, locations, or health values
/// (PRD §13.3). `installID` is a random UUID minted on first launch — not a device identifier.
actor AnalyticsSink {

    /// One queued event. Snake-cased on encode to match the table's columns.
    struct Envelope: Codable, Equatable, Sendable {
        let installID: String
        let name: String
        let params: [String: String]
        let appVersion: String
        let build: String
        let platform: String
        let occurredAt: Date

        private enum CodingKeys: String, CodingKey {
            case installID = "install_id"
            case name
            case params
            case appVersion = "app_version"
            case build
            case platform
            case occurredAt = "occurred_at"
        }
    }

    /// Flush once the queue reaches this many events. Small enough that a funnel shows up while the
    /// athlete is still in the session, large enough that a chatty screen isn't one request per tap.
    static let batchSize = 20

    /// Hard ceiling on the stored queue. A device that is offline for weeks must not grow this
    /// without bound; past the cap the OLDEST events are dropped, because the newest ones are the
    /// ones still describing something we can act on.
    static let maxQueued = 500

    private let defaults: UserDefaults
    private let session: URLSession
    private let installID: String
    private let appVersion: String
    private let build: String
    private let queueKey = "com.momentum.analytics.queue"

    private var queue: [Envelope]
    private var isFlushing = false

    init(defaults: UserDefaults = .standard,
         session: URLSession = .shared,
         bundle: Bundle = .main) {
        self.defaults = defaults
        self.session = session
        self.installID = Self.installID(in: defaults)
        self.appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        self.build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        // Pick up anything a previous run buffered but never got to send.
        self.queue = (try? JSONDecoder().decode([Envelope].self,
                                                from: defaults.data(forKey: queueKey) ?? Data())) ?? []
    }

    /// A stable, random per-install id. Not a device identifier: it is minted here, never leaves
    /// with anything identifying attached, and a reinstall legitimately produces a new one.
    private static func installID(in defaults: UserDefaults) -> String {
        let key = "com.momentum.analytics.installID"
        if let existing = defaults.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }

    /// Buffer an event, and flush once a batch has accumulated.
    func enqueue(name: String, params: [String: String], at date: Date = Date()) async {
        queue.append(Envelope(installID: installID, name: name, params: params,
                              appVersion: appVersion, build: build, platform: "ios",
                              occurredAt: date))
        trimAndPersist()
        if queue.count >= Self.batchSize { await flush() }
    }

    /// Send everything buffered. Called on a full batch, on backgrounding, and at launch for
    /// whatever the last run left behind.
    func flush() async {
        guard Self.egressAllowed else { return }
        guard !isFlushing, !queue.isEmpty, let endpoint, let anonKey else { return }
        isFlushing = true
        defer { isFlushing = false }

        let batch = queue
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            // The user's JWT when signed in, so the table's `user_id default auth.uid()` attributes
            // the row; the anon key alone for guests, which inserts an anonymous row (allowed —
            // most of the funnel happens before sign-in).
            let token = await SupabaseClientProvider.accessToken() ?? anonKey
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Don't ask PostgREST to echo the inserted rows back; we have nothing to do with them.
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(batch)

            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            // 2xx: sent. 4xx: the server will never accept this batch — drop it rather than retry
            // forever and block every later event behind it. 5xx/offline: keep and retry.
            guard (200..<300).contains(http.statusCode) || (400..<500).contains(http.statusCode) else { return }

            queue.removeFirst(min(batch.count, queue.count))
            persist()
        } catch {
            // Offline or transient — the batch stays queued for the next flush.
        }
    }

    /// Drop the oldest events past the cap, then write the queue through so a termination between
    /// flushes doesn't lose it.
    private func trimAndPersist() {
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(queue), forKey: queueKey)
    }

    /// Test seam: how many events are still waiting.
    var queuedCount: Int { queue.count }

    /// Whether this process may send. The unit-test host and the demo/UI-test runs share the
    /// shipping Info.plist — and therefore the real Supabase config — so without this guard a test
    /// sweep or a marketing-screenshot session would write fabricated events straight into the
    /// funnel we're trying to measure. Events still queue in those runs (the buffering contract
    /// stays under test); they just never leave. Mirrors `PaywallController.isRunningUnitTests`.
    private static let egressAllowed: Bool = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        if NSClassFromString("XCTestCase") != nil { return false }
        let args = ProcessInfo.processInfo.arguments
        if args.contains(where: { $0 == "--seed-demo" || $0.hasPrefix("--ui-test") }) { return false }
        #endif
        return true
    }()

    private var endpoint: URL? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String, !base.isEmpty,
              let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("rest/v1/app_events")
    }

    private var anonKey: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
