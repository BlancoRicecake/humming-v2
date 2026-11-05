-- STAGING ONLY. Everything created/deleted below is uncommitted and rolled back.
-- Refuses any project that already has Auth users or cloud projects/accounts.
-- Exercises real PostgreSQL RPC/trigger/RLS, not Auth HTTP or R2 operations.
begin;
do $probe$
declare
  u uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid();
  up1 text; bk1 text; up2 text; bk2 text; up3 text; bk3 text;
  result jsonb; first_time timestamptz; n integer;
begin
  if exists(select 1 from auth.users) or exists(select 1 from public.cloud_projects)
    or exists(select 1 from public.cloud_accounts) then
    raise exception 'Empty isolated staging required';
  end if;
  insert into auth.users(id) values(u),(b),(c);
  perform set_config('qa.uid_b',b::text,true);
  result:=public.cloud_lifecycle('ensure',u,'{}');
  if result->>'status'<>'ok' then raise exception 'ensure failed'; end if;
  up1:='vocals/'||u||'/qa_song/up-'||replace(gen_random_uuid()::text,'-','')||'.humtrack';
  bk1:='vocals/'||u||'/qa_song/bk-'||replace(gen_random_uuid()::text,'-','')||'.humtrack';
  perform public.cloud_lifecycle('upload',u,jsonb_build_object('project_id','qa_song','key',up1,'ttl',600));
  perform public.cloud_lifecycle('begin_commit',u,jsonb_build_object('project_id','qa_song','source',up1,'key',bk1));
  result:=public.commit_cloud_project(u,'qa_song','Synthetic QA',jsonb_build_object('key',bk1),10,null,true);
  if result->>'status'<>'ok' then raise exception 'first commit failed'; end if;
  first_time:=(result->>'updated_at')::timestamptz;
  result:=public.cloud_lifecycle('queue',u,jsonb_build_object('keys',jsonb_build_array(bk1),'reason','orphan'));
  if jsonb_array_length(result->'keys')<>0 then raise exception 'current copy was queued'; end if;
  up2:='vocals/'||u||'/qa_song/up-'||replace(gen_random_uuid()::text,'-','')||'.humtrack';
  bk2:='vocals/'||u||'/qa_song/bk-'||replace(gen_random_uuid()::text,'-','')||'.humtrack';
  perform public.cloud_lifecycle('upload',u,jsonb_build_object('project_id','qa_song','key',up2,'ttl',600));
  perform public.cloud_lifecycle('begin_commit',u,jsonb_build_object('project_id','qa_song','source',up2,'key',bk2));
  result:=public.cloud_lifecycle('queue',u,jsonb_build_object('keys',jsonb_build_array(bk2),'reason','orphan'));
  if jsonb_array_length(result->'keys')<>0 then raise exception 'pending copy was queued'; end if;
  result:=public.commit_cloud_project(u,'qa_song','Replacement QA',jsonb_build_object('key',bk2),20,first_time,false);
  if result->>'status'<>'ok' then raise exception 'replacement failed'; end if;
  up3:='vocals/'||u||'/qa_song/up-'||replace(gen_random_uuid()::text,'-','')||'.humtrack';
  bk3:='vocals/'||u||'/qa_song/bk-'||replace(gen_random_uuid()::text,'-','')||'.humtrack';
  perform public.cloud_lifecycle('upload',u,jsonb_build_object('project_id','qa_song','key',up3,'ttl',600));
  perform public.cloud_lifecycle('begin_commit',u,jsonb_build_object('project_id','qa_song','source',up3,'key',bk3));
  result:=public.commit_cloud_project(u,'qa_song','Stale QA',jsonb_build_object('key',bk3),30,first_time,false);
  if result->>'status'<>'conflict' or (select meta->>'key' from public.cloud_projects where user_id=u and project_id='qa_song')<>bk2 then
    raise exception 'stale conflict did not preserve current copy';
  end if;
  result:=public.cloud_lifecycle('queue',u,jsonb_build_object('keys',jsonb_build_array(bk3),'reason','orphan'));
  if jsonb_array_length(result->'keys')<>1 then raise exception 'failed copy not queued'; end if;
  result:=public.cloud_lifecycle('claim_deletes',u,jsonb_build_object('keys',jsonb_build_array(bk3),'token','qa-worker-a'));
  if jsonb_array_length(result->'keys')<>1 then raise exception 'first claim failed'; end if;
  result:=public.cloud_lifecycle('claim_deletes',u,jsonb_build_object('keys',jsonb_build_array(bk3),'token','qa-worker-b'));
  if jsonb_array_length(result->'keys')<>0 then raise exception 'worker claim not fenced'; end if;
  perform public.cloud_lifecycle('finish_delete',u,jsonb_build_object('key',bk3,'token','qa-worker-a','ok',false));
  if (select attempts from public.cloud_delete_jobs where object_key=bk3)<>1 then raise exception 'retry not durable'; end if;
  delete from auth.users where id=u;
  if not exists(select 1 from public.cloud_accounts where user_id=u and auth_deleted_at is not null and delete_requested_at is not null) then raise exception 'Auth tombstone absent'; end if;
  if not exists(select 1 from public.cloud_delete_jobs where object_key=bk3) then raise exception 'queue lost after Auth cascade'; end if;
  result:=public.cloud_lifecycle('ensure',u,'{}');
  if result->>'status'<>'account_deleting' then raise exception 'deleted account can act'; end if;
  insert into public.cloud_projects(user_id,project_id,title,meta) values(b,'qa_owner','Owner QA','{}'),(c,'qa_other','Other QA','{}');
  insert into public.app_announcements(id,kind,title_ko,title_en,body_ko,body_en,published,starts_at)
    values('qa_live','info','QA','QA','QA','QA',true,now()-interval '1 hour'),
          ('qa_draft','info','QA','QA','QA','QA',false,now()-interval '1 hour'),
          ('qa_future','info','QA','QA','QA','QA',true,now()+interval '1 day');
  update public.app_announcements set body_en='QA revision' where id='qa_live';
  if (select revision from public.app_announcements where id='qa_live')<>2 then raise exception 'revision trigger failed'; end if;
end $probe$;
set local role anon;
do $anon$
begin
  begin
    perform public.cloud_lifecycle('ensure',gen_random_uuid(),'{}');
    raise exception 'anon RPC was allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform 1 from public.cloud_delete_jobs;
    raise exception 'anon private queue read was allowed';
  exception when insufficient_privilege then null; end;
  if (select count(*) from public.app_announcements)<>1 then raise exception 'draft/future notice leaked'; end if;
end $anon$;
reset role;
select set_config('request.jwt.claim.sub',current_setting('qa.uid_b'),true);
set local role authenticated;
do $owner$
declare affected integer;
begin
  if (select count(*) from public.cloud_projects)<>1 then raise exception 'cross-account rows visible'; end if;
  update public.cloud_projects set title='Client mutation';
  get diagnostics affected=row_count;
  if affected<>0 then raise exception 'client can mutate cloud rows'; end if;
end $owner$;
reset role;
rollback;
select true as transaction_probe_passed,
       (select count(*) from auth.users) as auth_users_after_rollback,
       (select count(*) from public.cloud_projects) as projects_after_rollback,
       (select count(*) from public.cloud_accounts) as accounts_after_rollback,
       (select count(*) from public.cloud_delete_jobs) as jobs_after_rollback,
       (select count(*) from public.app_announcements) as announcements_after_rollback;
