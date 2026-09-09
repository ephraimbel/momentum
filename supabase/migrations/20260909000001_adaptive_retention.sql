begin;
-- RevenueCat is the billing ledger. Client paywall callbacks are never treated as paid conversions.
create table if not exists public.subscription_events (
  event_id text primary key,
  event_type text not null,
  app_user_id text,
  aliases text[] not null default '{}',
  product_id text,
  original_transaction_id text,
  entitlement_ids text[] not null default '{}',
  environment text,
  period_type text,
  occurred_at timestamptz not null,
  purchased_at timestamptz,
  expires_at timestamptz,
  is_trial_conversion boolean not null default false,
  received_at timestamptz not null default now()
);
alter table public.subscription_events enable row level security;
revoke all on public.subscription_events from anon, authenticated;
grant select, insert on public.subscription_events to service_role;
create index if not exists subscription_events_customer_time on public.subscription_events(app_user_id, occurred_at);

-- Only explicitly linked authenticated identities enter this comparison. Anonymous/unlinked
-- customers remain measurable in the ledger but are not guessed into workout cohorts.
create or replace view public.adaptive_trial_cohorts as
with starts as (
  select event_id, app_user_id, original_transaction_id, occurred_at as trial_at,
         expires_at as trial_end, product_id
  from public.subscription_events
  where environment = 'PRODUCTION' and event_type = 'INITIAL_PURCHASE' and period_type = 'TRIAL'
), identities as (
  -- Renewal/login aliases can link an anonymous trial to the later authenticated account.
  select s.event_id, a.user_id
  from starts s
  join public.subscription_events b on b.environment = 'PRODUCTION'
    and (b.app_user_id = s.app_user_id or s.app_user_id = any(b.aliases))
  join public.app_events a on a.user_id is not null
    and (a.user_id::text = b.app_user_id or a.user_id::text = any(b.aliases))
  group by s.event_id, a.user_id
), unambiguous as (
  select event_id from identities group by event_id having count(*) = 1
), linked as (
  select s.*, i.user_id,
    min(a.occurred_at) filter (where a.name = 'workout_completed' and a.occurred_at >= s.trial_at
       and a.occurred_at < s.trial_end) as first_trial_workout,
    count(distinct a.params->>'plan_week') filter (where a.name = 'next_week_generated'
       and a.occurred_at >= s.trial_at) as adapted_weeks,
    count(distinct a.params->>'session') filter (where a.name = 'session_end'
       and a.occurred_at >= s.trial_at + interval '7 days'
       and a.occurred_at < s.trial_at + interval '14 days') as second_week_sessions
  from starts s
  join identities i using (event_id)
  join unambiguous u using (event_id)
  join public.app_events a on a.user_id = i.user_id
  group by s.event_id, s.app_user_id, s.original_transaction_id, s.trial_at, s.trial_end,
           s.product_id, i.user_id
)
select l.event_id, l.user_id, l.trial_at, l.trial_end,
       l.trial_end is not null as has_known_trial_window,
       l.first_trial_workout is not null as completed_during_trial,
       l.adapted_weeks, l.second_week_sessions,
       exists(select 1 from public.subscription_events b
         where b.environment = 'PRODUCTION' and b.event_type = 'RENEWAL'
           and b.is_trial_conversion and b.occurred_at >= l.trial_at
           and b.original_transaction_id = l.original_transaction_id
           and b.purchased_at <= l.trial_end + interval '7 days') as converted,
       exists(select 1 from public.subscription_events b
         where b.environment = 'PRODUCTION' and b.event_type = 'CANCELLATION'
           and b.period_type = 'TRIAL' and b.occurred_at >= l.trial_at
           and b.occurred_at < l.trial_end
           and b.original_transaction_id = l.original_transaction_id) as cancelled_during_trial
from linked l;
revoke all on public.adaptive_trial_cohorts from anon, authenticated;
grant select on public.adaptive_trial_cohorts to service_role;
commit;
