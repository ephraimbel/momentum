-- One-post projection for notification deep links.
--
-- A feed notification may point to a workout older than the first feed_page result. Fetching that
-- target by id avoids paging through (and signing photos for) every newer post. SECURITY INVOKER
-- is intentional: the posts/profiles RLS policies remain the authority, so a guessed UUID cannot
-- reveal a private, blocked, or otherwise invisible post.
create or replace function public.feed_post(p_post_id uuid)
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
  created_at timestamptz,
  author_pro boolean,
  comment_count bigint,
  cover_is_photo boolean,
  earned_context text
)
language sql stable security invoker set search_path = public
as $$
  select
    p.id, p.author_id, pr.display_name, nullif(pr.handle, ''), pr.public_location,
    pr.avatar_path, p.workout_type, p.started_at, p.title, p.caption, p.stat_line,
    p.pr_badge, p.muscles, p.route, p.map_style, p.ai_read, p.photo_paths,
    (select count(*) from reactions r
      where r.post_id = p.id and not is_blocked_either((select auth.uid()), r.user_id)),
    exists (select 1 from reactions r
      where r.post_id = p.id and r.user_id = (select auth.uid())),
    p.created_at, pr.is_pro,
    (select count(*) from comments c
      where c.post_id = p.id and not is_blocked_either((select auth.uid()), c.author_id)),
    p.cover_is_photo, p.earned_context
  from posts p
  join profiles pr on pr.id = p.author_id
  where p.id = p_post_id
  limit 1;
$$;

revoke all on function public.feed_post(uuid) from public;
revoke all on function public.feed_post(uuid) from anon;
grant execute on function public.feed_post(uuid) to authenticated;
