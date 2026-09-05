-- WHERE ARE PEOPLE FALLING OFF — is it the paywall, or before it?
-- Paste into the Supabase SQL editor (project hhhlrqngutmyccfpgdoq). Run each block, paste results back.
--
-- WHY THIS FILE EXISTS ALONGSIDE funnel_dropoff.sql: that one is keyed on onboarding step INDEX
-- (pre-build-37). This one leads with the two questions the owner actually asked — how many reach
-- the wall, and what they do once they are on it — and it reads the views that migration
-- 20260901000001 already applied to the live DB.
--
-- ⚠️ BUILD REALITY AT TIME OF WRITING (2026-09-03): build 37 is committed but NOT shipped.
--    - `onboarding_funnel_v2` needs the build-37 named-step params → expect it EMPTY. Skip it.
--    - `conversion_funnel_by_build` needs `app_launched` → builds 33+ only.
--    - `paywall_diagnostics` works on every build that ever showed a wall.
--    Judge nothing from lifetime totals: DEBUG builds never egress, but TestFlight sandbox
--    purchases DO count as `subscribed`. Compare builds, and treat tiny builds as noise.

-- ================================================================
-- BLOCK 1 — THE WHOLE FUNNEL, PER BUILD  ← answers the question directly
-- Read the pct columns right to left: if `showcase_to_paywall_pct` is high and
-- `paywall_to_attempt_pct` is low, they ARE reaching the wall and bouncing on price.
-- If `install_to_plan_pct` is low, they never got near the wall and the paywall is innocent.
-- ================================================================
select build, app_version,
       installs, welcome_acted, onboarding_started, plans_generated,
       showcase_viewers, showcase_continuers, paywall_viewers,
       purchase_attempts, subscribers,
       install_to_plan_pct, plan_to_showcase_pct, showcase_continue_pct,
       showcase_to_paywall_pct, paywall_to_attempt_pct, attempt_to_paid_pct,
       install_to_paid_pct
from public.conversion_funnel_by_build
order by nullif(regexp_replace(build, '\D', '', 'g'), '')::int desc nulls last;

-- ================================================================
-- BLOCK 2 — ON THE WALL ITSELF  ← the "are they just falling off at the paywall" answer
-- `viewed` vs `purchase_attempt` = how many even tapped the button.
-- `purchase_cancelled` = they opened the Apple sheet and backed out (price/trust).
-- `purchase_failed` / `pricing_failed` = OUR bug or a store outage, not a decision.
-- `closed` = dismissed a contextual wall. `plan_selected` = they engaged with the cards.
-- ================================================================
select build, app_version, placement, action, product, pricing_live, events, installs
from public.paywall_diagnostics
order by nullif(regexp_replace(build, '\D', '', 'g'), '')::int desc nulls last,
         placement, action;

-- ================================================================
-- BLOCK 2b — the same thing collapsed to one line per build (easiest to read)
-- ================================================================
with per_install as (
  select build, install_id,
         bool_or(name = 'paywall_view')                                        as viewed,
         bool_or(name = 'paywall_action' and params->>'action' = 'plan_selected')   as touched_cards,
         bool_or(name = 'paywall_action' and params->>'action' = 'purchase_attempt') as attempted,
         bool_or(name = 'paywall_action' and params->>'action' = 'purchase_cancelled') as cancelled,
         bool_or(name = 'paywall_action' and params->>'action' in ('purchase_failed','pricing_failed')) as errored,
         bool_or(name = 'paywall_convert')                                      as paid
  from public.app_events
  where name in ('paywall_view', 'paywall_action', 'paywall_convert')
  group by build, install_id
)
select build,
       count(*) filter (where viewed)                          as saw_wall,
       count(*) filter (where touched_cards)                   as touched_a_plan_card,
       count(*) filter (where attempted)                       as tapped_buy,
       count(*) filter (where cancelled)                       as cancelled_in_apple_sheet,
       count(*) filter (where errored)                         as store_errors,
       count(*) filter (where paid)                            as paid,
       count(*) filter (where viewed and not attempted)        as bounced_without_tapping,
       round(100.0 * count(*) filter (where viewed and not attempted)
             / nullif(count(*) filter (where viewed), 0), 1)   as bounce_pct
from per_install
group by build
order by nullif(regexp_replace(build, '\D', '', 'g'), '')::int desc nulls last;

-- ================================================================
-- BLOCK 3 — WHERE THEY DIE BEFORE THE WALL (screen by screen, build 33-36 era)
-- Steps are enum ORDINALS in these builds. Biggest `dropped` = the screen to fix.
-- Era map: builds <= 32 have RATE US at 24 and account at 25; builds >= 33 have account at 24.
-- ================================================================
with labels(min_build, max_build, step, screen) as (values
  (0,9999,0,'name'),(0,9999,1,'identity/@handle'),(0,9999,2,'goal'),(0,9999,3,'disciplines'),
  (0,9999,4,'experience+pace'),(0,9999,5,'injuries'),(0,9999,6,'metrics'),(0,9999,7,'race'),
  (0,9999,8,'race goal time'),(0,9999,9,'muscle focus'),(0,9999,10,'run volume'),
  (0,9999,11,'days per week'),(0,9999,12,'preferred days'),(0,9999,13,'session length'),
  (0,9999,14,'equipment'),(0,9999,15,'strength split'),(0,9999,16,'hybrid focus'),(0,9999,17,'why'),
  (0,9999,18,'HEALTHKIT consent'),(0,9999,19,'intensity'),(0,9999,20,'building…'),
  (0,9999,21,'PLAN REVEAL'),(0,9999,22,'NOTIFICATIONS consent'),(0,9999,23,'primers/location'),
  (0,32,24,'RATE US'),(0,32,25,'account'),
  (33,9999,24,'account')
),
steps as (
  select build,
         nullif(regexp_replace(build, '\D', '', 'g'), '')::int as build_n,
         install_id,
         (params->>'index')::int as step
  from public.app_events
  where name = 'onboarding_step' and params->>'index' ~ '^[0-9]+$'
),
per_step as (
  select build, max(build_n) as build_n, step, count(distinct install_id) as reached
  from steps group by build, step
)
select p.build, p.step, l.screen, p.reached,
       lag(p.reached) over (partition by p.build order by p.step) - p.reached as dropped
from per_step p
left join labels l
  on l.step = p.step and p.build_n between l.min_build and l.max_build
where p.build_n >= 33
order by p.build_n desc, p.step;

-- ================================================================
-- BLOCK 4 — DAILY, so a mid-campaign change is visible as a cliff
-- (the annual trial was retired 2026-08-20 and returned 2026-09-01)
-- ================================================================
select date_trunc('day', occurred_at)::date            as day,
       count(distinct install_id) filter (where name = 'app_launched' and params->>'first' = 'true') as installs,
       count(distinct install_id) filter (where name = 'paywall_view')    as saw_wall,
       count(distinct install_id) filter (where name = 'paywall_convert') as paid
from public.app_events
group by 1
order by 1 desc
limit 30;
