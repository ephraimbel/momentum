-- Privacy + performance hardening (2026-07-10 backend audit).
--
-- 1. `discoverable` is now enforced server-side. The old profiles_read was `using (true)` —
--    any authenticated user could enumerate every profile (handle, display name, coarse
--    location) regardless of the toggle the UI promises ("Let others find you in search and
--    suggestions"). New rule: a profile row is readable iff
--      · the athlete opted into discovery, or
--      · it's your own row, or
--      · a follow edge exists in either direction, or
--      · they authored a post or comment the viewer can already see (posts/comments RLS
--        applies inside the subqueries, so "visible" means visible TO THIS VIEWER).
--    The last clause is what keeps the SECURITY INVOKER feed_page join and the comment-author
--    embeds working: anyone whose content you can see remains identifiable on that content —
--    blocks gate posts, not identity — while a non-discoverable stranger with nothing visible
--    to you is no longer enumerable. No recursion: posts/comments policies reference
--    follows/blocks helpers, never profiles.
--
-- 2. post-photos reads now bind the folder owner to the post author. The old policy authorized
--    any object whose second path segment matched a visible post id, without checking the first
--    segment (the uploader) was that post's author — letting a user plant images under their
--    own folder keyed to someone else's public post. Not reachable through the app (clients
--    only render posts.photo_paths), but the invariant belongs in the policy.
--
-- 3. feed_page reaction counts now exclude blocked users, matching comments_read. Counts are
--    the one aggregate where a blocked user still leaked in.
--
-- 4. Global-feed index: feed_page orders all posts by (created_at desc, id desc), but the only
--    matching index was partial (`where visibility = 'public'`), which the RLS OR-clause
--    disqualifies for the general case — the "everyone" feed was a seq-scan + sort waiting to
--    happen. Full keyset index fixes it.

-- ── 1. discoverable enforcement ────────────────────────────────────────────────────────────
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (
    discoverable
    or id = (select auth.uid())
    or public.is_following((select auth.uid()), id)
    or public.is_following(id, (select auth.uid()))
    or exists (select 1 from public.posts p where p.author_id = profiles.id)
    or exists (select 1 from public.comments c where c.author_id = profiles.id)
  );

-- ── 2. post-photos author binding ──────────────────────────────────────────────────────────
drop policy if exists storage_post_photos_read on storage.objects;
create policy storage_post_photos_read on storage.objects for select to authenticated
  using (
    bucket_id = 'post-photos'
    and exists (
      select 1 from public.posts p
      where p.id::text = (storage.foldername(name))[2]
        and p.author_id::text = (storage.foldername(name))[1]
    )
  );

-- ── 3. blocked users out of reaction counts ────────────────────────────────────────────────
create or replace function public.feed_page(
  p_scope text default 'everyone',
  p_cursor_created timestamptz default null,
  p_cursor_id uuid default null,
  p_limit int default 20,
  p_author uuid default null
)
returns table (
  id uuid,
  author_id uuid,
  author_name text,
  author_handle text,
  author_location text,
  avatar_path text,
  workout_type text,
  started_at timestamptz,
  title text,
  caption text,
  stat_line text,
  pr_badge text,
  muscles jsonb,
  route jsonb,
  map_style text,
  ai_read text,
  photo_paths text[],
  reaction_count bigint,
  viewer_reacted boolean,
  created_at timestamptz
)
language sql stable security invoker set search_path = public
as $$
  select
    p.id, p.author_id,
    pr.display_name,
    nullif(pr.handle, ''),
    pr.public_location,
    pr.avatar_path,
    p.workout_type, p.started_at, p.title, p.caption,
    p.stat_line, p.pr_badge, p.muscles, p.route, p.map_style, p.ai_read, p.photo_paths,
    (select count(*) from reactions r
      where r.post_id = p.id
        and not is_blocked_either((select auth.uid()), r.user_id)),
    exists (select 1 from reactions r where r.post_id = p.id and r.user_id = (select auth.uid())),
    p.created_at
  from posts p
  join profiles pr on pr.id = p.author_id
  where (p_scope <> 'following'
         or p.author_id = (select auth.uid())
         or is_following((select auth.uid()), p.author_id))
    and (p_author is null or p.author_id = p_author)
    and (p_cursor_created is null
         or (p.created_at, p.id) < (p_cursor_created, p_cursor_id))
  order by p.created_at desc, p.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

-- ── 4. global feed keyset index ────────────────────────────────────────────────────────────
create index if not exists posts_created_id on public.posts (created_at desc, id desc);
