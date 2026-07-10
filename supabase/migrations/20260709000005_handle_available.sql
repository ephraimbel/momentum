-- Handle claiming (docs/SOCIAL-LAYER.md, onboarding identity step).
-- Uniqueness truth stays `profiles_handle_unique` (unique on lower(handle) where handle <> '');
-- this migration adds (1) server-side format + reserved-name enforcement so no hand-rolled
-- client can bypass what SocialPrivacy.normalizedHandle enforces in the app, and (2) an
-- anon-callable availability probe so the onboarding field can live-check for guests too
-- (profiles RLS is authenticated-only — this function is deliberately the ONLY anon window,
-- and it leaks nothing but "does some athlete own this handle": an accepted trade-off).

-- Keep this list byte-identical to SocialPrivacy.reservedHandles (Momentum/Engines/SocialPrivacy.swift).
-- A drift only softens client UX — the constraint + function here still enforce.

alter table public.profiles
  add constraint profiles_handle_format check (handle ~ '^[a-z0-9_]{0,20}$');

alter table public.profiles
  add constraint profiles_handle_not_reserved check (
    lower(handle) <> all (array[
      'momentum','admin','administrator','support','help','official','mod','moderator',
      'team','staff','root','api','www','app','about','settings','profile','athlete',
      'everyone','following','feed'
    ])
  );

create or replace function public.handle_available(p_handle text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select p_handle ~ '^[a-z0-9_]{1,20}$'
     and lower(p_handle) <> all (array[
       'momentum','admin','administrator','support','help','official','mod','moderator',
       'team','staff','root','api','www','app','about','settings','profile','athlete',
       'everyone','following','feed'
     ])
     and not exists (
       select 1 from public.profiles where lower(handle) = lower(p_handle)
     );
$$;

revoke all on function public.handle_available(text) from public;
grant execute on function public.handle_available(text) to anon, authenticated;
