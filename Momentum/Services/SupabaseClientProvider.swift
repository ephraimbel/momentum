import Foundation
import Supabase

/// The one place the app touches the Supabase SDK's client (docs/SOCIAL-BACKEND-SETUP.md).
/// Config-gated like every network seam: `client` is nil until `SupabaseURL`/`SupabaseAnonKey`
/// are injected via Secrets.xcconfig, and the app behaves exactly as it does offline. The SDK
/// persists the auth session in the Keychain and refreshes the JWT automatically — services that
/// need the user's token for RLS'd calls read it through `accessToken()` (never cache it).
enum SupabaseClientProvider {
    static let client: SupabaseClient? = {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
            !urlString.isEmpty, !key.isEmpty,
            let url = URL(string: urlString)
        else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()

    static var isConfigured: Bool { client != nil }

    /// The signed-in user's session JWT, refreshed if stale — nil for guests or when unconfigured.
    /// This is what satisfies owner-only RLS (`user_id = auth.uid()`); the anon key alone can't.
    static func accessToken() async -> String? {
        guard let client else { return nil }
        return try? await client.auth.session.accessToken
    }

}
