-- `onboarding_funnel`, re-keyed on BUILD (2026-08-22). The original view (20260812000001) split by
-- `app_version` precisely to contain the fact that `step` is `OnboardingViewModel.Step.rawValue` —
-- an ordinal that MOVES whenever a case is added to or removed from the enum. The instinct was
-- right; the key was wrong.
--
-- `app_version` is `CFBundleShortVersionString` — the MARKETING string ("1.4.0"). One marketing
-- version spans many builds: 1.4.0 alone covers builds 28 through 33+. `app_events` has carried a
-- separate `build` column since the table was created, and that is the only column fine-grained
-- enough to separate two enum eras that shipped under the same version string.
--
-- The concrete case this exists for: the `rateUs` beat (added 2026-07-26) is removed in build 33,
-- sliding `account` from rawValue 25 to 24. Cases 0-23 are byte-identical either side of that line.
--       builds <= 32    24 = RATE US, 25 = account
--       builds >= 33    24 = account   (there is no 25)
-- Grouped by `app_version`, builds 32 and 33 land in the same "1.4.0" bucket and step 24 silently
-- averages two different screens together. Grouped by `build`, they never touch.
--
-- This view deliberately carries NO screen labels — a label map has to be era-aware and belongs
-- with the analysis, not the schema. It lives in `scripts/analysis/funnel_dropoff.sql` (block 2).
-- When the enum changes again, ADD an era there; never renumber the map in place, or every
-- historical cohort silently re-labels.
--
-- DROP + CREATE, not CREATE OR REPLACE: `build` becomes the leading column, and Postgres only lets
-- a replace append columns, never reorder them. Nothing else in the repo reads this view.

drop view if exists public.onboarding_funnel;

create view public.onboarding_funnel as
with steps as (
  select build,
         app_version,
         install_id,
         (params->>'index')::int as step
  from public.app_events
  where name = 'onboarding_step'
    and params->>'index' ~ '^[0-9]+$'   -- ignore anything malformed rather than error the view
),
per_step as (
  select build,
         max(app_version)              as app_version,
         step,
         count(distinct install_id)    as installs
  from steps
  group by build, step
)
select build,
       app_version,
       step,
       installs,
       lag(installs) over (partition by build order by step) - installs
         as dropped_from_previous,
       round(100.0 * installs
             / nullif(first_value(installs) over (partition by build order by step), 0), 1)
         as pct_of_starters
from per_step
-- Builds are numeric strings; sort them numerically so 9 doesn't outrank 32. A row whose build is
-- '' (the column default, pre-instrumentation clients) sorts last rather than erroring the cast.
order by nullif(regexp_replace(build, '\D', '', 'g'), '')::int desc nulls last,
         step;

-- Dashboard-only, exactly like the view it replaces. This is load-bearing here in a way it is not
-- for a plain replace: DROP discards the old grants, and Supabase's default privileges on schema
-- `public` can hand a freshly created view straight to anon/authenticated — which would give the
-- shipped (public) anon key a read path into the event stream.
revoke all on public.onboarding_funnel from anon, authenticated;
