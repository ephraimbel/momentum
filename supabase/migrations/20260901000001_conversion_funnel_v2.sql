-- Conversion funnel v2 (build 37+).
--
-- Build 37 stops treating an enum raw value as a linear onboarding path. Every onboarding event
-- now carries a stable step name plus its actual one-based position and total for that athlete's
-- branched flow. Checkout also reports the decisions between a paywall view and a conversion.
-- These views intentionally count DISTINCT installs so retries, relaunches, and duplicate client
-- events cannot inflate the funnel.

create or replace view public.onboarding_funnel_v2 as
with valid_steps as (
  select build,
         app_version,
         install_id,
         params->>'step'                         as step_name,
         (params->>'position')::int              as position,
         (params->>'total')::int                 as total
  from public.app_events
  where name = 'onboarding_step'
    and coalesce(params->>'step', '') <> ''
    and params->>'position' ~ '^[0-9]+$'
    and params->>'total' ~ '^[0-9]+$'
),
per_step as (
  select build,
         max(app_version)                        as app_version,
         position,
         step_name,
         min(total)                              as min_path_steps,
         max(total)                              as max_path_steps,
         count(distinct install_id)              as installs
  from valid_steps
  group by build, position, step_name
),
starters as (
  select build, count(distinct install_id) as installs
  from valid_steps
  group by build
)
select p.build,
       p.app_version,
       p.position,
       p.step_name,
       p.min_path_steps,
       p.max_path_steps,
       p.installs,
       round(100.0 * p.installs / nullif(s.installs, 0), 1) as pct_of_onboarding_starters
from per_step p
join starters s using (build)
order by nullif(regexp_replace(p.build, '\D', '', 'g'), '')::int desc nulls last,
         p.position,
         p.step_name;

create or replace view public.conversion_funnel_by_build as
with per_install as (
  select build,
         max(app_version) as app_version,
         install_id,
         bool_or(name = 'app_launched' and params->>'first' = 'true') as installed,
         bool_or(name = 'welcome_action')                              as welcome_acted,
         bool_or(name = 'onboarding_step')                             as onboarding_started,
         bool_or(name = 'plan_generated')                              as plan_generated,
         bool_or(name = 'onboarding_showcase' and params->>'action' = 'viewed')
                                                                       as showcase_viewed,
         bool_or(name = 'onboarding_showcase' and params->>'action' = 'continued')
                                                                       as showcase_continued,
         bool_or(name = 'paywall_view')                                as paywall_viewed,
         bool_or(name = 'paywall_action' and params->>'action' = 'purchase_attempt')
                                                                       as purchase_attempted,
         bool_or(name = 'paywall_convert')                             as subscribed
  from public.app_events
  group by build, install_id
  having bool_or(name = 'app_launched' and params->>'first' = 'true')
),
counts as (
  select build,
         max(app_version) as app_version,
         count(*) filter (where installed)            as installs,
         count(*) filter (where welcome_acted)        as welcome_acted,
         count(*) filter (where onboarding_started)   as onboarding_started,
         count(*) filter (where plan_generated)       as plans_generated,
         count(*) filter (where showcase_viewed)      as showcase_viewers,
         count(*) filter (where showcase_continued)   as showcase_continuers,
         count(*) filter (where paywall_viewed)       as paywall_viewers,
         count(*) filter (where purchase_attempted)   as purchase_attempts,
         count(*) filter (where subscribed)           as subscribers
  from per_install
  group by build
)
select *,
       round(100.0 * plans_generated / nullif(installs, 0), 1)              as install_to_plan_pct,
       round(100.0 * showcase_viewers / nullif(plans_generated, 0), 1)      as plan_to_showcase_pct,
       round(100.0 * showcase_continuers / nullif(showcase_viewers, 0), 1)  as showcase_continue_pct,
       round(100.0 * paywall_viewers / nullif(showcase_continuers, 0), 1)   as showcase_to_paywall_pct,
       round(100.0 * purchase_attempts / nullif(paywall_viewers, 0), 1)     as paywall_to_attempt_pct,
       round(100.0 * subscribers / nullif(purchase_attempts, 0), 1)         as attempt_to_paid_pct,
       round(100.0 * subscribers / nullif(installs, 0), 1)                  as install_to_paid_pct
from counts
order by nullif(regexp_replace(build, '\D', '', 'g'), '')::int desc nulls last;

create or replace view public.paywall_diagnostics as
with normalized as (
  select build,
         app_version,
         install_id,
         case
           when name = 'paywall_view' then 'viewed'
           when name = 'paywall_convert' then 'converted'
           else params->>'action'
         end as action,
         coalesce(params->>'placement', 'unknown') as placement,
         coalesce(params->>'product', 'unknown')   as product,
         params->>'pricing_live'                   as pricing_live
  from public.app_events
  where name in ('paywall_view', 'paywall_action', 'paywall_convert')
)
select build,
       max(app_version)              as app_version,
       placement,
       action,
       product,
       pricing_live,
       count(*)                      as events,
       count(distinct install_id)    as installs
from normalized
group by build, placement, action, product, pricing_live
order by nullif(regexp_replace(build, '\D', '', 'g'), '')::int desc nulls last,
         placement, action, product;

create or replace view public.onboarding_permission_outcomes as
select build,
       max(app_version)                    as app_version,
       params->>'kind'                     as permission,
       params->>'status'                   as status,
       count(*)                            as responses,
       count(distinct install_id)          as installs
from public.app_events
where name = 'onboarding_permission'
  and params->>'kind' in ('notifications', 'location')
  and params->>'status' in ('granted', 'denied', 'skipped')
group by build, params->>'kind', params->>'status'
order by nullif(regexp_replace(build, '\D', '', 'g'), '')::int desc nulls last,
         permission, status;

-- Dashboard-only. The public anon key may insert into app_events but must never read event data or
-- aggregates derived from it.
revoke all on public.onboarding_funnel_v2       from anon, authenticated;
revoke all on public.conversion_funnel_by_build from anon, authenticated;
revoke all on public.paywall_diagnostics        from anon, authenticated;
revoke all on public.onboarding_permission_outcomes from anon, authenticated;
