-- Nudges (2026-08-25, the social-forward call). One outbound social gesture beyond the
-- reaction: "I noticed you haven't trained today." Deliberately narrow so it can never become a
-- leaderboard or a pressure channel:
--   * only between MUTUALS (both follow edges exist) — you cannot nudge a stranger;
--   * at most ONE per pair per day (unique index on the calendar day);
--   * the row carries no text — there is nothing to moderate.
-- Rows are owner-scoped both ways: the sender sees what they sent, the receiver what they got.

create table public.nudges (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references public.profiles(id) on delete cascade,
  to_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  seen_at timestamptz,
  check (from_id <> to_id)
);

create unique index nudges_one_per_day on public.nudges (from_id, to_id, ((created_at at time zone 'utc')::date));
create index nudges_to on public.nudges (to_id, seen_at);

alter table public.nudges enable row level security;

create policy nudges_read on public.nudges for select to authenticated
  using (from_id = (select auth.uid()) or to_id = (select auth.uid()));

-- Writes go through `nudge(_handle)` (security definer) so the mutual-follow check is enforced
-- server-side; there is deliberately NO insert policy for direct table writes.

create policy nudges_seen on public.nudges for update to authenticated
  using (to_id = (select auth.uid()))
  with check (to_id = (select auth.uid()));

-- Send a nudge to a handle. Returns true when a new row landed; false when the target is not a
-- mutual, does not exist, is yourself, or was already nudged today (the unique index).
create or replace function public.nudge(_handle text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := (select auth.uid());
  target uuid;
begin
  if me is null then return false; end if;
  select id into target from public.profiles where lower(handle) = lower(_handle) and handle <> '';
  if target is null or target = me then return false; end if;
  if not exists (select 1 from public.follows where follower_id = me and followee_id = target)
     or not exists (select 1 from public.follows where follower_id = target and followee_id = me) then
    return false;
  end if;
  begin
    insert into public.nudges (from_id, to_id) values (me, target);
  exception when unique_violation then
    return false;
  end;
  return true;
end;
$$;

revoke all on function public.nudge(text) from public;
grant execute on function public.nudge(text) to authenticated;

-- Unseen nudges for the caller, newest first, with the sender's public identity; marks them
-- seen in the same call so a second pull never re-delivers.
create or replace function public.pull_nudges()
returns table (id uuid, from_handle text, from_name text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := (select auth.uid());
begin
  if me is null then return; end if;
  return query
    with fresh as (
      update public.nudges n set seen_at = now()
       where n.to_id = me and n.seen_at is null
       returning n.id, n.from_id, n.created_at
    )
    select f.id, p.handle, p.display_name, f.created_at
      from fresh f join public.profiles p on p.id = f.from_id
     order by f.created_at desc;
end;
$$;

revoke all on function public.pull_nudges() from public;
grant execute on function public.pull_nudges() to authenticated;

-- Who follows the caller back, as handles — the client needs this to know whom it MAY nudge
-- (mutuals) before the server would refuse. `follows_read` already admits these rows; this is
-- just the cheap projection.
create or replace function public.mutual_handles()
returns setof text
language sql
security definer
set search_path = public
stable
as $$
  select p.handle
    from public.follows a
    join public.follows b on b.follower_id = a.followee_id and b.followee_id = a.follower_id
    join public.profiles p on p.id = a.followee_id
   where a.follower_id = (select auth.uid())
$$;

revoke all on function public.mutual_handles() from public;
grant execute on function public.mutual_handles() to authenticated;
