-- AI coach rate limiting (2026-07-14): a per-identity DAILY cap so a single athlete — or a leaked
-- token hammering the endpoint — can't run up the Anthropic bill. The coach-chat Edge Function calls
-- `coach_rate_check()` before every model request; over-limit returns 429, and the app silently uses
-- its offline deterministic coach (the chat is never blocked). Generous by design: the cap sits far
-- above real daily use, so it only ever stops abuse. These counts are ephemeral usage, not user data.

create table if not exists public.coach_usage (
  id_key text    not null,                                 -- auth.uid() (signed-in) or client IP (guest)
  day    date    not null default (now() at time zone 'utc')::date,
  count  integer not null default 0,
  primary key (id_key, day)
);

-- No client ever touches this directly — only the SECURITY DEFINER RPC below writes it.
alter table public.coach_usage enable row level security;
revoke all on table public.coach_usage from anon, authenticated;

-- A cleanup job (or a manual prune) can drop old days cheaply.
create index if not exists coach_usage_day_idx on public.coach_usage (day);

-- Atomically bump today's counter for the caller and report whether they're still within the limit.
-- SECURITY DEFINER so it can write `coach_usage` under RLS. Keyed on auth.uid() when signed in
-- (trusted, unspoofable) and on the fallback the edge function passes (the client IP) for guests.
-- The increment happens on EVERY call, so a blocked caller stays blocked for the rest of the UTC day
-- rather than resetting their odds by retrying. Returns the post-increment count so the caller can
-- surface "N of M used" if it ever wants to.
create or replace function public.coach_rate_check(p_limit integer, p_fallback_key text default '')
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
  insert into public.coach_usage (id_key, day, count)
       values (v_key, v_today, 1)
  on conflict (id_key, day)
    do update set count = public.coach_usage.count + 1
    returning count into v_count;

  return query select (v_count <= p_limit), v_count, p_limit;
end;
$$;

revoke all on function public.coach_rate_check(integer, text) from public;
grant execute on function public.coach_rate_check(integer, text) to anon, authenticated;
