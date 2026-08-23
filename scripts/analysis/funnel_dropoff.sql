-- WHERE ARE WE LOSING PEOPLE? — paste into Supabase SQL editor (project hhhlrqngutmyccfpgdoq).
-- Run each block separately. Ads started 2026-08-13, so everything is scoped to that.
-- ⚠️ `installs` here = installs that fired at least ONE event. Anyone who bounced on the
--    welcome screen fires nothing and is invisible. Compare block 1's total to Apple Ads
--    installs for that period: the difference is the door we cannot currently see.

-- ================================================================
-- 1. THE WHOLE JOURNEY, AD ERA ONLY
-- ================================================================
with per_install as (
  select install_id,
         min(occurred_at) as first_at,
         max(app_version) as app_version,
         bool_or(name = 'onboarding_step')                                as began_setup,
         bool_or(name = 'onboarding_step' and (params->>'index')::int >= 20) as reached_building,
         bool_or(name = 'plan_generated')                                 as built_plan,
         -- ERA-AWARE: the rate beat sat at 24 through build 32; removing it slid `account`
         -- from 25 to 24 in build 33+. Key on the row's own `build`, never on app_version.
         bool_or(name = 'onboarding_step' and (params->>'index')::int
                 = case when build ~ '^[0-9]+$' and build::int >= 33 then 24 else 25 end)
                                                                          as reached_account,
         bool_or(name = 'paywall_view')                                   as saw_paywall,
         bool_or(name = 'paywall_convert')                                as subscribed,
         bool_or(name = 'workout_started')                                as started_workout,
         bool_or(name = 'workout_completed')                              as logged_workout
  from public.app_events
  where params->>'index' is null or params->>'index' ~ '^[0-9]+$'
  group by install_id
)
select count(*)                                          as installs_with_events,
       count(*) filter (where began_setup)               as began_setup,
       count(*) filter (where reached_building)          as reached_plan_build,
       count(*) filter (where built_plan)                as built_plan,
       count(*) filter (where reached_account)           as reached_account_beat,
       count(*) filter (where saw_paywall)               as saw_paywall,
       count(*) filter (where subscribed)                as subscribed,
       count(*) filter (where started_workout)           as started_a_workout,
       count(*) filter (where logged_workout)            as logged_a_workout
from per_install
where first_at >= date '2026-08-13';

-- ================================================================
-- 2. THE SCREEN-BY-SCREEN LEAK  ← THE MONEY QUERY
--    Biggest `dropped` = the screen to fix.
--
-- ⚠️ KEYED ON `build`, NOT `app_version`, and the label map is ERA-AWARE. `step` is
--    `OnboardingViewModel.Step.rawValue`, an ordinal that MOVES when a case is added or removed,
--    and one marketing version spans many builds (1.4.0 = builds 28 through 33+). The concrete
--    case: the rateUs beat is removed in build 33, sliding `account` from 25 to 24. Steps 0-23 are
--    identical either side of that line. See migration 20260822000002.
--
--    WHEN THE ENUM CHANGES AGAIN: add a new era below. NEVER renumber a map in place — every
--    historical cohort would silently re-label.
-- ================================================================
with eras(min_build, max_build, step, screen) as (values
  -- shared prefix, both eras (steps 0-23 are byte-identical)
  (0,9999,0,'name'),(0,9999,1,'identity/@handle'),(0,9999,2,'goal'),(0,9999,3,'disciplines'),
  (0,9999,4,'experience+pace'),(0,9999,5,'injuries'),(0,9999,6,'metrics(height/weight/sex/age)'),
  (0,9999,7,'race'),(0,9999,8,'race goal time'),(0,9999,9,'muscle focus'),(0,9999,10,'run volume'),
  (0,9999,11,'days per week'),(0,9999,12,'preferred days'),(0,9999,13,'session length'),
  (0,9999,14,'equipment'),(0,9999,15,'strength split'),(0,9999,16,'hybrid focus'),(0,9999,17,'why'),
  (0,9999,18,'HEALTHKIT consent'),(0,9999,19,'intensity'),(0,9999,20,'building…'),
  (0,9999,21,'PLAN REVEAL'),(0,9999,22,'NOTIFICATIONS consent'),(0,9999,23,'primers/location'),
  -- era A — builds <= 32: the rateUs beat exists
  (0,32,24,'RATE US'),(0,32,25,'account'),
  -- era B — builds >= 33: rateUs removed 2026-08-22, account slides up
  (33,9999,24,'account')
),
recent as (
  select build,
         nullif(regexp_replace(build, '\D', '', 'g'), '')::int as build_n,
         install_id,
         (params->>'index')::int as step
  from public.app_events
  where name = 'onboarding_step'
    and params->>'index' ~ '^[0-9]+$'
    and occurred_at >= date '2026-08-13'
),
per_step as (
  select build, max(build_n) as build_n, step, count(distinct install_id) as reached
  from recent group by build, step
)
select p.build,
       p.step,
       coalesce(e.screen, '(unknown — enum changed, add an era above)') as screen,
       p.reached,
       lag(p.reached) over (partition by p.build order by p.step) - p.reached as dropped,
       round(100.0 * p.reached
             / nullif(first_value(p.reached) over (partition by p.build order by p.step),0),1)
         as pct_of_starters
from per_step p
left join eras e
  on e.step = p.step
 and coalesce(p.build_n, 0) between e.min_build and e.max_build
order by p.build_n desc nulls last, p.step;

-- ================================================================
-- 3. DAILY COHORTS vs AD SPEND
-- ================================================================
select * from public.daily_installs where day >= date '2026-08-13';

-- ================================================================
-- 4. DID THE PAYWALL EVEN LOAD? which placement, and does it convert
-- ================================================================
select params->>'placement' as placement,
       count(distinct install_id) as installs_seeing_it
from public.app_events
where name = 'paywall_view' and occurred_at >= date '2026-08-13'
group by 1 order by 2 desc;

-- ================================================================
-- 5. IS THE APP BREAKING? crashes/hangs + sync failures in the ad era
-- ================================================================
select name, params, count(*) as n, count(distinct install_id) as installs
from public.app_events
where name in ('app_diagnostics','sync_failed','store_quarantined','app_performance')
  and occurred_at >= date '2026-08-13'
group by 1,2 order by n desc limit 40;

-- ================================================================
-- 6. HOW MANY EVER CAME BACK? (retention = the real conversion driver
--    on a soft paywall, since the free app IS the trial)
-- ================================================================
with days as (
  select install_id, count(distinct occurred_at::date) as active_days,
         min(occurred_at)::date as first_day, max(occurred_at)::date as last_day
  from public.app_events group by 1
)
select active_days, count(*) as installs
from days where first_day >= date '2026-08-13'
group by 1 order by 1;
