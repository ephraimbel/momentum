-- Storage buckets + policies (docs/SOCIAL-BACKEND-SETUP.md).
--   avatars      PUBLIC  — small identity images, CDN-served (the profile row is already the
--                          public projection; an avatar has no privacy tier of its own).
--   post-photos  PRIVATE — post photos are follower-gated; reads are authorized per-viewer by an
--                          RLS check against the parent post, then served via short-lived signed
--                          URLs. Path convention: {auth.uid()}/{postId}/{uuid}.jpg — the first
--                          segment is the owner, the second the post.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 2097152, array['image/jpeg','image/png','image/webp']),
  ('post-photos', 'post-photos', false, 10485760, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do nothing;

-- Writes: only into your own top-level folder, in either bucket.
create policy storage_own_folder_insert on storage.objects for insert to authenticated
  with check (
    bucket_id in ('avatars','post-photos')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy storage_own_folder_update on storage.objects for update to authenticated
  using (
    bucket_id in ('avatars','post-photos')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy storage_own_folder_delete on storage.objects for delete to authenticated
  using (
    bucket_id in ('avatars','post-photos')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- Post-photo reads inherit the parent post's visibility: the posts subquery runs under the
-- caller's RLS (owner/public/follower + blocks). This is what authorizes signed-URL minting.
create policy storage_post_photos_read on storage.objects for select to authenticated
  using (
    bucket_id = 'post-photos'
    and exists (
      select 1 from public.posts p
      where p.id::text = (storage.foldername(name))[2]
    )
  );

-- Avatars are in a public bucket (anonymous CDN reads bypass RLS), but authenticated API reads
-- (e.g. list/download through the SDK) still need a select policy.
create policy storage_avatars_read on storage.objects for select to authenticated
  using (bucket_id = 'avatars');
