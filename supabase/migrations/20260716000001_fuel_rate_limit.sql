-- Fuel estimate rate limiting (2026-07-16): the meal-estimate Edge Function calls
-- `fuel_rate_check()` before every model request — a per-identity DAILY cap so a single athlete
-- (or a leaked token) can't run up the Gemini/Anthropic bill. Same shape as coach_rate_check
-- (20260714000001). Generous by design: the heaviest honest day — race-day gels, drinks, snacks,
-- meals — sits near 20 estimates; the cap only ever stops abuse. Logging itself is NEVER limited:
-- an over-limit meal simply stays pending with manual numbers always available.

create table if not exists public.fuel_usage (
  id_key text    not null,                                 -- auth.uid() (signed-in) or client IP (guest)
  day    date    not null default (now() at time zone 'utc')::date,
  count  integer not null default 0,
  primary key (id_key, day)
);

-- No client ever touches this directly — only the SECURITY DEFINER RPC below writes it.
alter table public.fuel_usage enable row level security;
revoke all on table public.fuel_usage from anon, authenticated;

create index if not exists fuel_usage_day_idx on public.fuel_usage (day);

-- Atomically bump today's counter for the caller and report whether they're within the limit.
-- The increment happens on EVERY call, so a blocked caller stays blocked for the rest of the
-- UTC day rather than resetting their odds by retrying.
create or replace function public.fuel_rate_check(p_limit integer, p_fallback_key text default '')
returns table (allowed boolean, used integer, lim integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key   text    := coalesce(nullif(auth.uid()::text, ''), nullif(p_fallback_key, ''), 'anon');
  v_today date    := (now() at time zone 'utc')::date;
  v_count integer;
begin
  insert into public.fuel_usage (id_key, day, count)
       values (v_key, v_today, 1)
  on conflict (id_key, day)
    do update set count = public.fuel_usage.count + 1
    returning count into v_count;

  return query select (v_count <= p_limit), v_count, p_limit;
end;
$$;

revoke all on function public.fuel_rate_check(integer, text) from public;
grant execute on function public.fuel_rate_check(integer, text) to anon, authenticated;
