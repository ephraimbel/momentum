-- In-app account deletion (App Store 5.1.1(v)): one authenticated RPC removes the auth user —
-- every public.* row cascades from auth.users (workouts directly; profiles → posts/follows/
-- blocks/reactions/comments/reports), which also frees their @handle.
--
-- Storage is NOT touched here: Supabase forbids SQL deletes on storage.objects ("use the
-- Storage API"), so the app removes the avatar + post photos via the Storage API (as the
-- owner, RLS-scoped) before calling this. Any blob that slips through is unreachable anyway —
-- every storage policy resolves against rows this delete cascades away.
--
-- Local device data is untouched by design (offline-first: the athlete keeps their own
-- history, like a guest).
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;

-- Owners can always list/read their OWN post photos, post row or not. Without this, a photo
-- whose post is gone is invisible to its owner (the follower-gated read policy requires the
-- parent post) — the account-deletion walk couldn't find it, and it would orphan.
create policy storage_post_photos_owner_read on storage.objects for select to authenticated
  using (
    bucket_id = 'post-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
