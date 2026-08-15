-- Public follow COUNTS for any profile (2026-08-15). The graph itself stays private — the
-- `follows_read` RLS only admits rows the viewer is part of, which is why another real
-- athlete's profile could only ever show "0 Followers · 0 Following" no matter how many
-- people follow them. Counts are the public projection every social surface shows; the
-- LISTS remain viewer-scoped exactly as before (this function exposes two integers, never rows).
--
-- The followers count EXCLUDES the caller's own edge on purpose: the client displays
-- `fetched + (locally following ? 1 : 0)`, so a follow/unfollow tap moves the number in the
-- same frame and stays exact whether or not the server has acknowledged the write yet — the
-- same +mine arithmetic the seeded community profiles have always used. Anonymous callers
-- have no uid, exclude nothing, and can't write follows anyway, so the math still holds.
create or replace function public.follow_counts_of(_handle text)
returns table (followers integer, following integer)
language sql
security definer
set search_path = public
stable
as $$
  select
    (select count(*)::int
       from public.follows f
       join public.profiles p on p.id = f.followee_id
      where p.handle = _handle
        and f.follower_id is distinct from (select auth.uid())) as followers,
    (select count(*)::int
       from public.follows f
       join public.profiles p on p.id = f.follower_id
      where p.handle = _handle) as following
$$;

revoke all on function public.follow_counts_of(text) from public;
grant execute on function public.follow_counts_of(text) to anon, authenticated;
