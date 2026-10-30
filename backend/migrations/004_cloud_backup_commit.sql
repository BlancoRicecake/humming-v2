-- 004 — cloud backup commit: switch a song's cloud copy atomically (2026-10-30)
--
-- NOT APPLIED to any environment. Apply only together with the backend that
-- calls it (backup contract 1), before CLOUD_SYNC_ENABLED is turned on.
-- Requires backend/sql/2026-06-04_cloud_sync_schema.sql and migration 003.
--
-- Why: POST /projects used to read updated_at, compare it in Python, then
-- upsert — two devices could both pass the check and the later write would
-- silently replace the other's backup. This function locks the row, compares
-- and writes in one transaction:
--   * row exists  → update only if p_expected_updated_at matches (and the
--                   caller did not claim "first upload"); else conflict.
--   * row missing → insert only for a first upload (p_expect_absent); a
--                   concurrent first upload loses on the primary key and gets
--                   a conflict instead of an error.
-- The previous meta comes back so the backend deletes exactly the object the
-- new row replaced. cloud_quota is NOT touched here: the backend records the
-- usage it measured in R2.
--
-- delete_cloud_backup removes the row only if it still points at the copy
-- the backend just deleted from R2 (a new copy committed meanwhile by another
-- device stays). Codex review C2/C3, 2026-10-30.
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.commit_cloud_project(uuid, text, text, jsonb, bigint, timestamptz, boolean);
--   DROP FUNCTION IF EXISTS public.delete_cloud_backup(uuid, text, text);

create or replace function public.commit_cloud_project(
  p_user_id             uuid,
  p_project_id          text,
  p_title               text,
  p_meta                jsonb,
  p_size_bytes          bigint,
  p_expected_updated_at timestamptz,
  p_expect_absent       boolean
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.cloud_projects%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  select * into v_row
  from public.cloud_projects
  where user_id = p_user_id and project_id = p_project_id
  for update;

  if found then
    if p_expect_absent
       or p_expected_updated_at is null
       or v_row.updated_at <> p_expected_updated_at then
      return jsonb_build_object(
        'status', 'conflict',
        'current', jsonb_build_object(
          'title', v_row.title,
          'size_bytes', v_row.size_bytes,
          'updated_at', v_row.updated_at,
          'meta', v_row.meta));
    end if;
    update public.cloud_projects
       set title = p_title, meta = p_meta, size_bytes = p_size_bytes,
           updated_at = v_now
     where user_id = p_user_id and project_id = p_project_id;
    return jsonb_build_object('status', 'ok', 'updated_at', v_now,
                              'previous_meta', v_row.meta);
  end if;

  if not coalesce(p_expect_absent, false) then
    -- the copy this device knew was deleted elsewhere
    return jsonb_build_object('status', 'conflict', 'current', null);
  end if;

  begin
    insert into public.cloud_projects
      (user_id, project_id, title, meta, size_bytes, uploaded_at, updated_at)
    values (p_user_id, p_project_id, p_title, p_meta, p_size_bytes, v_now, v_now);
  exception when unique_violation then
    select * into v_row from public.cloud_projects
     where user_id = p_user_id and project_id = p_project_id;
    return jsonb_build_object(
      'status', 'conflict',
      'current', jsonb_build_object(
        'title', v_row.title,
        'size_bytes', v_row.size_bytes,
        'updated_at', v_row.updated_at,
        'meta', v_row.meta));
  end;
  return jsonb_build_object('status', 'ok', 'updated_at', v_now,
                            'previous_meta', null);
end $$;

revoke all on function public.commit_cloud_project(uuid, text, text, jsonb, bigint, timestamptz, boolean) from public;
revoke all on function public.commit_cloud_project(uuid, text, text, jsonb, bigint, timestamptz, boolean) from anon, authenticated;
grant execute on function public.commit_cloud_project(uuid, text, text, jsonb, bigint, timestamptz, boolean) to service_role;

create or replace function public.delete_cloud_backup(
  p_user_id      uuid,
  p_project_id   text,
  p_expected_key text
) returns text  -- 'deleted' | 'changed' | 'absent'
language plpgsql security definer set search_path = public
as $$
declare
  v_key text;
begin
  select meta->>'key' into v_key
  from public.cloud_projects
  where user_id = p_user_id and project_id = p_project_id
  for update;
  if not found then
    return 'absent';
  end if;
  if v_key is distinct from p_expected_key then
    return 'changed';
  end if;
  delete from public.cloud_projects
   where user_id = p_user_id and project_id = p_project_id;
  return 'deleted';
end $$;

revoke all on function public.delete_cloud_backup(uuid, text, text) from public;
revoke all on function public.delete_cloud_backup(uuid, text, text) from anon, authenticated;
grant execute on function public.delete_cloud_backup(uuid, text, text) to service_role;
