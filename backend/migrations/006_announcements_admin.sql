-- 006 — announcements managed from the web (2026-11-02)
--
-- Applied to production on 2026-11-02 (after 005_app_announcements.sql);
-- not applied to staging. A different file, 006_cloud_lifecycle.sql, shares
-- the number — see migrations/README.md. Do not rename or re-run this file.
--
-- The web admin page (hum-track.com/admin/notices) signs in with Supabase
-- Auth (Google) and writes app_announcements with the user's own token.
-- Only the e-mails listed in public.app_admins may read drafts or write;
-- everyone else keeps 005's rule (published + active rows, read only).
-- Adding an admin later is one row:
--   insert into public.app_admins (email) values ('someone@example.com');
--
-- Rollback:
--   DROP POLICY IF EXISTS "admin_all" ON public.app_announcements;
--   REVOKE INSERT, UPDATE, DELETE ON public.app_announcements FROM authenticated;
--   DROP FUNCTION IF EXISTS public.is_app_admin();
--   DROP TABLE IF EXISTS public.app_admins;

create table if not exists public.app_admins (
  email      text primary key check (email = lower(email)),
  created_at timestamptz not null default now()
);

-- nobody reads or writes the list through the API; the function below does
alter table public.app_admins enable row level security;
revoke all on table public.app_admins from anon, authenticated;

insert into public.app_admins (email) values ('humtrack@gmail.com')
  on conflict (email) do nothing;

-- true when the signed-in user's (verified) e-mail is an admin
create or replace function public.is_app_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.app_admins a
    where a.email = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
  and coalesce((auth.jwt() -> 'user_metadata' ->> 'email_verified')::boolean, true)
$$;

revoke all on function public.is_app_admin() from public, anon;
grant execute on function public.is_app_admin() to authenticated;

-- admins: everything (drafts included); 005's read policy stays for others
grant insert, update, delete on table public.app_announcements to authenticated;

drop policy if exists "admin_all" on public.app_announcements;
create policy "admin_all" on public.app_announcements
  for all to authenticated
  using (public.is_app_admin())
  with check (public.is_app_admin());
