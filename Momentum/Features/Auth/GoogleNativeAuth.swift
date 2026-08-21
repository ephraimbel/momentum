import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Native Google OAuth (2026-08-20). The sign-in sheet talks to accounts.google.com directly —
/// authorization-code + PKCE via `ASWebAuthenticationSession`, no Google SDK (third-party-dep
/// rules) — and hands back an ID token that `AuthController` bridges to a Supabase session with
/// `signInWithIdToken`, exactly like the Apple path. This replaces the Supabase web-sheet flow,
/// whose iOS permission dialog named the project's `*.supabase.co` domain; the dialog now says
/// "google.com".
///
/// The iOS OAuth client lives in the owner's "momentum app" Google Cloud project; its ID ships in
/// Info.plist (`GoogleIOSClientID` — client IDs are public by design). Supabase's Google provider
/// lists it as an accepted audience, so GoTrue trusts the token. The nonce goes to Google RAW and
/// to Supabase RAW — Google echoes it into the ID token verbatim, so GoTrue's equality check holds
/// (no Apple-style hash dance; only Apple's API forces that).
@MainActor
final class GoogleNativeAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Tokens {
        let idToken: String
        let accessToken: String?
        let rawNonce: String
    }

    enum AuthError: Error {
        case notConfigured
        case badCallback
        case tokenExchangeFailed
    }

    /// nil/empty → the seam is dark and `AuthController.signInWithGoogle` fails soft, same as
    /// every other unconfigured network seam.
    static var clientID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GoogleIOSClientID") as? String,
              !id.isEmpty else { return nil }
        return id
    }

    /// Must outlive `start()` — ASWebAuthenticationSession is not retained by the system.
    private var activeSession: ASWebAuthenticationSession?

    /// Run the full dance: consent sheet → authorization code → token exchange. Throws on
    /// cancel/offline/unconfigured; the caller maps any throw to a soft "gate stays put".
    func signIn() async throws -> Tokens {
        guard let clientID = Self.clientID else { throw AuthError.notConfigured }
        // Google's custom-scheme convention: the client ID with its dot-components reversed.
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        let redirectURI = "\(scheme):/oauth2redirect"

        let verifier = Self.randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let rawNonce = Self.randomURLSafeString()

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "nonce", value: rawNonce),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = self
            activeSession = session
            session.start()
        }
        activeSession = nil

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else { throw AuthError.badCallback }

        return try await exchange(code: code, clientID: clientID, redirectURI: redirectURI,
                                  verifier: verifier, rawNonce: rawNonce)
    }

    /// Authorization code → tokens, straight against Google's token endpoint. iOS OAuth clients
    /// have no client secret — PKCE's verifier is the proof.
    private func exchange(code: String, clientID: String, redirectURI: String,
                          verifier: String, rawNonce: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AuthError.tokenExchangeFailed }

        struct TokenResponse: Decodable {
            let idToken: String
            let accessToken: String?
            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case accessToken = "access_token"
            }
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(idToken: tokens.idToken, accessToken: tokens.accessToken, rawNonce: rawNonce)
    }

    /// CSPRNG base64url string (43 chars from 32 bytes — inside PKCE's 43–128 verifier bounds).
    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
