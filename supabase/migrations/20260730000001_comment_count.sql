-- Comment counts on the feed (2026-07-30): the rail shows how many comments a post carries
-- WITHOUT opening the sheet. Before this, a remote post's count was 0 until its comments were
-- pulled — the one aggregate the feed row was missing (reactions already ride on it).
--
-- feed_page grows a trailing `comment_count` column, appended LAST (the author_pro precedent):
-- decoders read by name, and PostgREST JSON with an extra key is invisible to app versions that
-- don't know it. Blocked-either filtering matches the reaction count's rule, so a blocked
-- athlete's comments never inflate a count for the viewer.
drop function if exists public.feed_page(text, timestamptz, uuid, int, uuid);
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
  created_at timestamptz,
  author_pro boolean,
  comment_count bigint
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
    p.created_at,
    pr.is_pro,
    (select count(*) from comments c
      where c.post_id = p.id
        and not is_blocked_either((select auth.uid()), c.author_id))
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
