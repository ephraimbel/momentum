-- WHERE ARE TRIALISTS CHURNING? — paste into the Supabase SQL editor (project hhhlrqngutmyccfpgdoq).
-- Run each block separately. The onboarding paywall has been HARD since 2026-09-01, so every
-- block is scoped to installs whose first event is on/after that date: the cohort that faced
-- the "pay or trial" wall.
--
-- ⚠️ WHAT THIS CAN AND CANNOT SEE
--   • `paywall_convert` = a purchase/trial went through in-app. It does NOT know cancel/expire/
--     renew — those are RevenueCat (Charts → Trial Conversion, Churn) and App Store Connect
--     (SUBSCRIPTION_EVENT report). This file answers the BEHAVIOUR question: what trialists do,
--     and where they go dark.
--   • The 7-day trial started 2026-09-01 and the 3-day one 2026-09-07: until a cohort has aged
--     past its trial length, "converted to paid" is undefined. Read blocks 1-3 now; block 4
--     becomes meaningful once installs are ≥7 days old.
--   • Same caveat as funnel_dropoff.sql: an install that fired no event is invisible.

-- ================================================================
-- 1. THE DOOR — the hard wall's rejection rate (the test the owner is running)
--    saw_paywall → tapped_anything → converted. Big gap between saw and converted = people
--    are not willing to pay/trial; big gap between saw and tapped = they didn't even try.
-- ================================================================
with per_install as (
  select install_id,
         min(occurred_at)                                              as first_at,
         bool_or(name = 'plan_generated')                              as built_plan,
         bool_or(name = 'paywall_view')                                as saw_paywall,
         bool_or(name = 'paywall_action')                              as tapped_paywall,
         bool_or(name = 'paywall_convert')                             as converted,
         bool_or(name = 'workout_started')                             as started_workout,
         bool_or(name = 'workout_completed')                           as completed_workout
  from public.app_events
  group by install_id
)
select count(*)                                       as installs_with_events,
       count(*) filter (where built_plan)             as built_plan,
       count(*) filter (where saw_paywall)            as saw_paywall,
       count(*) filter (where tapped_paywall)         as tapped_paywall,
       count(*) filter (where converted)              as converted,
       round(100.0 * count(*) filter (where converted)
             / nullif(count(*) filter (where saw_paywall), 0), 1) as pct_of_viewers_converted,
       count(*) filter (where converted and started_workout)    as trialists_started_workout,
       count(*) filter (where converted and completed_workout)  as trialists_completed_workout
from per_install
where first_at >= date '2026-09-01';

-- ================================================================
-- 2. WHAT NON-CONVERTERS DID AT THE WALL
--    Every paywall tap by installs that never converted: which product they picked, whether
--    they tried Restore, whether the App Store failed them (`purchase_failed` /
--    `store_pricing_unavailable` are separate events; join them in if the counts look odd).
-- ================================================================
with converters as (
  select distinct install_id from public.app_events where name = 'paywall_convert'
),
cohort as (
  select install_id from public.app_events
  group by install_id having min(occurred_at) >= date '2026-09-01'
)
select params->>'placement' as placement,
       params->>'action'    as action,
       params->>'product'   as product,
       count(*)             as taps,
       count(distinct e.install_id) as installs
from public.app_events e
join cohort c using (install_id)
where e.name = 'paywall_action'
  and e.install_id not in (select install_id from converters)
group by 1, 2, 3
order by installs desc, taps desc;

