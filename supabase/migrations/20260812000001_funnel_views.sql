-- Funnel read layer (2026-08-12). `app_events` has been collecting since 2026-07-25 and
-- `paywall_funnel` already answers "of those who saw a paywall, who bought". What was still
-- unanswerable is the question paid acquisition actually turns on: **where do people leave?**
-- Buying installs without that means knowing the cost per install and nothing about why the rest
-- never subscribed.
--
-- These are dashboard views, not client surfaces: every one is revoked from anon/authenticated at
-- the bottom, same as `paywall_funnel`. Read them with the service role in the SQL editor.
--
-- ⚠️ There is no explicit "install" event. The first event of ANY kind for an `install_id` is the
-- proxy for first launch, which is accurate because `AnalyticsService` starts logging immediately.
-- A reinstall legitimately mints a new `install_id`, so these count installs, not humans.

-- 1. WHERE ONBOARDING LEAKS ------------------------------------------------------------------
-- Installs that reached each onboarding step, with the drop from the step before it. The biggest
-- `dropped_from_previous` is the screen to fix.
--
-- ⚠️ GROUPED BY app_version ON PURPOSE. `step` is `OnboardingViewModel.Step.rawValue`, an ordinal
-- that SHIFTS whenever a step is inserted or removed, so step 7 in 1.1 need not be step 7 in
-- 1.2.0. Comparing across versions without this split silently mixes different screens together.
create or replace view public.onboarding_funnel as
with steps as (
  select app_version,
         install_id,
         (params->>'index')::int as step
  from public.app_events
  where name = 'onboarding_step'
    and params->>'index' ~ '^[0-9]+$'   -- ignore anything malformed rather than error the view
),
per_step as (
  select app_version, step, count(distinct install_id) as installs
  from steps
  group by 1, 2
)
select app_version,
       step,
       installs,
       lag(installs) over (partition by app_version order by step) - installs
         as dropped_from_previous,
       round(100.0 * installs
             / nullif(first_value(installs) over (partition by app_version order by step), 0), 1)
         as pct_of_starters
from per_step
order by app_version desc, step;

-- 2. THE WHOLE JOURNEY, ONE ROW -------------------------------------------------------------
-- Install → set up → built a plan → saw the paywall → subscribed → actually trained. The single
-- most useful sanity check before and during a paid campaign: if `subscribed / installs` is much
-- worse for a spend period than it was organically, the traffic is the problem, not the app.
create or replace view public.activation_funnel as
select count(distinct install_id)                                             as installs,
       count(distinct install_id) filter (where name = 'onboarding_step')     as began_setup,
       count(distinct install_id) filter (where name = 'plan_generated')      as built_plan,
       count(distinct install_id) filter (where name = 'paywall_view')        as saw_paywall,
       count(distinct install_id) filter (where name = 'paywall_convert')     as subscribed,
       count(distinct install_id) filter (where name = 'workout_completed')   as logged_a_workout
from public.app_events;

-- 3. DAILY COHORTS — THE ONE TO WATCH WHILE SPENDING ----------------------------------------
-- New installs per day and what became of them. Line this up against daily ad spend to get a real
-- cost per subscriber, which SKAdNetwork's delayed, aggregated reporting will not give you.
-- Note the cohort is keyed on the install's FIRST-EVER day, so a subscriber who converts a week
-- later still counts against the day they arrived — which is what makes payback legible.
create or replace view public.daily_installs as
with per_install as (
  select install_id,
         min(occurred_at)                  as first_at,
         bool_or(name = 'plan_generated')  as built_plan,
         bool_or(name = 'paywall_view')    as saw_paywall,
         bool_or(name = 'paywall_convert') as subscribed
  from public.app_events
  group by install_id
)
select first_at::date                                                              as day,
       count(*)                                                                    as new_installs,
       count(*) filter (where built_plan)                                          as built_plan,
       count(*) filter (where saw_paywall)                                         as saw_paywall,
       count(*) filter (where subscribed)                                          as subscribed,
       round(100.0 * count(*) filter (where subscribed) / nullif(count(*), 0), 1)  as subscribe_pct
from per_install
group by 1
order by 1 desc;

-- Dashboard-only, exactly like paywall_funnel. A view inherits nothing from the base table's RLS
-- for the roles that can read it, so an accidental grant here would hand the (public, shipped)
-- anon key a read path into the whole event stream.
revoke all on public.onboarding_funnel  from anon, authenticated;
revoke all on public.activation_funnel  from anon, authenticated;
revoke all on public.daily_installs     from anon, authenticated;
