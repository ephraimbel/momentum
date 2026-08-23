-- The door (2026-08-22). `onboarding_funnel` starts at the first ONBOARDING question, so it has
-- always been blind to the screen before it: the welcome. Worse, `installs` everywhere was defined
-- as "install_id with at least one event", and the first event an install could fire was
-- `onboarding_step` — so an athlete who tapped an ad, installed, opened the app, looked at the
-- welcome film and left fired NOTHING. They were not a drop-off. They were not even an install.
-- That is the exact shape of a cold paid click, which made paid acquisition unreadable.
--
-- Two events close it (app build 33+): `app_launched` (params.first = 'true' on the very first
-- launch of an install — the TRUE install denominator) and `welcome_action`
-- (get_started | resume | have_account | auto_resume — what they did at the gate).
--
-- ⚠️ ERA SPLIT. Installs from builds before 33 fire neither event. Every view below is therefore
-- scoped to installs that fired `app_launched` at all; mixing eras would read as a catastrophic
-- welcome-bounce rate that is really just old clients. Compare cohorts, never lifetime totals.

-- 1. THE DOOR ---------------------------------------------------------------------------------
-- Launched → saw the gate and acted → answered question one. The gap between `first_launches` and
-- `acted_at_gate` is the leak that was invisible; the gap between `acted_at_gate` and
-- `began_onboarding` is a handoff bug if it is anything but ~zero.
create or replace view public.door_funnel as
with per_install as (
  select install_id,
         min(occurred_at)::date as cohort_day,
         max(app_version)       as app_version,
         bool_or(name = 'app_launched' and params->>'first' = 'true')     as first_launch,
         bool_or(name = 'welcome_action')                                 as acted_at_gate,
         bool_or(name = 'welcome_action' and params->>'action'
                 in ('get_started','resume'))                             as chose_to_start,
         bool_or(name = 'welcome_action' and params->>'action' = 'have_account')
                                                                          as chose_sign_in,
         bool_or(name = 'onboarding_step')                                as began_onboarding,
         bool_or(name = 'plan_generated')                                 as built_plan,
         bool_or(name = 'paywall_view')                                   as saw_paywall,
         bool_or(name = 'paywall_convert')                                as subscribed
  from public.app_events
  group by install_id
  having bool_or(name = 'app_launched')   -- instrumented era only
)
select cohort_day,
       app_version,
       count(*) filter (where first_launch)                     as first_launches,
       count(*) filter (where acted_at_gate)                    as acted_at_gate,
       count(*) filter (where chose_to_start)                   as chose_to_start,
       count(*) filter (where chose_sign_in)                    as chose_sign_in,
       count(*) filter (where began_onboarding)                 as began_onboarding,
       count(*) filter (where built_plan)                       as built_plan,
       count(*) filter (where saw_paywall)                      as saw_paywall,
       count(*) filter (where subscribed)                       as subscribed,
       -- The number this whole migration exists to produce.
       count(*) filter (where first_launch and not acted_at_gate)  as bounced_at_welcome,
       round(100.0 * count(*) filter (where first_launch and not acted_at_gate)
             / nullif(count(*) filter (where first_launch), 0), 1) as welcome_bounce_pct
from per_install
group by 1, 2
order by 1 desc, 2 desc;

-- 2. RETURNS ----------------------------------------------------------------------------------
-- `app_launched` also, for free, makes retention readable: cold launches per install over time.
-- On a soft paywall the free app IS the trial, so "did they ever come back" predicts conversion
-- far better than anything inside onboarding does.
create or replace view public.launch_retention as
with per_install as (
  select install_id,
         min(occurred_at)::date                     as cohort_day,
         count(*) filter (where name = 'app_launched')   as launches,
         count(distinct occurred_at::date)          as active_days,
         max(occurred_at)::date - min(occurred_at)::date as days_span
  from public.app_events
  group by install_id
  having bool_or(name = 'app_launched')
)
select cohort_day,
       count(*)                                        as installs,
       count(*) filter (where launches >= 2)           as returned_at_least_once,
       count(*) filter (where active_days >= 2)        as active_on_2plus_days,
       count(*) filter (where days_span >= 7)          as still_around_after_a_week,
       round(avg(launches), 1)                         as avg_launches
from per_install
group by 1 order by 1 desc;

revoke all on public.door_funnel      from anon, authenticated;
revoke all on public.launch_retention from anon, authenticated;
