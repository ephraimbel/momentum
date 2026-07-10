-- RLS visibility matrix (docs/SOCIAL-BACKEND-SETUP.md §Verify).
-- Run in the Supabase SQL editor (or psql against the linked db). Everything runs inside a
-- transaction and rolls back — safe on a live project. Failures raise; a clean run prints
-- 'RLS matrix: all checks passed'.

begin;

-- Two throwaway users straight into auth.users (service-role context).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@test.local', '', now(), now(), now()),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b@test.local', '', now(), now(), now());

insert into public.profiles (id, handle, display_name) values
  ('00000000-0000-0000-0000-00000000000a', 'athlete_a', 'Athlete A'),
  ('00000000-0000-0000-0000-00000000000b', 'athlete_b', 'Athlete B');

-- A's data: an owner-only workout, a public post, a friends post.
insert into public.workouts (id, user_id, type, started_at, route) values
  ('00000000-0000-0000-0001-000000000001', '00000000-0000-0000-0000-00000000000a', 'run', now(), '[[37.0,-122.0],[37.1,-122.1]]');

insert into public.posts (id, author_id, visibility, workout_type, started_at, title, stat_line) values
  ('00000000-0000-0000-0002-000000000001', '00000000-0000-0000-0000-00000000000a', 'public',  'run', now(), 'Public run',  '5.0 mi · 40:00'),
  ('00000000-0000-0000-0002-000000000002', '00000000-0000-0000-0000-00000000000a', 'friends', 'run', now(), 'Friends run', '5.0 mi · 40:00');

do $$
declare
  n int;
begin
  -- ── Act as B (stranger) ──────────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);

  select count(*) into n from public.workouts;
  if n <> 0 then raise exception 'FAIL: stranger can read owner workouts (%)', n; end if;

  select count(*) into n from public.posts;
  if n <> 1 then raise exception 'FAIL: stranger should see exactly the public post, saw %', n; end if;

  select count(*) into n from public.posts where visibility = 'friends';
  if n <> 0 then raise exception 'FAIL: friends post visible without a follow'; end if;

  -- B follows A → the friends post appears.
  insert into public.follows (follower_id, followee_id)
  values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000a');

  select count(*) into n from public.posts;
  if n <> 2 then raise exception 'FAIL: follower should see public+friends, saw %', n; end if;

  -- Feed RPC agrees with direct reads (following scope).
  select count(*) into n from public.feed_page('following', null, null, 20);
  if n <> 2 then raise exception 'FAIL: feed_page(following) returned %', n; end if;

  -- B reacts + comments on the public post.
  insert into public.reactions (post_id, user_id)
  values ('00000000-0000-0000-0002-000000000001', '00000000-0000-0000-0000-00000000000b');

  insert into public.comments (id, post_id, author_id, body)
  values ('00000000-0000-0000-0003-000000000001', '00000000-0000-0000-0002-000000000001',
          '00000000-0000-0000-0000-00000000000b', 'Nice run!');

  -- Comment length CHECK: 281 chars must be rejected.
  begin
    insert into public.comments (id, post_id, author_id, body)
    values ('00000000-0000-0000-0003-000000000002', '00000000-0000-0000-0002-000000000001',
            '00000000-0000-0000-0000-00000000000b', repeat('x', 281));
    raise exception 'FAIL: 281-char comment was accepted';
  exception when check_violation then null;
  end;

  -- Reports are insert-only: the insert works, reading back does not.
  insert into public.reports (reporter_id, post_id, reason)
  values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0002-000000000001', 'spam');

  select count(*) into n from public.reports;
  if n <> 0 then raise exception 'FAIL: client can read reports (%)', n; end if;

  -- ── Act as A: block B → B's world goes dark both directions ──────────────
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);

  insert into public.blocks (blocker_id, blocked_id)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b');

  select count(*) into n from public.comments;   -- A opening their own post's thread
  if n <> 0 then raise exception 'FAIL: blocked user''s comment still visible to blocker'; end if;

  -- ── Back to B: A's posts (and the whole feed from A) are gone ────────────
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);

  select count(*) into n from public.posts;
  if n <> 0 then raise exception 'FAIL: blocked-either posts still visible, saw %', n; end if;

  select count(*) into n from public.feed_page('everyone', null, null, 20);
  if n <> 0 then raise exception 'FAIL: feed_page still returns blocked author''s posts (%)', n; end if;

  raise notice 'RLS matrix: all checks passed';
end $$;

rollback;
