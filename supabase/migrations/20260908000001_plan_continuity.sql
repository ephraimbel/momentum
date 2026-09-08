-- Private plan continuity. Workouts remain in their existing upload path; this document carries
-- the plan graph and bounded recent training evidence needed to restore adaptive behavior.
create table if not exists public.plan_continuity (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null check (revision > 0),
  operation_id uuid not null,
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  updated_at timestamptz not null default now()
);
alter table public.plan_continuity enable row level security;
revoke all on public.plan_continuity from anon, authenticated;
grant select on public.plan_continuity to authenticated;
create policy "plan owner reads own continuity" on public.plan_continuity
  for select to authenticated using (user_id = auth.uid());

create or replace function public.commit_plan_continuity(
  p_expected_revision bigint,
  p_operation_id uuid,
  p_snapshot jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  owner_id uuid := auth.uid();
  current_row public.plan_continuity%rowtype;
begin
  if owner_id is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_expected_revision is null or p_expected_revision < 0 or p_operation_id is null
     or p_snapshot is null or jsonb_typeof(p_snapshot) <> 'object'
     or p_snapshot->>'version' is distinct from '1'
     or jsonb_typeof(p_snapshot->'profile') is distinct from 'object'
     or jsonb_typeof(p_snapshot->'coach') is distinct from 'object'
     or octet_length(p_snapshot::text) > 8388608 then
    raise exception 'Invalid plan snapshot' using errcode = '22023';
  end if;
  -- Reject missing/malformed identities rather than storing a document no client can restore.
  perform (p_snapshot->'profile'->>'id')::uuid;
  if p_snapshot->'profile'->>'id' is null then
    raise exception 'Missing profile identity' using errcode = '22023';
  end if;
  select * into current_row from public.plan_continuity where user_id = owner_id for update;
  if not found then
    if p_expected_revision <> 0 then raise exception 'Plan no longer exists' using errcode = '40001'; end if;
    insert into public.plan_continuity(user_id, revision, operation_id, snapshot)
      values(owner_id, 1, p_operation_id, p_snapshot)
      on conflict(user_id) do nothing returning * into current_row;
    if found then
      return jsonb_build_object('revision', current_row.revision, 'operation_id', current_row.operation_id, 'snapshot', current_row.snapshot);
    end if;
    select * into current_row from public.plan_continuity where user_id = owner_id for update;
  end if;
  if current_row.operation_id = p_operation_id then
    if current_row.snapshot <> p_snapshot then
      raise exception 'Operation identity reused with different content' using errcode = '22023';
    end if;
  elsif current_row.revision = p_expected_revision then
    update public.plan_continuity set revision = revision + 1, operation_id = p_operation_id,
      snapshot = p_snapshot, updated_at = now() where user_id = owner_id returning * into current_row;
  end if;
  -- A revision conflict returns the winning copy without overwriting it. The client must ask
  -- the athlete to choose; an old device can never win just by retrying a request.
  return jsonb_build_object('revision', current_row.revision, 'operation_id', current_row.operation_id, 'snapshot', current_row.snapshot);
end;
$$;
revoke all on function public.commit_plan_continuity(bigint, uuid, jsonb) from public, anon;
grant execute on function public.commit_plan_continuity(bigint, uuid, jsonb) to authenticated;
