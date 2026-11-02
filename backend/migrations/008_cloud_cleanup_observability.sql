-- Operator-only aggregate health. Apply after 006/007; not applied to production.
-- No customer UUID/key/title is copied here. Worker UUIDs identify ephemeral processes.
create table if not exists public.cloud_cleanup_workers (
  worker_id uuid primary key,
  kind text not null check(kind in ('scheduled','manual')),
  started_at timestamptz not null,
  finished_at timestamptz,
  last_ok_at timestamptz,
  state text not null check(state in ('running','ok','error')),
  counts jsonb not null default '{}'
);
alter table public.cloud_cleanup_workers enable row level security;
revoke all on public.cloud_cleanup_workers from public,anon,authenticated;
grant select,insert,update,delete on public.cloud_cleanup_workers to service_role;

create or replace function public.record_cloud_cleanup_pass(
 p_worker_id uuid,p_state text,p_counts jsonb default '{}',p_kind text default 'scheduled')
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_now timestamptz:=clock_timestamp(); safe_counts jsonb:='{}'; k text;
begin
  if p_kind not in ('scheduled','manual') or p_state not in ('running','ok','error') then raise exception 'invalid worker state'; end if;
  foreach k in array array['accounts','objects','eligible','queued','deleted','failed','busy','auth_failed','errors'] loop
    if jsonb_typeof(p_counts->k)='number' then
      safe_counts:=safe_counts||jsonb_build_object(k,greatest(0,least(2147483647,(p_counts->>k)::numeric)));
    end if;
  end loop;
  if p_state='running' then
    insert into public.cloud_cleanup_workers(worker_id,kind,started_at,state)
      values(p_worker_id,p_kind,v_now,'running')
      on conflict(worker_id) do update set kind=p_kind,started_at=v_now,finished_at=null,state='running',counts='{}';
    -- Operational process rows only; customer deletion tombstones are NOT touched.
    delete from public.cloud_cleanup_workers where started_at<v_now-interval '7 days';
  else
    update public.cloud_cleanup_workers set finished_at=v_now,state=p_state,counts=safe_counts,
      last_ok_at=case when p_state='ok' then v_now else last_ok_at end
      where worker_id=p_worker_id and kind=p_kind and state='running';
    if not found then raise exception 'worker pass not started'; end if;
  end if;
  return jsonb_build_object('status','ok');
end $$;
revoke all on function public.record_cloud_cleanup_pass(uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.record_cloud_cleanup_pass(uuid,text,jsonb,text) to service_role;

create or replace function public.cloud_cleanup_health()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_now timestamptz:=now(); w public.cloud_cleanup_workers%rowtype;
  alerts jsonb:='[]'; pending_jobs bigint; old_jobs bigint; overdue_accounts bigint;
  auth_overdue bigint; purge_overdue bigint;
begin
  select * into w from public.cloud_cleanup_workers where kind='scheduled' order by started_at desc limit 1;
  if not found then alerts:=alerts||'"scheduled_worker_missing"'::jsonb;
  elsif w.state='error' then alerts:=alerts||'"worker_pass_failed"'::jsonb;
  elsif w.last_ok_at is null or w.last_ok_at<v_now-interval '5 minutes'
    or (w.state='running' and w.started_at<v_now-interval '2 minutes') then
    alerts:=alerts||'"scheduled_worker_stale"'::jsonb;
  end if;
  select count(*),count(*) filter(where created_at<v_now-interval '1 hour')
    into pending_jobs,old_jobs from public.cloud_delete_jobs;
  select count(*) filter(where next_sweep_at<v_now-interval '10 minutes'),
    count(*) filter(where delete_requested_at<v_now-interval '15 minutes' and auth_deleted_at is null),
    count(*) filter(where auth_deleted_at is not null and purged_at is null and purge_after<v_now-interval '15 minutes')
    into overdue_accounts,auth_overdue,purge_overdue from public.cloud_accounts;
  if old_jobs>0 then alerts:=alerts||'"delete_queue_old"'::jsonb; end if;
  if overdue_accounts>0 then alerts:=alerts||'"account_scans_overdue"'::jsonb; end if;
  if auth_overdue>0 then alerts:=alerts||'"auth_deletion_overdue"'::jsonb; end if;
  if purge_overdue>0 then alerts:=alerts||'"primary_purge_overdue"'::jsonb; end if;
  return jsonb_build_object('healthy',jsonb_array_length(alerts)=0,'alerts',alerts,
    'pending_delete_jobs',pending_jobs,'old_delete_jobs',old_jobs,'overdue_account_scans',overdue_accounts,
    'overdue_auth_deletions',auth_overdue,'overdue_primary_purges',purge_overdue,
    'worker_state',w.state,'last_started_at',w.started_at,'last_finished_at',w.finished_at,
    'last_ok_at',w.last_ok_at,'last_counts',coalesce(w.counts,'{}'));
end $$;
revoke all on function public.cloud_cleanup_health() from public,anon,authenticated;
grant execute on function public.cloud_cleanup_health() to service_role;
notify pgrst,'reload schema';
