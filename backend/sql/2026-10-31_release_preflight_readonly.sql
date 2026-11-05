-- READ ONLY. Run in the intended Supabase project's owner SQL Editor.
-- Reports catalog facts only. No keys, user IDs, titles, or recordings.
-- A pass here does not prove PostgREST cache refresh, worker execution or R2 behavior.
with required_tables(name, private) as (values
  ('cloud_projects',false),('cloud_quota',false),('app_announcements',false),
  ('cloud_accounts',true),('cloud_object_leases',true),('cloud_delete_jobs',true),('cloud_cleanup_workers',true)
), table_checks as (
  select 'table_rls:'||r.name as check_name,
    coalesce(c.relrowsecurity,false) as passed,
    'table exists and row level security is enabled' as detail
  from required_tables r left join pg_class c on c.oid=to_regclass('public.'||r.name)
  union all
  select 'private_client_access:'||r.name,
    c.oid is not null and not has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE')
      and not has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE'),
    'private lifecycle tables grant no direct client data access'
  from required_tables r left join pg_class c on c.oid=to_regclass('public.'||r.name)
  where r.private
), admin_gate as (
  -- 006_announcements_admin.sql (applied in production 2026-11-02): the one
  -- client write policy allowed, and only in exactly this shape. Its gate
  -- function and admin list must stay closed to the API roles.
  select coalesce((
    select f.prosecdef and f.prorettype='boolean'::regtype
      and not has_function_privilege('anon',f.oid,'EXECUTE')
    from pg_proc f where f.oid=to_regprocedure('public.is_app_admin()')
  ),false) and coalesce((
    select a.relrowsecurity
      and not has_table_privilege('anon',a.oid,'SELECT,INSERT,UPDATE,DELETE')
      and not has_table_privilege('authenticated',a.oid,'SELECT,INSERT,UPDATE,DELETE')
    from pg_class a where a.oid=to_regclass('public.app_admins')
  ),false) as safe
), policy_checks as (
  select 'client_policy:'||r.name as check_name,
    c.oid is not null and exists (
      select 1 from pg_policy p where p.polrelid=c.oid and p.polcmd='r'
    ) and not exists (
      select 1 from pg_policy p where p.polrelid=c.oid and p.polcmd<>'r'
        and (0=any(p.polroles) or p.polroles && array[
          (select oid from pg_roles where rolname='anon'),
          (select oid from pg_roles where rolname='authenticated')])
        and not (
          r.name='app_announcements' and p.polname='admin_all' and p.polcmd='*'
          and p.polpermissive
          and p.polroles=array[(select oid from pg_roles where rolname='authenticated')]::oid[]
          and coalesce(pg_get_expr(p.polqual,p.polrelid) ~ '^\(?(public\.)?is_app_admin\(\)\)?$',false)
          and coalesce(pg_get_expr(p.polwithcheck,p.polrelid) ~ '^\(?(public\.)?is_app_admin\(\)\)?$',false)
          and (select safe from admin_gate)
        )
    ) as passed,
    case when r.name='app_announcements'
      then 'SELECT policy exists; no client/public write or ALL policy except the admin_all policy of 006_announcements_admin (authenticated only, is_app_admin() for USING and WITH CHECK, closed admin list)'
      else 'SELECT policy exists; no client/public write or ALL policy' end as detail
  from required_tables r left join pg_class c on c.oid=to_regclass('public.'||r.name)
  where not r.private
), functions(name,signature) as (values
  ('cloud_lifecycle','public.cloud_lifecycle(text,uuid,jsonb)'),
  ('commit_cloud_project','public.commit_cloud_project(uuid,text,text,jsonb,bigint,timestamptz,boolean)'),
  ('delete_cloud_backup','public.delete_cloud_backup(uuid,text,text)'),
  ('legacy_upsert','public.upsert_cloud_project(uuid,text,text,jsonb,bigint)'),
  ('legacy_delete','public.delete_cloud_project(uuid,text)'),
  ('record_cleanup_pass','public.record_cloud_cleanup_pass(uuid,text,jsonb,text)'),
  ('cleanup_health','public.cloud_cleanup_health()')
), function_checks as (
  select 'rpc_permissions:'||f.name as check_name,
    p.oid is not null and p.prosecdef
      and has_function_privilege('service_role',p.oid,'EXECUTE')
      and not has_function_privilege('anon',p.oid,'EXECUTE')
      and not has_function_privilege('authenticated',p.oid,'EXECUTE') as passed,
    'security definer; service role only' as detail
  from functions f left join pg_proc p on p.oid=to_regprocedure(f.signature)
), additional_checks as (
  select 'leased_commit_wrapper' as check_name, coalesce((
    select position('cloud_object_leases' in pg_get_functiondef(p.oid))>0
      and position('pg_advisory_xact_lock' in pg_get_functiondef(p.oid))>0
    from pg_proc p where p.oid=to_regprocedure('public.commit_cloud_project(uuid,text,text,jsonb,bigint,timestamptz,boolean)')
  ),false) as passed, 'published commit checks lease under account lock' as detail
  union all
  select 'unleased_alias_closed', coalesce((
    select not has_function_privilege('service_role',p.oid,'EXECUTE')
      and not has_function_privilege('anon',p.oid,'EXECUTE')
      and not has_function_privilege('authenticated',p.oid,'EXECUTE')
    from pg_proc p where p.oid=to_regprocedure('public.commit_cloud_project_unleased(uuid,text,text,jsonb,bigint,timestamptz,boolean)')
  ),false), 'old unleased implementation cannot be called by API roles'
  union all
  select 'auth_delete_trigger', exists(
    select 1 from pg_trigger t join pg_proc p on p.oid=t.tgfoid
    where t.tgrelid=to_regclass('auth.users') and t.tgname='humtrack_cloud_auth_delete'
      and t.tgenabled in ('O','A') and not t.tgisinternal
      and p.proname='cloud_auth_delete_tombstone' and p.prosecdef
  ), 'enabled Auth deletion trigger persists the cleanup request'
)
select * from table_checks union all select * from policy_checks
union all select * from function_checks union all select * from additional_checks
order by check_name;
