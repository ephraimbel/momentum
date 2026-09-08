-- Build 44 screen analytics. A session is a foreground visit, not a retention interval.
-- Never equate an observed exit with dissatisfaction, a recovered end with a crash, or seven
-- silent days with permanent churn. Unknown endings remain visible without inventing durations.

-- Deduplicate at-least-once delivery by the install/session/sequence contract. CASE protects
-- casts even if the optimizer changes filter order; digit length also prevents integer overflow.
create or replace view public.analytics_screen_events as
select distinct on (install_id, params->>'session', seq)
       id, install_id, params->>'session' as session_id, params->>'screen' as screen,
       seq, occurred_at, received_at, build
from (
  select *, case when params->>'seq' ~ '^[0-9]{1,9}$'
                 then (params->>'seq')::integer end as seq
  from public.app_events where name = 'screen_view'
) e
where seq > 0 and length(params->>'session') between 8 and 64
  and params->>'screen' ~ '^[a-z][a-z0-9_]{0,63}$'
order by install_id, params->>'session', seq, occurred_at, id;

-- An end recovered on a later launch has a NEW event timestamp. Use the original screens for
-- the visit's date and last observed time, and only clean-background ends for measured duration.
create or replace view public.analytics_screen_sessions as
with screens as (
  select install_id, session_id, min(occurred_at) as started_at,
         max(occurred_at) as last_seen_at, count(*) as views,
         (array_agg(screen order by seq desc, occurred_at desc, id desc))[1] as last_screen
  from public.analytics_screen_events group by 1, 2
), ends as (
  select distinct on (install_id, params->>'session')
         install_id, params->>'session' as session_id, params->>'reason' as reason,
         case when params->>'duration_s' ~ '^[0-9]{1,7}$'
              then (params->>'duration_s')::numeric end as duration_s,
         occurred_at as reported_at
  from public.app_events
  where name = 'session_end' and params->>'reason' in ('background', 'abandoned', 'timed_out')
  order by install_id, params->>'session',
           (params->>'reason' = 'background') desc, occurred_at desc, id desc
)
select s.*, e.reason, e.reason is not null as is_closed,
       case when e.reason = 'background' then e.duration_s end as duration_s,
       extract(epoch from s.last_seen_at - s.started_at) as observed_seconds_floor,
       e.reported_at
from screens s left join ends e using (install_id, session_id);

create or replace view public.screen_reach as
select screen, count(distinct install_id) as installs, count(*) as views,
       round(count(*)::numeric / nullif(count(distinct install_id), 0), 1) as views_per_install,
       round(100.0 * count(distinct install_id) /
         nullif((select count(distinct install_id) from public.analytics_screen_events), 0), 1) as pct_of_installs
from public.analytics_screen_events group by screen;

create or replace view public.session_dropoff as
select last_screen, count(*) as sessions,
       round(100.0 * count(*) / sum(count(*)) over (), 1) as pct_of_sessions,
       round(avg(duration_s)) as avg_seconds, round(avg(views), 1) as avg_screens,
       count(*) filter (where reason = 'abandoned') as recovered_without_clean_end,
       round(100.0 * count(*) filter (where reason = 'abandoned') / count(*), 1) as abandoned_pct,
       count(duration_s) as measured_sessions,
       count(*) filter (where reason = 'timed_out') as timed_out
from public.analytics_screen_sessions where is_closed group by last_screen;

-- Both denominators are exposed. Per-view rates can be diluted by repeated visits; the per-session
-- rate answers "of visits reaching this screen, how many ended here?" Open tails are not exits.
create or replace view public.screen_exit_rate as
with reached as (
  select e.install_id, e.session_id, e.screen, count(*) as views,
         bool_or(e.screen = s.last_screen) as ended_here
  from public.analytics_screen_events e
  join public.analytics_screen_sessions s using (install_id, session_id)
  where s.is_closed group by 1, 2, 3
)
select screen, sum(views)::bigint as views,
       count(*) filter (where ended_here) as times_it_was_the_last_screen,
       round(100.0 * count(*) filter (where ended_here) / nullif(sum(views), 0), 1) as exit_pct,
       count(*) as sessions_reaching_screen,
       round(100.0 * count(*) filter (where ended_here) / count(*), 1) as session_exit_pct
from reached group by screen;

create or replace view public.screen_paths as
with stepped as (
  select e.*, lead(screen) over (partition by install_id, session_id order by seq, occurred_at, id) as next_screen
  from public.analytics_screen_events e
), paths as (
  select e.screen, coalesce(e.next_screen, case when s.is_closed then '(session ended)'
                      else '(no next screen observed)' end) as next_screen
  from stepped e join public.analytics_screen_sessions s using (install_id, session_id)
)
select screen, next_screen, count(*) as transitions,
       round(100.0 * count(*) / sum(count(*)) over (partition by screen), 1) as pct_of_screen
from paths group by screen, next_screen;

