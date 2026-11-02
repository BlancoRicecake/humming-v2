-- Durable cleanup + account-deletion fence. Applied to isolated staging on
-- 2026-11-01; not to the production Supabase project.
-- Apply after 003/004, before deploying the lifecycle-aware backend.
-- No FK to auth.users: deletion requests/jobs must outlive Auth deletion.

create table if not exists public.cloud_accounts (
  user_id uuid primary key,
  delete_requested_at timestamptz,
  auth_deleted_at timestamptz,
  purge_after timestamptz,
  purged_at timestamptz,
  last_upload_expires_at timestamptz,
  auth_attempts integer not null default 0,
  auth_retry_at timestamptz not null default now(),
  next_sweep_at timestamptz not null default now(),
  scan_cursor text,
  claim_token text,
  claim_until timestamptz
);
create table if not exists public.cloud_object_leases (
  object_key text primary key,
  user_id uuid not null references public.cloud_accounts(user_id),
  project_id text not null,
  state text not null check (state in ('upload','pending','committed','deleting')),
  lease_until timestamptz not null,
  source_key text,
  created_at timestamptz not null default now()
);
create index if not exists cloud_leases_source on public.cloud_object_leases(source_key);
create table if not exists public.cloud_delete_jobs (
  object_key text primary key,
  user_id uuid not null references public.cloud_accounts(user_id),
  project_id text not null,
  reason text not null,
  expected_key text,
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  claim_token text,
  claim_until timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);
create index if not exists cloud_delete_due on public.cloud_delete_jobs(next_attempt_at);
create index if not exists cloud_accounts_due on public.cloud_accounts(next_sweep_at);

-- Existing tracked accounts also need a scheduled scan without opening the
-- app again. Keep unknown bucket prefixes/formats for operator inventory.
insert into public.cloud_accounts(user_id)
  select user_id from public.cloud_projects union select user_id from public.cloud_quota
  on conflict(user_id) do nothing;

alter table public.cloud_accounts enable row level security;
alter table public.cloud_object_leases enable row level security;
alter table public.cloud_delete_jobs enable row level security;
revoke all on public.cloud_accounts, public.cloud_object_leases, public.cloud_delete_jobs from public, anon, authenticated;
grant select, insert, update, delete on public.cloud_accounts, public.cloud_object_leases, public.cloud_delete_jobs to service_role;

-- Also cover Auth deletion outside this backend (and rolling deployments of
-- the old route). The tombstone commits in the SAME transaction as Auth/FK
-- deletion, so a rollback leaves neither a fake success nor a lost request.
create or replace function public.cloud_auth_delete_tombstone()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_now timestamptz := clock_timestamp();
begin
  perform pg_advisory_xact_lock(hashtextextended('humtrack-cloud:'||old.id::text,0));
  insert into public.cloud_accounts(user_id,delete_requested_at,auth_deleted_at,purge_after)
    values(old.id,v_now,v_now,v_now+interval '5 minutes')
    on conflict(user_id) do update set
      delete_requested_at=coalesce(cloud_accounts.delete_requested_at,v_now),
      auth_deleted_at=coalesce(cloud_accounts.auth_deleted_at,v_now),
      purge_after=coalesce(cloud_accounts.purge_after,greatest(cloud_accounts.last_upload_expires_at,v_now)+interval '5 minutes'),
      next_sweep_at=least(cloud_accounts.next_sweep_at,v_now);
  return old;
end $$;
revoke all on function public.cloud_auth_delete_tombstone() from public,anon,authenticated,service_role;
drop trigger if exists humtrack_cloud_auth_delete on auth.users;
create trigger humtrack_cloud_auth_delete before delete on auth.users
  for each row execute function public.cloud_auth_delete_tombstone();

