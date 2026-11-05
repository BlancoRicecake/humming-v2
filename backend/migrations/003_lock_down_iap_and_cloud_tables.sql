-- 003 — lock down tables the client must never touch directly (2026-10-22)
--
-- Why:
-- * iap_notifications had no RLS. Its payload holds Apple signed transactions
--   and Google purchase tokens; with Supabase's default grants anyone holding
--   the (public) anon key could read them via PostgREST and replay them to
--   /iap/verify. Only the backend (service role, which bypasses RLS) uses it.
-- * cloud_projects / cloud_quota allowed owners to write (FOR ALL), so a user
--   could reset used_bytes or insert size_bytes=0 rows and skip quota
--   accounting. Writes go through the service-role RPC upsert_cloud_project.
--
-- Apply with: supabase db push   (or paste into the SQL editor)

-- iap_notifications: RLS on, no policies → service role only.
alter table public.iap_notifications enable row level security;
revoke all on table public.iap_notifications from anon, authenticated;

-- cloud_* (backend/sql/2026-06-04_cloud_sync_schema.sql): owner read-only.
do $$
begin
  if to_regclass('public.cloud_projects') is not null then
    drop policy if exists "own_cloud_projects" on public.cloud_projects;
    create policy "own_cloud_projects" on public.cloud_projects
      for select using (auth.uid() = user_id);
  end if;
  if to_regclass('public.cloud_quota') is not null then
    drop policy if exists "own_cloud_quota" on public.cloud_quota;
    create policy "own_cloud_quota" on public.cloud_quota
      for select using (auth.uid() = user_id);
  end if;
end $$;
