-- Social core (docs/SOCIAL-LAYER.md Slice 6): profiles, follow graph, blocks, posts,
-- reactions, comments, reports. Design rules:
--   * Everything the server holds is ALREADY publish-redacted by the client
--     (SocialPrivacy: location granularity applied, stat line respects show-exact-numbers,
--     route trimmed at the ends or absent). RLS decides WHO sees a row, never re-redacts it.
--   * Blocks are enforced server-side in read policies (App Store 1.2), both directions.
--   * `(select auth.uid())` everywhere — initPlan caching; SECURITY DEFINER helpers break
--     RLS recursion between posts↔follows/blocks and are pinned to search_path=public.

-- ── Profiles ────────────────────────────────────────────────────────────────
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  handle text not null default '',
  display_name text not null default '',
  bio text not null default '',
  public_location text,                 -- client-redacted (city/region or null) — raw city never uploads
  avatar_path text,                     -- storage path in the public `avatars` bucket
  discoverable boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Handles are globally unique once claimed; '' means unclaimed (many rows may have it).
create unique index profiles_handle_unique on public.profiles (lower(handle)) where handle <> '';

alter table public.profiles enable row level security;

create policy profiles_read on public.profiles for select to authenticated
  using (true);   -- profile rows are publish-redacted projections; blocks gate posts, not identity

create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));

create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid()));

-- ── Follow graph (asymmetric) ───────────────────────────────────────────────
create table public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followee_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

create index follows_followee on public.follows (followee_id);

alter table public.follows enable row level security;

create policy follows_read on public.follows for select to authenticated
  using (follower_id = (select auth.uid()) or followee_id = (select auth.uid()));

create policy follows_insert on public.follows for insert to authenticated
  with check (follower_id = (select auth.uid()));

create policy follows_delete on public.follows for delete to authenticated
  using (follower_id = (select auth.uid()));

-- ── Blocks ──────────────────────────────────────────────────────────────────
create table public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

alter table public.blocks enable row level security;

create policy blocks_read on public.blocks for select to authenticated
  using (blocker_id = (select auth.uid()));

create policy blocks_insert on public.blocks for insert to authenticated
  with check (blocker_id = (select auth.uid()));

create policy blocks_delete on public.blocks for delete to authenticated
  using (blocker_id = (select auth.uid()));

-- ── Graph helpers (SECURITY DEFINER: bypass RLS on follows/blocks inside policies) ──
create or replace function public.is_following(_follower uuid, _followee uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from follows f
    where f.follower_id = _follower and f.followee_id = _followee
  );
$$;

create or replace function public.is_blocked_either(_a uuid, _b uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from blocks b
    where (b.blocker_id = _a and b.blocked_id = _b)
       or (b.blocker_id = _b and b.blocked_id = _a)
  );
$$;

-- ── Posts (the publish-redacted display payload; id = the workout's local UUID) ──
create table public.posts (
  id uuid primary key,
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  visibility text not null check (visibility in ('public','friends')),
  workout_type text not null,
  started_at timestamptz not null,
  title text not null default '',
  caption text,
  stat_line text not null default '',   -- pre-formatted " · " strip; exact-numbers rule pre-applied
  distance_m double precision,
  duration_s double precision,
  total_volume_kg double precision,
  total_sets int,
  avg_pace_s_per_km double precision,
  pr_badge text,
  muscles jsonb,                        -- {"chest":0.9,...} | null
  route jsonb,                          -- TRIMMED [[lat,lon]] | null (ends removed client-side)
  map_style text not null default 'standard',
  ai_read text,
  photo_paths text[] not null default '{}',  -- ordered storage paths; first = hero (cap 5)
  created_at timestamptz not null default now(),
  check (cardinality(photo_paths) <= 5)
);

create index posts_author_created on public.posts (author_id, created_at desc);
create index posts_public_created on public.posts (created_at desc, id desc) where visibility = 'public';

alter table public.posts enable row level security;

create policy posts_read on public.posts for select to authenticated
  using (
    author_id = (select auth.uid())
    or ( not public.is_blocked_either((select auth.uid()), author_id)
         and ( visibility = 'public'
               or (visibility = 'friends'
                   and public.is_following((select auth.uid()), author_id)) ) )
  );

create policy posts_insert on public.posts for insert to authenticated
  with check (author_id = (select auth.uid()));

create policy posts_update on public.posts for update to authenticated
  using (author_id = (select auth.uid()));

create policy posts_delete on public.posts for delete to authenticated
  using (author_id = (select auth.uid()));

-- ── Reactions (one iridescent "respect" per athlete per post) ───────────────
create table public.reactions (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create index reactions_post on public.reactions (post_id);

alter table public.reactions enable row level security;

-- Read/insert inherit the post's visibility: the subquery on posts runs under the CALLER's RLS.
create policy reactions_read on public.reactions for select to authenticated
  using (exists (select 1 from public.posts p where p.id = post_id));

create policy reactions_insert on public.reactions for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.posts p where p.id = post_id));

create policy reactions_delete on public.reactions for delete to authenticated
  using (user_id = (select auth.uid()));

-- ── Comments (flat, 280 chars — mirrors CommentModeration.maxLength) ────────
create table public.comments (
  id uuid primary key,                  -- client-generated (Comment.id) → idempotent upsert
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 280),
  created_at timestamptz not null default now()
);

create index comments_post on public.comments (post_id, created_at);

alter table public.comments enable row level security;

create policy comments_read on public.comments for select to authenticated
  using (
    exists (select 1 from public.posts p where p.id = post_id)   -- caller can see the post
    and not public.is_blocked_either((select auth.uid()), author_id)
  );

create policy comments_insert on public.comments for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and exists (select 1 from public.posts p where p.id = post_id)
  );

-- Comment authors can delete their own; post authors can moderate their own post's thread.
create policy comments_delete on public.comments for delete to authenticated
  using (
    author_id = (select auth.uid())
    or exists (select 1 from public.posts p
               where p.id = post_id and p.author_id = (select auth.uid()))
  );

-- ── Reports (App Store 1.2 audit trail; write-only from clients) ────────────
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  post_id uuid,
  comment_id uuid,
  target_handle text,
  reason text not null check (reason in ('spam','inappropriate','harassment','other')),
  details text,
  status text not null default 'pending' check (status in ('pending','actioned','dismissed')),
  created_at timestamptz not null default now()
);

alter table public.reports enable row level security;

-- Insert-only for clients; review happens in the dashboard (service role bypasses RLS).
create policy reports_insert on public.reports for insert to authenticated
  with check (reporter_id = (select auth.uid()));
