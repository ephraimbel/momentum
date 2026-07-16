-- Direct wearable connections (docs/WEARABLES-DIRECT.md) — Garmin first, COROS next.
-- Three tables with three distinct trust levels:
--
--   vendor_connections  owner-visible connection status (no secrets). The app reads this to render
--                       "Garmin · Connected" and deletes a row to disconnect.
--   vendor_tokens       OAuth secrets. RLS enabled with NO policies — reachable ONLY by the
--                       service-role key inside Edge Functions. Never exposed to the client API.
--   vendor_activities   staging inbox for webhook-pushed activities. The webhook (service role)
--                       inserts; the owner's app reads unprocessed rows, runs the SAME overlap
--                       dedupe as the HealthKit importer on-device (SwiftData stays the source of
--                       truth), then marks them processed. Nothing here mutates workouts directly.

create table public.vendor_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  vendor text not null check (vendor in ('garmin', 'coros', 'fitbit')),
  -- The vendor's stable id for this athlete (Garmin: userId from the User Id endpoint / pings).
  -- Webhooks identify users by THIS, so it's the join key back to auth.users.
  vendor_user_id text not null,
  status text not null default 'active' check (status in ('active', 'revoked', 'error')),
  -- What the athlete granted (Garmin: activity export, workout import, …) — display + gating.
  scopes text[] not null default '{}',
  connected_at timestamptz not null default now(),
  last_event_at timestamptz,           -- last webhook received (staleness indicator in Settings)
  unique (user_id, vendor),            -- one connection per vendor per athlete
  unique (vendor, vendor_user_id)      -- a vendor account links to exactly one momentum account
);

create index vendor_connections_lookup on public.vendor_connections (vendor, vendor_user_id);

alter table public.vendor_connections enable row level security;

create policy "owner can read"   on public.vendor_connections for select using ((select auth.uid()) = user_id);
create policy "owner can delete" on public.vendor_connections for delete using ((select auth.uid()) = user_id);
-- No insert/update policies: rows are created/updated only by the OAuth Edge Function (service role).

-- OAuth secrets — service-role only. RLS on + zero policies = invisible to anon/authenticated.
create table public.vendor_tokens (
  connection_id uuid primary key references public.vendor_connections(id) on delete cascade,
  access_token text not null,
  refresh_token text,
  expires_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.vendor_tokens enable row level security;
-- (no policies — deliberately) Belt and braces for a secrets table: revoke the default grants
-- too, so even a future accidental policy can't expose tokens through the client API.
revoke all on public.vendor_tokens from anon, authenticated;

-- Short-lived OAuth state: issued when the app starts a connect flow, consumed by the callback.
-- Ties the browser redirect back to the authenticated athlete without trusting the redirect itself.
create table public.vendor_oauth_states (
  state text primary key,              -- 32-byte random hex, single use
  user_id uuid not null references auth.users(id) on delete cascade,
  vendor text not null check (vendor in ('garmin', 'coros', 'fitbit')),
  code_verifier text not null,         -- PKCE verifier (Garmin OAuth2 requires PKCE)
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes'
);

alter table public.vendor_oauth_states enable row level security;
-- (no policies — service-role only)
revoke all on public.vendor_oauth_states from anon, authenticated;

-- Webhook staging inbox. One row per pushed activity; the unique key makes redelivery idempotent
-- (Garmin retries failed pushes, and a re-sync can replay history).
create table public.vendor_activities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  vendor text not null check (vendor in ('garmin', 'coros', 'fitbit')),
  vendor_activity_id text not null,    -- Garmin: summaryId; COROS: activity id
  activity_type text,                  -- vendor's sport string, normalized client-side
  started_at timestamptz not null,
  duration_s double precision not null default 0,
  distance_m double precision,
  avg_hr int,
  elevation_gain_m double precision,
  summary jsonb not null default '{}', -- full vendor payload for fields we don't model yet
  received_at timestamptz not null default now(),
  processed boolean not null default false,
  unique (vendor, vendor_activity_id)
);

create index vendor_activities_inbox on public.vendor_activities (user_id, processed, started_at desc);

alter table public.vendor_activities enable row level security;

create policy "owner can read"   on public.vendor_activities for select using ((select auth.uid()) = user_id);
-- The app marks rows processed after local import. RLS is row-level, so the column restriction
-- is enforced with column-level grants below: the client may update ONLY `processed`.
create policy "owner can update" on public.vendor_activities for update
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
revoke update on public.vendor_activities from authenticated;
grant update (processed) on public.vendor_activities to authenticated;
-- No insert policy: only the webhook Edge Function (service role) writes activities.
