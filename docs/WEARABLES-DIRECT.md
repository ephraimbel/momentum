# Direct wearable connections — Garmin first (2026-07-15)

> Positioning note: this **extends**, not replaces, the 2026-07 decision that HealthKit is the
> single wearable integration. HealthKit stays the universal *read* baseline (Garmin/COROS/Fitbit
> phone apps all write to Apple Health). Direct APIs add what HealthKit can't do:
> **pushing planned structured workouts onto the athlete's watch** (the Runna feature people
> switch for), richer native data, and independence from the user having enabled vendor→Health sync.

## Phasing

| Phase | Scope | Status |
|---|---|---|
| **P0** | Garmin **read**: OAuth connect + activity webhook → staging inbox → in-app import | schema + functions committed (this doc); Swift + approval pending |
| **P1** | Garmin **workout push**: plan engine's structured sessions → Training API → on-watch | after P0 ships |
| **P2** | COROS (same shape: partner API, webhook push, workout push) | after P1 |
| — | Fitbit | not planned — read-only API, mostly non-runners; revisit on demand |

## What exists in the repo (this commit)

| Piece | Path |
|---|---|
| Schema: connections / tokens / OAuth state / staging inbox | `supabase/migrations/20260715000001_vendor_connections.sql` |
| OAuth2+PKCE flow (start + callback) | `supabase/functions/garmin-oauth/index.ts` |
| Activity webhook receiver (staging, idempotent) | `supabase/functions/garmin-webhook/index.ts` |

Both functions deploy with `--no-verify-jwt` (Garmin's redirect/pushes can't carry a Supabase JWT);
`/start` verifies the app's JWT itself, and the webhook authenticates by joining the pushed
`userId` against `vendor_connections` (unknown users are dropped).

## Architecture

```
 Settings "Connect Garmin"
   │  POST /garmin-oauth/start (user JWT)          ← app
   │  → { authorizeUrl }  (state + PKCE persisted)
   ▼
 ASWebAuthenticationSession → Garmin consent
   │  Garmin redirects → GET /garmin-oauth/callback
   │  code→tokens, resolve Garmin userId,
   │  upsert vendor_connections + vendor_tokens
   ▼
 momentum://garmin-connected  (app URL scheme)

 Garmin Push Service ──POST──▶ /garmin-webhook ──▶ vendor_activities (staging, idempotent upsert)
                                                        │
 app foreground ── reads unprocessed rows ─────────────┘
   → runs the SAME overlap dedupe as the HealthKit importer (HealthService.shouldImport +
     overlap window), creates local Workouts (SwiftData = source of truth), marks processed
```

**Trust levels** (why three tables): `vendor_connections` is owner-readable status (no secrets);
`vendor_tokens` has RLS on with **zero policies** — service-role/Edge-Functions only, never
reachable through the client API; `vendor_activities` is a staging inbox the owner reads and
flags processed — the webhook never mutates `workouts` directly, preserving offline-first.

**The dedupe contract (do not break):** a Garmin run typically arrives TWICE — via this webhook
AND via HealthKit (Garmin Connect writes to Apple Health). The physical run must import once.
Client-side import from the staging inbox must reuse the HealthKit importer's overlap dedupe
(match on start time ± tolerance + duration + distance) *and* skip anything whose
`vendor_activity_id` was already imported. Import stays on-device so the rules live in one place.

## Garmin developer application — apply-ready details

Apply at **developerportal.garmin.com** → Garmin Connect Developer Program (the consumer-app
program; free, approval usually 1–3 weeks). Fill with:

| Field | Value |
|---|---|
| App name | momentum |
| Company / developer | Ephraim Belachew (individual) |
| Website | https://momentumrunning.app |
| Privacy policy | https://momentumrunning.app/privacy |
| Terms | https://momentumrunning.app/terms |
| Support | https://momentumrunning.app/support |
| Platform | iOS (App Store; bundle id `com.ephraimbel.momentum.app`) |
| App description | Running-first adaptive training app for iOS. A deterministic plan engine adapts each athlete's week from recovery and training-load signals; momentum imports completed activities to keep the plan honest and (Training API) delivers the plan's structured workouts to the athlete's Garmin watch. |
| APIs requested | **Activity API** (activity-summary push) + **Training API** (workout import to device) — request both up front; re-review for added scopes is slower than one application. Do NOT request the all-day **Health API** (wellness/sleep tier — reported to carry a ~$5k production fee, and we read wellness from Apple Health anyway). |
| Data requested & why | Activity summaries (type, time, duration, distance, HR, elevation) — to log training and adapt the plan. No wellness/sleep via this API (read from Apple Health). |
| Data retention / deletion | Owner-only rows under Postgres RLS; deleting the momentum account cascades all vendor data (`on delete cascade`); disconnecting deletes the connection + tokens. Garmin-side deregistration webhooks are honored (connection marked revoked). |
| Webhook URL (Activity push) | `https://<project-ref>.supabase.co/functions/v1/garmin-webhook` |
| OAuth redirect URI | `https://<project-ref>.supabase.co/functions/v1/garmin-oauth/callback` |

After approval, Garmin issues a **client id + secret** → `supabase secrets set GARMIN_CLIENT_ID=…
GARMIN_CLIENT_SECRET=… APP_REDIRECT_SCHEME=momentum`, and the push/ping endpoints are configured
in their portal (enable **Activities** summaries; leave wellness summaries off).

> Endpoint-constant caveat: the OAuth/token/user-id URLs in `garmin-oauth/index.ts` are Garmin's
> published OAuth2 endpoints; confirm them against the portal docs for the approved app before
> first deploy — Garmin occasionally versions paths.

## Deploy checklist (once approved)

```bash
supabase db push                                        # applies the migration
supabase functions deploy garmin-oauth  --no-verify-jwt
supabase functions deploy garmin-webhook --no-verify-jwt
supabase secrets set GARMIN_CLIENT_ID=… GARMIN_CLIENT_SECRET=… APP_REDIRECT_SCHEME=momentum
```

## Remaining work (P0, Swift side — not yet built)

1. `WearableConnectService` — calls `/start`, opens `ASWebAuthenticationSession`, handles the
   `momentum://garmin-connected` callback; Settings row "Devices → Garmin" with status from
   `vendor_connections` (`last_event_at` → "last synced …", `revoked` → "Reconnect").
2. Staging-inbox importer — on foreground, fetch unprocessed `vendor_activities`, run the shared
   dedupe, create local `Workout`s, mark processed. Reuse `HealthService.shouldImport`-style
   pure filters so it's unit-testable.
3. URL-scheme registration for the OAuth return (project.yml `CFBundleURLTypes`).
4. Token refresh — a scheduled Edge Function (or refresh-on-401 in a future server-side fetch)
   using `vendor_tokens.refresh_token`. P0 can ship without it if pushes keep flowing regardless
   of access-token expiry (webhooks don't need our token; only outbound API calls do).
