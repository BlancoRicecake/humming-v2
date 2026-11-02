-- Remove legacy mutation bypasses from explicit Supabase API-role grants.
-- Idempotent; preserve backend service_role access and all existing data.
-- Verified in staging, then applied to production on 2026-11-01.
-- Evidence: docs/release/STAGING-VERIFICATION-2026-11-01.md
do $$ begin
  if to_regprocedure('public.upsert_cloud_project(uuid,text,text,jsonb,bigint)') is not null then
    revoke all on function public.upsert_cloud_project(uuid,text,text,jsonb,bigint) from public,anon,authenticated;
    grant execute on function public.upsert_cloud_project(uuid,text,text,jsonb,bigint) to service_role;
  end if;
  if to_regprocedure('public.delete_cloud_project(uuid,text)') is not null then
    revoke all on function public.delete_cloud_project(uuid,text) from public,anon,authenticated;
    grant execute on function public.delete_cloud_project(uuid,text) to service_role;
  end if;
end $$;
notify pgrst, 'reload schema';
