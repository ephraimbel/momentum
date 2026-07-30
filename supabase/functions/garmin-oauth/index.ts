// Supabase Edge Function: garmin-oauth (docs/WEARABLES-DIRECT.md)
//
// The two legs of the Garmin Connect OAuth2 + PKCE flow:
//
//   POST /garmin-oauth/start      (app, with user JWT)  → { authorizeUrl }
//        Generates state + PKCE verifier, persists them, returns the Garmin consent URL
//        for the app to open in ASWebAuthenticationSession.
//
//   GET  /garmin-oauth/callback   (browser redirect from Garmin; no JWT)
//        Validates state, exchanges code for tokens, resolves the Garmin userId, upserts
//        vendor_connections + vendor_tokens, then redirects to the app's URL scheme.
//
// Deploy:  supabase functions deploy garmin-oauth --no-verify-jwt
//          (the callback arrives from Garmin's redirect — it can't carry a Supabase JWT;
//           /start does its own JWT verification below instead.)
// Secrets: supabase secrets set GARMIN_CLIENT_ID=... GARMIN_CLIENT_SECRET=... \
//            APP_REDIRECT_SCHEME=momentum   # momentum://garmin-connected
//
// Endpoint constants below are Garmin's published OAuth2/PKCE endpoints (Connect Developer
// Program, 2024+ apps are OAuth2-only). Confirm against the developer portal docs for the
// approved app before first deploy — they occasionally version the paths.

import { createClient } from "npm:@supabase/supabase-js@2";

const GARMIN_AUTHORIZE_URL = "https://connect.garmin.com/oauth2Confirm";
const GARMIN_TOKEN_URL = "https://diauth.garmin.com/di-oauth2-service/oauth/token";
const GARMIN_USER_ID_URL = "https://apis.garmin.com/wellness-api/rest/user/id";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, // service role: writes tokens, bypasses RLS
);

const CLIENT_ID = Deno.env.get("GARMIN_CLIENT_ID") ?? "";
const CLIENT_SECRET = Deno.env.get("GARMIN_CLIENT_SECRET") ?? "";
const APP_SCHEME = Deno.env.get("APP_REDIRECT_SCHEME") ?? "momentum";

// --- PKCE helpers -------------------------------------------------------------------------

function randomHex(bytes: number): string {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256base64url(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

// --- Routes -------------------------------------------------------------------------------

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const leg = url.pathname.split("/").pop(); // "start" | "callback"

  try {
    if (req.method === "POST" && leg === "start") return await start(req);
    if (req.method === "GET" && leg === "callback") return await callback(url);
    return json({ error: "not found" }, 404);
  } catch (e) {
    console.error("[garmin-oauth]", e);
    return json({ error: "internal" }, 500);
  }
});

/// App calls this with its Supabase JWT; we verify it ourselves (function deploys with
/// --no-verify-jwt because the callback leg must be public).
async function start(req: Request): Promise<Response> {
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: { user }, error } = await supabase.auth.getUser(jwt);
  if (error || !user) return json({ error: "unauthorized" }, 401);

  const state = randomHex(32);
  const verifier = randomHex(32);
  const challenge = await sha256base64url(verifier);

  const { error: insertErr } = await supabase.from("vendor_oauth_states").insert({
    state, user_id: user.id, vendor: "garmin", code_verifier: verifier,
  });
  if (insertErr) return json({ error: "state persist failed" }, 500);

  const redirectUri = `${Deno.env.get("SUPABASE_URL")}/functions/v1/garmin-oauth/callback`;
  const authorize = new URL(GARMIN_AUTHORIZE_URL);
  authorize.searchParams.set("response_type", "code");
  authorize.searchParams.set("client_id", CLIENT_ID);
  authorize.searchParams.set("code_challenge", challenge);
  authorize.searchParams.set("code_challenge_method", "S256");
  authorize.searchParams.set("state", state);
  authorize.searchParams.set("redirect_uri", redirectUri);

  return json({ authorizeUrl: authorize.toString() });
}

/// Garmin redirects the athlete's browser here after consent.
async function callback(url: URL): Promise<Response> {
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  if (!code || !state) return appRedirect("error", "missing code/state");

  // Single-use state: fetch + delete atomically-enough (delete first loses nothing but a retry).
  const { data: st } = await supabase.from("vendor_oauth_states")
    .select("user_id, code_verifier, expires_at").eq("state", state).single();
  await supabase.from("vendor_oauth_states").delete().eq("state", state);
  if (!st || new Date(st.expires_at) < new Date()) return appRedirect("error", "state expired");

  // Exchange the code.
  const redirectUri = `${Deno.env.get("SUPABASE_URL")}/functions/v1/garmin-oauth/callback`;
  const tokenRes = await fetch(GARMIN_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      code,
      code_verifier: st.code_verifier,
      redirect_uri: redirectUri,
    }),
  });
  if (!tokenRes.ok) {
    console.error("[garmin-oauth] token exchange", tokenRes.status, await tokenRes.text());
    return appRedirect("error", "token exchange failed");
  }
  const tokens = await tokenRes.json(); // { access_token, refresh_token, expires_in, ... }

  // Resolve Garmin's stable userId — the key webhooks identify athletes by.
  const idRes = await fetch(GARMIN_USER_ID_URL, {
    headers: { Authorization: `Bearer ${tokens.access_token}` },
  });
  if (!idRes.ok) return appRedirect("error", "user id fetch failed");
  const { userId } = await idRes.json();

  // Upsert connection + tokens (reconnecting replaces the old grant).
  const { data: conn, error: connErr } = await supabase.from("vendor_connections")
    .upsert({
      user_id: st.user_id, vendor: "garmin", vendor_user_id: String(userId),
      status: "active", connected_at: new Date().toISOString(),
    }, { onConflict: "user_id,vendor" })
    .select("id").single();
  if (connErr || !conn) {
    console.error("[garmin-oauth] connection upsert", connErr);
    return appRedirect("error", "connection save failed");
  }
  await supabase.from("vendor_tokens").upsert({
    connection_id: conn.id,
    access_token: tokens.access_token,
    refresh_token: tokens.refresh_token ?? null,
    expires_at: tokens.expires_in
      ? new Date(Date.now() + tokens.expires_in * 1000).toISOString()
      : null,
    updated_at: new Date().toISOString(),
  });

  return appRedirect("connected");
}

// --- Small helpers ------------------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/// Bounce the browser back into the app; Settings listens for momentum://garmin-{connected|error}.
function appRedirect(result: string, reason?: string): Response {
  const target = new URL(`${APP_SCHEME}://garmin-${result}`);
  if (reason) target.searchParams.set("reason", reason);
  return Response.redirect(target.toString(), 302);
}
