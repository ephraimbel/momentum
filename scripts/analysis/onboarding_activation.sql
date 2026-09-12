-- Activation v2 release cohort. Read-only; run as the project owner/service role.
-- Rows are recorded installs, not App Store download totals. Only fully elapsed 24h windows
-- enter the funnel. Returning installs that migrate an old draft are not new installs.
-- A client entitlement observation is not proof of a paid renewal. Use subscription_events
-- separately for mature trial conversion, and report identity linkage coverage.
with installs as (
  select install_id, min(occurred_at) as installed_at
  from public.app_events
  where name = 'app_launched' and params->>'first' = 'true'
  group by install_id
), observations as (
  select i.install_id, i.installed_at,
    coalesce(max(a.params->>'onboarding_flow_version') filter (
      where a.params->>'onboarding_flow_version' <> 'legacy_or_unknown'), 'legacy_or_unknown') as flow,
    case when bool_or(a.params->>'store_environment' = 'sandbox') then 'sandbox_or_mixed'
         when bool_or(a.params->>'store_environment' = 'production') then 'production_observed'
         else 'unknown' end as environment,
    min(a.occurred_at) filter (where a.name = 'onboarding_step') as setup_at,
    min(a.occurred_at) filter (where a.name = 'onboarding_milestone' and a.params->>'action' = 'reveal_visible') as reveal_at,
    min(a.occurred_at) filter (where a.name = 'paywall_view' and a.params->>'placement' = 'full_plan') as paywall_at,
    min(a.occurred_at) filter (where a.name = 'paywall_convert') as client_purchase_at,
    min(a.occurred_at) filter (where a.name = 'onboarding_milestone' and a.params->>'action' = 'first_entitled_today') as today_at,
    min(a.occurred_at) filter (where a.name = 'workout_completed') as completed_at,
    bool_or(a.name = 'onboarding_milestone' and a.params->>'action' = 'generation_failed') as generation_failed
  from installs i
  join public.app_events a using (install_id)
  where i.installed_at >= now() - interval '28 days'
    and i.installed_at <= now() - interval '24 hours'
    and a.occurred_at >= i.installed_at and a.occurred_at < i.installed_at + interval '24 hours'
  group by i.install_id, i.installed_at
)
select flow, environment, count(*) as recorded_installs_with_24h,
  count(setup_at) as started_setup, count(reveal_at) as actual_reveal_views,
  count(paywall_at) as checkout_views, count(client_purchase_at) as client_purchase_callbacks,
  count(today_at) as entered_today_entitled, count(completed_at) as completed_workout,
  count(*) filter (where generation_failed) as installs_with_generation_failure,
  round(100.0 * count(today_at) / nullif(count(*), 0), 1) as entitled_today_pct,
  percentile_cont(0.5) within group (order by extract(epoch from (reveal_at - setup_at)))
    filter (where reveal_at >= setup_at) as median_setup_to_reveal_seconds
from observations
-- Legacy has no actual-reveal/Today milestone: those nulls mean uninstrumented, not no activation.
where flow = 'activation_v2'
group by flow, environment
order by flow, environment;
