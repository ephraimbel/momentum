-- The one feed query (docs/SOCIAL-LAYER.md: strictly reverse-chronological, no ranking, ever).
-- SECURITY INVOKER: posts RLS does the real gating (visibility + blocks); the scope parameter
-- only narrows to the follow graph. Keyset pagination on (created_at, id) — stable under
-- concurrent inserts, no OFFSET scans. Returns the display payload + the viewer's reaction state
-- so one round trip renders a page.

create or replace function public.feed_page(
  p_scope text default 'everyone',            -- 'everyone' | 'following'
  p_cursor_created timestamptz default null,
  p_cursor_id uuid default null,
  p_limit int default 20,
  p_author uuid default null                  -- non-null → one athlete's page (profile view)
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
    (select count(*) from reactions r where r.post_id = p.id),
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

-- One athlete's public projection + their posts happen through plain PostgREST reads
-- (profiles + posts under RLS); no extra RPC needed.