-- Seven-day inactivity, including installs that NEVER return to emit a recovered session_end.
-- Last screen comes from screen events, not an older closed session or its delayed recovery event.
create or replace view public.churn_screen as
with last_seen as (
  select install_id, max(greatest(occurred_at, received_at)) as last_event
  from public.app_events group by install_id
), final_screen as (
  select distinct on (install_id) install_id, screen
  from public.analytics_screen_events
  order by install_id, occurred_at desc, id desc
)
select f.screen as last_screen, count(*) as installs_last_seen_here,
       round(100.0 * count(*) / sum(count(*)) over (), 1) as pct_of_churned
from final_screen f join last_seen l using (install_id)
where l.last_event < now() - interval '7 days'
group by f.screen;

create or replace view public.session_shape as
select (started_at at time zone 'UTC')::date as day,
       count(*) as sessions, count(distinct install_id) as installs,
       round(count(*)::numeric / nullif(count(distinct install_id), 0), 1) as sessions_per_install,
       round(avg(views), 1) as avg_screens, round(avg(duration_s)) as avg_seconds,
       percentile_cont(0.5) within group (order by duration_s) as median_seconds,
       count(*) filter (where reason = 'abandoned') as abandoned,
       count(duration_s) as measured_sessions,
       count(*) filter (where not is_closed) as sessions_without_end,
       round(avg(observed_seconds_floor) filter (where duration_s is null)) as unknown_duration_floor_seconds
from public.analytics_screen_sessions group by 1;

-- Acquisition cohorts need a FIRST LAUNCH in an instrumented build, not a surviving screen view.
-- Otherwise installs that quit before the first screen vanish from the denominator, and upgraded
-- installs mix years of pre-instrumentation activity into a purported build-44 funnel.
-- These columns are milestone reach, not an ordered funnel: tabs are optional branches, a purchase
-- can happen later, and a paywall conversion can be a trial rather than a paid renewal.
create or replace view public.app_journey as
with cohorts as (
  select install_id, min(occurred_at) as first_launch
  from public.app_events
  where name = 'app_launched' and params->>'first' = 'true'
    and case when build ~ '^[0-9]{1,9}$' then build::integer >= 44 else false end
  group by install_id
), per_install as (
  select c.install_id, (c.first_launch at time zone 'UTC')::date as cohort_day,
         bool_or(e.name = 'welcome_action') as acted_at_gate,
         bool_or(e.name = 'onboarding_step') as began_onboarding,
         bool_or(e.name = 'plan_generated') as built_plan,
         bool_or(e.name = 'paywall_view') as saw_paywall,
         bool_or(e.name = 'paywall_convert') as subscribed,
         bool_or(e.name = 'screen_view' and e.params->>'screen' = 'today') as reached_today,
         bool_or(e.name = 'screen_view' and e.params->>'screen' = 'plan') as opened_plan,
         bool_or(e.name = 'screen_view' and e.params->>'screen' like 'progress%') as opened_progress,
         bool_or(e.name = 'screen_view' and e.params->>'screen' = 'fuel') as opened_fuel,
         bool_or(e.name = 'workout_started') as started_a_workout,
         bool_or(e.name = 'workout_completed') as completed_a_workout,
         bool_or(e.name = 'screen_view' and (e.occurred_at at time zone 'UTC')::date >
                                          (c.first_launch at time zone 'UTC')::date) as returned_on_later_day,
         bool_or(e.name = 'screen_view' and (e.occurred_at at time zone 'UTC')::date =
                                          (c.first_launch at time zone 'UTC')::date + 1) as returned_d1
  from cohorts c join public.app_events e on e.install_id = c.install_id and e.occurred_at >= c.first_launch
  group by c.install_id, c.first_launch
)
select cohort_day, count(*) as installs,
       count(*) filter (where acted_at_gate) as acted_at_gate,
       count(*) filter (where began_onboarding) as began_onboarding,
       count(*) filter (where built_plan) as built_plan,
       count(*) filter (where saw_paywall) as saw_paywall,
       count(*) filter (where subscribed) as subscribed,
       count(*) filter (where reached_today) as reached_the_app,
       count(*) filter (where opened_plan) as opened_plan,
       count(*) filter (where opened_progress) as opened_progress,
       count(*) filter (where opened_fuel) as opened_fuel,
       count(*) filter (where started_a_workout) as started_a_workout,
       count(*) filter (where completed_a_workout) as completed_a_workout,
       count(*) filter (where returned_on_later_day) as returned_on_later_day,
       count(*) filter (where cohort_day < (now() at time zone 'UTC')::date - 1) as d1_eligible,
       count(*) filter (where returned_d1 and cohort_day < (now() at time zone 'UTC')::date - 1) as returned_d1
from per_install group by cohort_day;

-- Service-role/reporting only. Revoke PUBLIC as well as Supabase's default client grants.
revoke all on public.analytics_screen_events, public.analytics_screen_sessions,
  public.screen_reach, public.session_dropoff, public.screen_exit_rate, public.screen_paths,
  public.churn_screen, public.session_shape, public.app_journey from public, anon, authenticated;
grant select on public.analytics_screen_events, public.analytics_screen_sessions,
  public.screen_reach, public.session_dropoff, public.screen_exit_rate, public.screen_paths,
  public.churn_screen, public.session_shape, public.app_journey to service_role;
