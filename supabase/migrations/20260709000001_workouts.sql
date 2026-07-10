-- Workouts: the owner-only cloud backup (docs/SYNC-SETUP.md, PRD §8.9).
-- Full (untrimmed) route geometry lives ONLY here, readable by nobody but the owner.
-- The social feed reads the separate, publish-redacted `posts` table instead.

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

-- `(select auth.uid())` runs once per statement (initPlan cache) instead of per row.
create policy "owner can read"   on public.workouts for select using ((select auth.uid()) = user_id);
create policy "owner can write"  on public.workouts for insert with check ((select auth.uid()) = user_id);
create policy "owner can update" on public.workouts for update using ((select auth.uid()) = user_id);
create policy "owner can delete" on public.workouts for delete using ((select auth.uid()) = user_id);