-- ================================================================
-- 3. WHERE TRIALISTS GO DARK  ← THE MONEY QUERY
--    One row per converter: what they did after converting, when they were last seen, and the
--    LAST screen/event before silence. Sort by `hours_since_last_event` desc → the top of the
--    list is who has churned in behaviour (whatever RevenueCat says about their receipt).
--    `activated_24h` = completed a workout within a day of converting: the retention hinge.
-- ================================================================
with conv as (
  select install_id, min(occurred_at) as converted_at,
         min(params->>'product') as product
  from public.app_events
  where name = 'paywall_convert'
  group by install_id
),
after as (
  select c.install_id, c.converted_at, c.product,
         count(*) filter (where e.occurred_at > c.converted_at)                       as events_after,
         count(distinct date_trunc('day', e.occurred_at))
               filter (where e.occurred_at > c.converted_at)                          as days_active_after,
         bool_or(e.name = 'workout_started'   and e.occurred_at > c.converted_at)     as started_workout,
         bool_or(e.name = 'workout_completed' and e.occurred_at > c.converted_at)     as completed_workout,
         bool_or(e.name = 'workout_completed'
                 and e.occurred_at between c.converted_at and c.converted_at + interval '24 hours')
                                                                                      as activated_24h,
         bool_or(e.name = 'ai_read_viewed'    and e.occurred_at > c.converted_at)     as saw_ai_read,
         bool_or(e.name = 'plan_session_adapted')                                     as plan_adapted,
         max(e.occurred_at)                                                           as last_event_at
  from conv c
  join public.app_events e using (install_id)
  group by c.install_id, c.converted_at, c.product
),
last_event as (
  select a.install_id, e.name as last_event_name
  from after a
  join lateral (
    select name from public.app_events x
    where x.install_id = a.install_id order by occurred_at desc limit 1
  ) e on true
)
select a.product,
       a.converted_at::date                                         as converted_on,
       round(extract(epoch from now() - a.converted_at) / 3600)     as hours_in_trial,
       round(extract(epoch from now() - a.last_event_at) / 3600)    as hours_since_last_event,
       a.days_active_after, a.events_after,
       a.started_workout, a.completed_workout, a.activated_24h, a.saw_ai_read, a.plan_adapted,
       l.last_event_name
from after a
join last_event l using (install_id)
where a.converted_at >= date '2026-09-01'
order by hours_since_last_event desc;

-- ================================================================
-- 3b. THE SAME, ROLLED UP: which last-event do dark trialists share?
--     "dark" = no event for 48 h while still inside the trial window (≤7 days since convert).
--     The most common `last_event_name` is the screen the trial dies on.
-- ================================================================
with conv as (
  select install_id, min(occurred_at) as converted_at
  from public.app_events where name = 'paywall_convert' group by install_id
),
last_ev as (
  select c.install_id, c.converted_at, x.name as last_event_name, x.occurred_at as last_event_at
  from conv c
  join lateral (
    select name, occurred_at from public.app_events e
    where e.install_id = c.install_id order by occurred_at desc limit 1
  ) x on true
)
select last_event_name,
       count(*)                                                              as dark_trialists,
       round(avg(extract(epoch from last_event_at - converted_at) / 3600), 1) as avg_hours_from_convert_to_silence
from last_ev
where converted_at >= date '2026-09-01'
  and now() - last_event_at  > interval '48 hours'
  and now() - converted_at  <= interval '7 days'
group by 1
order by dark_trialists desc;

-- ================================================================
-- 4. TRIAL-DAY RETENTION CURVE
--    Of everyone who converted, what share was active on day 0, 1, 2 … 7 after converting.
--    The day the curve drops hardest is the day to put something worth opening the app for.
--    Only trust a day once EVERY converter in the cohort is at least that old (see block 3's
--    hours_in_trial), or the tail is undercounted by the people who haven't reached it yet.
-- ================================================================
with conv as (
  select install_id, min(occurred_at) as converted_at
  from public.app_events where name = 'paywall_convert' group by install_id
),
days as (select generate_series(0, 7) as d),
active as (
  select c.install_id, floor(extract(epoch from e.occurred_at - c.converted_at) / 86400)::int as d
  from conv c join public.app_events e using (install_id)
  where e.occurred_at >= c.converted_at and c.converted_at >= date '2026-09-01'
  group by 1, 2
)
select d.d                                                        as trial_day,
       count(distinct a.install_id)                                as active_trialists,
       (select count(*) from conv where converted_at >= date '2026-09-01') as cohort,
       round(100.0 * count(distinct a.install_id)
             / nullif((select count(*) from conv where converted_at >= date '2026-09-01'), 0), 1)
                                                                  as pct_active,
       -- how many of the cohort are actually old enough to have had this day
       (select count(*) from conv
         where converted_at >= date '2026-09-01'
           and now() - converted_at >= (d.d || ' days')::interval) as eligible
from days d
left join active a on a.d = d.d
group by d.d
order by d.d;
