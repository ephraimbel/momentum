# Cloud sync setup — activating Supabase

> **Superseded (2026-07-09, Slice 6):** setup now lives in
> [SOCIAL-BACKEND-SETUP.md](SOCIAL-BACKEND-SETUP.md) — auth (Sign in with Apple → JWT) is wired,
> the SQL below moved into versioned migrations (`supabase/migrations/`, applied with
> `supabase db push`), and the config keys inject from `Secrets.xcconfig`. This file remains as
> the reference for the sync *contract* (what `SyncEngine` uploads and why).

Phase 4 ships the **sync foundation**: a deterministic, tested upload contract (`SyncEngine`) and a
PostgREST push (`SyncService`) over URLSession — the same no-SDK approach `AIService`/`CoachChatService`
already use for Edge Functions. It's a **no-op until configured**, so the app builds/tests without it.

> Why it can't be fully verified in the build sandbox: it needs a live Supabase project, the schema +
> RLS deployed, and an authenticated user (JWT) — none exist in CI. Everything below is the one-time
> activation. **No SPM dependency is required** (we talk to PostgREST directly).

## What syncs (the contract — `SyncEngine`, unit-tested)
- **Dirty = never-synced** (`Workout.syncedAt == nil`). After a successful push it's stamped, so it's
  sent once. (An edit should clear `syncedAt` to re-sync — a small hook to add when edit-sync lands.)
- **Raw `LocationSample` logs stay on-device.** Only the route **geometry** (`[[lat, lon]]`) uploads.
- **Route geometry uploads only when the workout isn't private** (§8.9). Private → no geometry leaves.
- The workout row carries scalars (type, dates, duration, calories, effort, title/note, distance,
  pace, elevation) + a strength summary (volume, sets).

## 1. Supabase project
- Create a project; copy the **Project URL** and the **anon public key**.

## 2. Schema + owner-only RLS (§27)
Run in the SQL editor (snake_case columns match the encoder's `convertToSnakeCase`):

```sql
create table public.workouts (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  type text not null,
  started_at timestamptz not null,
  duration_s double precision not null default 0,
  calories double precision,
  perceived_effort int,
  title text default '',
  note text default '',
  privacy text not null default 'private',
  distance_m double precision,
  avg_pace_s_per_km double precision,
  elevation_gain_m double precision,
  total_volume_kg double precision,
  total_sets int,
  route jsonb,                          -- [[lat,lon]] geometry; null when private
  updated_at timestamptz not null default now()
);

create index workouts_user_started on public.workouts (user_id, started_at desc);

alter table public.workouts enable row level security;
create policy "owner can read"   on public.workouts for select using (auth.uid() = user_id);
create policy "owner can write"  on public.workouts for insert with check (auth.uid() = user_id);
create policy "owner can update" on public.workouts for update using (auth.uid() = user_id);
```

`user_id` defaults to `auth.uid()`, so an authenticated insert is auto-scoped to the owner; the
upsert (`Prefer: resolution=merge-duplicates`) is keyed on `id`.

## 3. Auth (the remaining piece)
Owner RLS requires the **user's session JWT** — the anon key alone fails `auth.uid() = user_id`.
Wire **Supabase Auth via Sign in with Apple** (the `applesignin` entitlement is already present),
then send the session's `access_token` as the `Authorization: Bearer` header in `SyncService`
(replace the anon-key placeholder marked `TODO(Sync auth)`).

## 4. Configure + verify
1. Set Info.plist keys (prefer xcconfig/CI secrets over literals):
   ```
   SupabaseURL: "https://xxxx.supabase.co"
   SupabaseAnonKey: "<anon key>"
   ```
2. Run the app, finish a **public** workout → confirm a row appears in `public.workouts` with a
   `route`; finish a **private** workout → row present but `route` is null.
3. Confirm a second account can't read the first's rows (RLS).

## Already done (no action)
- `SyncEngine` (dirty selection + privacy/raw-log filtering) — unit-tested.
- `SyncService` (PostgREST upsert, config-gated, marks rows synced) wired to run on Today's appear.
- Next layer: bidirectional merge (last-write-wins scalars, never overwrite sets/sample logs) +
  child tables for full set/split rows.
