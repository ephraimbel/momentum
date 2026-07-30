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
-- REMOVED (2026-07-26). This section used to `create or replace public.feed_page(...)`.
--
-- This migration was never applied. 20260710000002 (which IS applied) recreated feed_page with a
-- trailing `author_pro` column, and the body that lived here predates it — so running this file
-- would have replaced the live function with an older signature and broken the feed decoder.
-- That is precisely what `supabase db push` would have done, since push applies every pending
-- migration in order and this one was still pending.
--
-- Sections 1, 2 and 4 were applied by hand on 2026-07-26 after verifying preconditions against
-- production (is_following present, profiles.discoverable present, feed_page already carrying
-- author_pro). Section 2's storage policy was already correct in production and was a no-op.
-- The blocked-users change this section also carried lives on in 20260710000002's body.

-- ── 4. global feed keyset index ────────────────────────────────────────────────────────────
create index if not exists posts_created_id on public.posts (created_at desc, id desc);
