-- Analytics sink (2026-07-25). The app has carried a complete, privacy-clean event taxonomy since
-- day one (`AnalyticsEvent`, PRD §13.5) that only ever wrote to os.Logger — nothing left the device,
-- so the onboarding funnel and paywall view→convert rate were unmeasurable. This is the sink.
--
-- Write-only from clients, by design: an insert policy for anon + authenticated, and NO select
-- policy at all, so no client (or a leaked anon key) can read anybody's stream back. Read it with
-- the service role from the dashboard.
--
-- Guests must be able to write: most of the funnel — onboarding steps, the first paywall view —
-- happens before sign-in, so gating inserts on auth.uid() would drop exactly the events that matter.
-- `install_id` is a random UUID minted on first launch; it is not a device identifier and carries no
-- PII. `user_id` defaults to auth.uid(), which PostgREST evaluates from the caller's own JWT, so a
-- signed-in athlete's events self-attribute without the client ever sending an id it could forge.

create table if not exists public.app_events (
  id          bigint      generated always as identity primary key,
  install_id  uuid        not null,
  user_id     uuid        default auth.uid() references auth.users(id) on delete set null,
  name        text        not null,
  params      jsonb       not null default '{}'::jsonb,
  app_version text        not null default '',
  build       text        not null default '',
  platform    text        not null default 'ios',
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),

  -- Bounds, not validation: the anon key can write here, so cap what a single row can cost. The
  -- real taxonomy uses short snake_case names and a handful of tiny string dimensions.
  constraint app_events_name_len   check (char_length(name) between 1 and 64),
  constraint app_events_params_len check (pg_column_size(params) < 2048)
);

alter table public.app_events enable row level security;

-- Insert-only. WITH CHECK re-asserts the default: a caller may write an anonymous row, or one
-- attributed to themselves, and nothing else.
drop policy if exists app_events_insert on public.app_events;
create policy app_events_insert on public.app_events
  for insert to anon, authenticated
  with check (user_id is null or user_id = auth.uid());

-- No select/update/delete policy anywhere: RLS denies by default, so clients are write-only.
--
-- Deny-all-then-grant-one, NOT revoke-the-few-I-thought-of. Supabase's default privileges hand
-- anon/authenticated GRANT ALL on new public tables, and revoking only select/update/delete leaves
-- **TRUNCATE** behind — which RLS does not gate at all, because it is a table-level privilege that
-- bypasses row security entirely. Anyone holding the anon key (it ships inside the app binary; it is
-- public by construction) could have emptied this table in one statement.
--
-- Grants and RLS are separate gates and BOTH must pass: the insert policy alone still fails with
-- "permission denied for table app_events" if the role was never granted INSERT.
revoke all on table public.app_events from anon, authenticated;
grant insert on table public.app_events to anon, authenticated;

-- Funnel queries scan by name over a time window; retention/cohorts group by install.
create index if not exists app_events_name_time_idx on public.app_events (name, occurred_at desc);
create index if not exists app_events_install_idx   on public.app_events (install_id, occurred_at);

-- The question this whole table exists to answer: of the installs that saw a paywall, how many
-- bought — split by placement, so a low-converting surface is visible rather than averaged away.
-- Service-role only (see the revoke below); it is a dashboard view, not a client surface.
create or replace view public.paywall_funnel as
with views as (
  select params->>'placement' as placement,
         install_id,
         min(occurred_at)     as first_view
  from public.app_events
  where name = 'paywall_view'
  group by 1, 2
),
converts as (
  select install_id, min(occurred_at) as first_convert
  from public.app_events
  where name = 'paywall_convert'
  group by 1
)
select v.placement,
       count(*)                                                   as viewers,
       count(c.install_id)                                        as converters,
       round(100.0 * count(c.install_id) / nullif(count(*), 0), 1) as convert_pct
from views v
left join converts c
  on c.install_id = v.install_id
 and c.first_convert >= v.first_view
group by v.placement
order by viewers desc;

revoke all on public.paywall_funnel from anon, authenticated;