-- All decisions for an account share the same transaction lock, including
-- commit publication and GC fencing. No lock is held across an R2 call.
create or replace function public.cloud_lifecycle(p_action text, p_user_id uuid, p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a public.cloud_accounts%rowtype;
  l public.cloud_object_leases%rowtype;
  j public.cloud_delete_jobs%rowtype;
  k text; pid text; current_key text;
  until_at timestamptz;
  v_now timestamptz := clock_timestamp();
  result jsonb := '[]';
  token text := p_payload->>'token';
  reason text := p_payload->>'reason';
  expected text := p_payload->>'expected_key';
begin
  perform pg_advisory_xact_lock(hashtextextended('humtrack-cloud:' || p_user_id::text, 0));
  select * into a from public.cloud_accounts where user_id=p_user_id for update;
  if not found then
    if p_action not in ('ensure','upload','request_delete') then
      return jsonb_build_object('status','missing');
    end if;
    if p_action <> 'request_delete' and not exists(select 1 from auth.users where id=p_user_id) then
      return jsonb_build_object('status','gone');
    end if;
    insert into public.cloud_accounts(user_id) values(p_user_id) returning * into a;
  end if;
  if p_action in ('ensure','upload','begin_commit') then
    if a.delete_requested_at is not null or not exists(select 1 from auth.users where id=p_user_id) then
      return jsonb_build_object('status','account_deleting');
    end if;
  end if;
  if p_action='ensure' then return jsonb_build_object('status','ok'); end if;

  if p_action='upload' then
    k:=p_payload->>'key'; pid:=p_payload->>'project_id';
    if pid !~ '^[A-Za-z0-9_-]{1,100}$' or k !~ ('^vocals/'||p_user_id||'/'||pid||'/up-[0-9a-f]{32}\.humtrack$') then
      raise exception 'invalid upload key';
    end if;
    if (p_payload->>'ttl')::integer not between 1 and 3600 then raise exception 'invalid URL TTL'; end if;
    until_at:=v_now+make_interval(secs => (p_payload->>'ttl')::integer);
    insert into public.cloud_object_leases(object_key,user_id,project_id,state,lease_until)
      values(k,p_user_id,pid,'upload',greatest(v_now+interval '24 hours',until_at+interval '10 minutes'));
    update public.cloud_accounts set last_upload_expires_at=greatest(last_upload_expires_at,until_at),
      next_sweep_at=least(next_sweep_at,v_now+interval '1 hour') where user_id=p_user_id;
    return jsonb_build_object('status','ok');
  elsif p_action='begin_commit' then
    k:=p_payload->>'source'; pid:=p_payload->>'project_id';
    select * into l from public.cloud_object_leases where object_key=k and user_id=p_user_id and project_id=pid for update;
    if not found or l.state<>'upload' or l.lease_until<=v_now then
      return jsonb_build_object('status','upload_expired');
    end if;
    k:=p_payload->>'key';
    if k !~ ('^vocals/'||p_user_id||'/'||pid||'/bk-[0-9a-f]{32}\.humtrack$') then raise exception 'invalid backup key'; end if;
    until_at:=v_now+interval '10 minutes';
    insert into public.cloud_object_leases(object_key,user_id,project_id,state,lease_until,source_key)
      values(k,p_user_id,pid,'pending',until_at,p_payload->>'source');
    update public.cloud_object_leases set lease_until=greatest(lease_until,until_at)
      where object_key=p_payload->>'source';
    return jsonb_build_object('status','ok');
  elsif p_action='cancel_copy' then
    update public.cloud_object_leases set state='upload',lease_until=v_now
      where object_key=p_payload->>'key' and user_id=p_user_id and state='pending';
    return jsonb_build_object('status','ok');
  elsif p_action='request_delete' then
    update public.cloud_accounts set delete_requested_at=coalesce(delete_requested_at,v_now),
      purge_after=coalesce(purge_after,greatest(last_upload_expires_at,v_now)+interval '5 minutes'),
      next_sweep_at=least(next_sweep_at,v_now), auth_retry_at=least(auth_retry_at,v_now)
      where user_id=p_user_id;
    return jsonb_build_object('status','deletion_pending');
  elsif p_action='queue' then
    if jsonb_array_length(p_payload->'keys')>500 then raise exception 'too many keys'; end if;
    if reason not in ('orphan','post_commit','failed_commit','project_delete','account_delete') then raise exception 'invalid reason'; end if;
    pid:=p_payload->>'project_id';
    if reason='project_delete' and expected is not null then
      select meta->>'key' into current_key from public.cloud_projects where user_id=p_user_id and project_id=pid;
      if current_key is not null and current_key is distinct from expected then
        return jsonb_build_object('status','changed','keys','[]'::jsonb);
      end if;
    end if;
    for k in select jsonb_array_elements_text(p_payload->'keys') loop
      if not starts_with(k,'vocals/'||p_user_id||'/') then raise exception 'key outside account'; end if;
      pid:=split_part(k,'/',3);
      if a.delete_requested_at is null and exists(
        select 1 from public.cloud_projects where user_id=p_user_id and meta->>'key'=k
      ) and not (reason='project_delete' and k=expected) then continue; end if;
      select * into l from public.cloud_object_leases where object_key=k for update;
      if a.delete_requested_at is null and found and l.lease_until>v_now and l.state in ('upload','pending') then
        if l.state='pending' or reason not in ('post_commit','project_delete') or exists(
          select 1 from public.cloud_object_leases where source_key=k and state='pending' and lease_until>v_now
        ) then continue; end if;
      end if;
      if coalesce((p_payload->>'dry_run')::boolean,false) then
        result:=result||jsonb_build_array(k);
        continue;
      end if;
      insert into public.cloud_object_leases(object_key,user_id,project_id,state,lease_until)
        values(k,p_user_id,pid,'deleting',v_now)
        on conflict(object_key) do update set state='deleting',lease_until=v_now;
      insert into public.cloud_delete_jobs(object_key,user_id,project_id,reason,expected_key)
        values(k,p_user_id,pid,reason,case when reason='project_delete' and k=expected then expected else null end)
        on conflict(object_key) do nothing;
      result:=result||jsonb_build_array(k);
    end loop;
    return jsonb_build_object('status','ok','keys',result);
  elsif p_action='claim_deletes' then
    for j in select * from public.cloud_delete_jobs where user_id=p_user_id
      and object_key in (select jsonb_array_elements_text(p_payload->'keys'))
      and (next_attempt_at<=v_now or coalesce((p_payload->>'force_retry')::boolean,false))
      and (claim_until is null or claim_until<=v_now)
      order by next_attempt_at limit 500 for update skip locked loop
      update public.cloud_delete_jobs set claim_token=token,claim_until=v_now+interval '2 minutes' where object_key=j.object_key;
      result:=result||jsonb_build_array(j.object_key);
    end loop;
    return jsonb_build_object('status','ok','keys',result);
  elsif p_action='finish_delete' then
    k:=p_payload->>'key';
    select * into j from public.cloud_delete_jobs where object_key=k and user_id=p_user_id and claim_token=token for update;
    if not found then return jsonb_build_object('status','stale_worker'); end if;
    if (p_payload->>'ok')::boolean then
      if j.expected_key is not null then
        perform public.delete_cloud_backup(p_user_id,j.project_id,j.expected_key);
      end if;
      delete from public.cloud_delete_jobs where object_key=k;
      delete from public.cloud_object_leases where object_key=k and state='deleting';
    else
      update public.cloud_delete_jobs set attempts=attempts+1,
        next_attempt_at=v_now+make_interval(secs => least(3600,30*(2^least(attempts,7)))::integer),
        claim_token=null,claim_until=null,last_error='storage_delete_failed' where object_key=k;
    end if;
    return jsonb_build_object('status','ok');
  elsif p_action='claim_account' then
    if a.next_sweep_at>v_now or a.claim_until>v_now then return jsonb_build_object('status','busy'); end if;
    update public.cloud_accounts set claim_token=token,claim_until=v_now+interval '2 minutes' where user_id=p_user_id;
    return jsonb_build_object('status','ok');
  elsif p_action='auth_result' then
    if a.claim_token is distinct from token then return jsonb_build_object('status','stale_worker'); end if;
    update public.cloud_accounts set auth_deleted_at=case when (p_payload->>'ok')::boolean then coalesce(auth_deleted_at,v_now) else auth_deleted_at end,
      auth_attempts=auth_attempts+1,auth_retry_at=v_now+make_interval(secs => least(3600,30*(2^least(auth_attempts,7)))::integer)
      where user_id=p_user_id;
    return jsonb_build_object('status','ok');
  elsif p_action='finish_scan' then
    if a.claim_token is distinct from token then return jsonb_build_object('status','stale_worker'); end if;
    update public.cloud_accounts set scan_cursor=p_payload->>'cursor',
      purged_at=case when coalesce((p_payload->>'has_objects')::boolean,false) then null
        when coalesce((p_payload->>'complete')::boolean,false) and auth_deleted_at is not null
        and purge_after<=v_now and not exists(select 1 from public.cloud_delete_jobs where user_id=p_user_id)
        then v_now else purged_at end,
      next_sweep_at=v_now+make_interval(secs => greatest(1,least(86400,(p_payload->>'delay')::integer))),
      claim_token=null,claim_until=null where user_id=p_user_id;
    -- Once Auth is gone and the worker confirms an empty prefix after the URL
    -- expiry/grace boundary, filename-level leases serve no further purpose.
    -- Keep only the account tombstone for daily late-upload audits. A missing
    -- lease still rejects publication, even if a very late copy finishes.
    if a.delete_requested_at is not null and a.auth_deleted_at is not null
       and a.purge_after<=v_now
       and coalesce((p_payload->>'complete')::boolean,false)
       and not coalesce((p_payload->>'has_objects')::boolean,false)
       and not exists(select 1 from public.cloud_delete_jobs where user_id=p_user_id) then
      delete from public.cloud_object_leases where user_id=p_user_id;
    end if;
    return jsonb_build_object('status','ok');
  end if;
  raise exception 'unknown lifecycle action';
end $$;
revoke all on function public.cloud_lifecycle(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.cloud_lifecycle(text,uuid,jsonb) to service_role;

-- Preserve the proven CAS implementation, but make its only entry point
-- validate the finite copy lease under the SAME account lock used by GC.
do $$ begin
  if to_regprocedure('public.commit_cloud_project_unleased(uuid,text,text,jsonb,bigint,timestamptz,boolean)') is null then
    alter function public.commit_cloud_project(uuid,text,text,jsonb,bigint,timestamptz,boolean) rename to commit_cloud_project_unleased;
  end if;
end $$;
revoke all on function public.commit_cloud_project_unleased(uuid,text,text,jsonb,bigint,timestamptz,boolean) from public,anon,authenticated,service_role;
create or replace function public.commit_cloud_project(
 p_user_id uuid,p_project_id text,p_title text,p_meta jsonb,p_size_bytes bigint,
 p_expected_updated_at timestamptz,p_expect_absent boolean
) returns jsonb language plpgsql security definer set search_path=public as $$
declare r jsonb; l public.cloud_object_leases%rowtype;
begin
 perform pg_advisory_xact_lock(hashtextextended('humtrack-cloud:'||p_user_id::text,0));
 if exists(select 1 from public.cloud_accounts where user_id=p_user_id and delete_requested_at is not null)
   or not exists(select 1 from auth.users where id=p_user_id) then
   return jsonb_build_object('status','account_deleting');
 end if;
 select * into l from public.cloud_object_leases where object_key=p_meta->>'key'
   and user_id=p_user_id and project_id=p_project_id for update;
 if not found or l.state<>'pending' or l.lease_until<=clock_timestamp() then
   return jsonb_build_object('status','upload_expired');
 end if;
 r:=public.commit_cloud_project_unleased(p_user_id,p_project_id,p_title,p_meta,p_size_bytes,p_expected_updated_at,p_expect_absent);
 update public.cloud_object_leases set state=case when r->>'status'='ok' then 'committed' else 'upload' end,
   lease_until=clock_timestamp() where object_key=p_meta->>'key';
 return r;
end $$;
revoke all on function public.commit_cloud_project(uuid,text,text,jsonb,bigint,timestamptz,boolean) from public,anon,authenticated;
grant execute on function public.commit_cloud_project(uuid,text,text,jsonb,bigint,timestamptz,boolean) to service_role;

-- Let PostgREST discover the new RPC after this migration commits.
notify pgrst, 'reload schema';
