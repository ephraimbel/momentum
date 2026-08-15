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

  -- Public follow counts (follow_counts_of, 2026-08-15). As B, who follows A:
  -- A's followers read 0 — the CALLER's own edge is excluded (the client adds its local +1),
  -- and B's own following reads 1 (outgoing edges are never caller-excluded).
  select followers into n from public.follow_counts_of('athlete_a');
  if n <> 0 then raise exception 'FAIL: follow_counts_of should exclude the caller''s edge, saw %', n; end if;
  select following into n from public.follow_counts_of('athlete_b');
  if n <> 1 then raise exception 'FAIL: follow_counts_of(B).following should be 1, saw %', n; end if;

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

  -- As A (the followee, not the follower): B's edge counts — A really has 1 follower.
  select followers into n from public.follow_counts_of('athlete_a');
  if n <> 1 then raise exception 'FAIL: follow_counts_of(A).followers should be 1 for A, saw %', n; end if;

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

-- ── Vendor connections (docs/WEARABLES-DIRECT.md) ───────────────────────────
-- The previous block's set_config('role', …) is transaction-scoped and outlives the block —
-- drop back to the owning role so the seed inserts below bypass RLS like the ones at the top.
reset role;

-- Seeded as service role: a Garmin connection + tokens + one staged activity for A.
insert into public.vendor_connections (id, user_id, vendor, vendor_user_id) values
  ('00000000-0000-0000-0004-000000000001', '00000000-0000-0000-0000-00000000000a', 'garmin', 'garmin-user-a');

insert into public.vendor_tokens (connection_id, access_token, refresh_token) values
  ('00000000-0000-0000-0004-000000000001', 'secret-access', 'secret-refresh');

insert into public.vendor_activities (id, user_id, vendor, vendor_activity_id, started_at, duration_s, distance_m) values
  ('00000000-0000-0000-0005-000000000001', '00000000-0000-0000-0000-00000000000a', 'garmin', 'act-1', now(), 1800, 5000);

do $$
declare
  n int;
begin
  -- ── Act as B (stranger): A's vendor world is invisible ────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);

  select count(*) into n from public.vendor_connections;
  if n <> 0 then raise exception 'FAIL: stranger can read vendor connections (%)', n; end if;

  select count(*) into n from public.vendor_activities;
  if n <> 0 then raise exception 'FAIL: stranger can read vendor activities (%)', n; end if;

  -- ── Act as A (owner) ──────────────────────────────────────────────────────
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);

  select count(*) into n from public.vendor_connections;
  if n <> 1 then raise exception 'FAIL: owner should see their connection, saw %', n; end if;

  -- Tokens are service-role only — even the owner must be locked out entirely.
  begin
    select count(*) into n from public.vendor_tokens;
    raise exception 'FAIL: owner can read vendor tokens';
  exception when insufficient_privilege then null;
  end;

  -- Owner may flip `processed` on a staged activity…
  update public.vendor_activities set processed = true
  where id = '00000000-0000-0000-0005-000000000001';
  select count(*) into n from public.vendor_activities where processed;
  if n <> 1 then raise exception 'FAIL: owner could not mark activity processed'; end if;

  -- …but no other column (column-level grant).
  begin
    update public.vendor_activities set distance_m = 1
    where id = '00000000-0000-0000-0005-000000000001';
    raise exception 'FAIL: owner mutated a staged activity beyond processed';
  exception when insufficient_privilege then null;
  end;

  -- No client inserts into the staging inbox (webhook/service role only).
  begin
    insert into public.vendor_activities (user_id, vendor, vendor_activity_id, started_at)
    values ('00000000-0000-0000-0000-00000000000a', 'garmin', 'act-forged', now());
    raise exception 'FAIL: client inserted into vendor_activities';
  exception when insufficient_privilege then null;
  end;

  -- Disconnect = owner deletes the connection (tokens cascade).
  delete from public.vendor_connections where vendor = 'garmin';
  select count(*) into n from public.vendor_connections;
  if n <> 0 then raise exception 'FAIL: owner could not disconnect vendor'; end if;

  raise notice 'RLS matrix (vendor): all checks passed';
end $$;

rollback;
