-- Supabase Reports; service-role/owner access only. Times and acquisition cohorts are UTC.
-- These queries are descriptive: an exit is not proof of dissatisfaction.

-- 1. Acquisition milestone reach, BAR chart (NOT a sequential funnel: tabs are optional).
select milestone, sum(reach.installs) as installs
from public.app_journey,
lateral (values ('first launch (build 44+)', installs), ('began onboarding', began_onboarding),
 ('built plan', built_plan), ('saw paywall', saw_paywall), ('purchase / trial conversion', subscribed),
 ('reached Today', reached_the_app), ('opened Plan', opened_plan), ('opened Progress', opened_progress),
 ('opened Fuel', opened_fuel), ('started workout', started_a_workout),
 ('completed workout', completed_a_workout), ('returned on a later UTC day', returned_on_later_day)
) as reach(milestone, installs)
group by milestone;

-- 2. Last observed screen before seven-day inactivity (including unclosed visits).
select last_screen as screen, installs_last_seen_here as installs
from public.churn_screen order by installs desc limit 12;

-- 3. Visit-normalized exit rate, confirmed endings only. Show sample sizes alongside the rate.
select screen, sessions_reaching_screen, session_exit_pct, exit_pct as per_view_exit_pct
from public.screen_exit_rate where sessions_reaching_screen >= 20
order by session_exit_pct desc limit 15;

-- 4. Screen reach among observed instrumented installs (includes upgrades).
select screen, installs, pct_of_installs from public.screen_reach order by pct_of_installs desc;

-- 5. Foreground-visit shape. Measured durations and missing-end counts must be read together.
select day, median_seconds, measured_sessions, sessions_without_end, abandoned,
       avg_screens, sessions_per_install
from public.session_shape where day >= (now() at time zone 'UTC')::date - 59 order by day;

-- 6. D1 retention among fully observed acquisition cohorts; same-day app switches are not returns.
select cohort_day, d1_eligible, returned_d1,
       round(100.0 * returned_d1 / nullif(d1_eligible, 0), 1) as d1_retention_pct
from public.app_journey where d1_eligible > 0 order by cohort_day;
