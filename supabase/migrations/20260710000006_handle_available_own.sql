-- Fix: your own handle must read as available to YOU (Edit Profile opens with the athlete's
-- claimed handle in the field — without this, the availability probe reported it "taken" and
-- offered suggestions to replace their own name). Authenticated callers now exclude their own
-- profiles row; anon callers (guests, no uid) see the unfiltered truth as before.

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
       select 1 from public.profiles p
       where lower(p.handle) = lower(p_handle)
         and (auth.uid() is null or p.id <> auth.uid())
     );
$$;
