-- ─────────────────────────────────────────────────────────────────────────────
-- HumTrack — Cloud Sync schema (2026-06-04)
--
-- 적용 방법:
--   1. Supabase Dashboard → SQL Editor → New Query
--   2. 본 파일 전체 붙여넣기 → "Run"
--   3. Database → Tables 에서 `public.cloud_projects`, `public.cloud_quota` 확인
--   4. Database → Functions 에서 `upsert_cloud_project`, `delete_cloud_project` 확인
--
-- 멱등 (idempotent): 여러 번 실행해도 안전.
--
-- 롤백 (필요 시 — 아래를 SQL Editor 에서 실행):
--   DROP FUNCTION IF EXISTS public.delete_cloud_project(uuid, text);
--   DROP FUNCTION IF EXISTS public.upsert_cloud_project(uuid, text, text, jsonb, bigint);
--   DROP TABLE IF EXISTS public.cloud_projects;
--   DROP TABLE IF EXISTS public.cloud_quota;
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1) cloud_projects: 사용자 클라우드 프로젝트 메타 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.cloud_projects (
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  project_id   text NOT NULL,
  title        text NOT NULL,
  size_bytes   bigint NOT NULL DEFAULT 0,
  meta         jsonb NOT NULL,
  uploaded_at  timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, project_id)
);

CREATE INDEX IF NOT EXISTS idx_cloud_projects_user_updated
  ON public.cloud_projects(user_id, updated_at DESC);

-- ── 2) cloud_quota: 사용자별 누적 사용량 ────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cloud_quota (
  user_id     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  used_bytes  bigint NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ── 3) RLS: 본인 row 만 ─────────────────────────────────────────────────────
ALTER TABLE public.cloud_projects ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own_cloud_projects" ON public.cloud_projects;
CREATE POLICY "own_cloud_projects" ON public.cloud_projects
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

ALTER TABLE public.cloud_quota ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own_cloud_quota" ON public.cloud_quota;
CREATE POLICY "own_cloud_quota" ON public.cloud_quota
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ── 4) 원자적 upsert + quota 증감 ───────────────────────────────────────────
-- 백엔드 서비스 role 로 호출 (RLS bypass). user_id 명시 인자로 전달 — 이중 안전.
CREATE OR REPLACE FUNCTION public.upsert_cloud_project(
  p_user_id    uuid,
  p_project_id text,
  p_title      text,
  p_meta       jsonb,
  p_size_bytes bigint
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_old_size bigint;
  v_new_used bigint;
BEGIN
  SELECT size_bytes INTO v_old_size
  FROM cloud_projects
  WHERE user_id = p_user_id AND project_id = p_project_id;
  IF v_old_size IS NULL THEN v_old_size := 0; END IF;

  INSERT INTO cloud_projects (user_id, project_id, title, meta, size_bytes, updated_at)
  VALUES (p_user_id, p_project_id, p_title, p_meta, p_size_bytes, now())
  ON CONFLICT (user_id, project_id) DO UPDATE SET
    title      = EXCLUDED.title,
    meta       = EXCLUDED.meta,
    size_bytes = EXCLUDED.size_bytes,
    updated_at = now();

  INSERT INTO cloud_quota (user_id, used_bytes)
  VALUES (p_user_id, GREATEST(0, p_size_bytes - v_old_size))
  ON CONFLICT (user_id) DO UPDATE SET
    used_bytes = GREATEST(0, cloud_quota.used_bytes + (p_size_bytes - v_old_size)),
    updated_at = now()
  RETURNING used_bytes INTO v_new_used;

  RETURN v_new_used;
END $$;

-- ── 5) 원자적 delete + quota 감소 ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.delete_cloud_project(
  p_user_id    uuid,
  p_project_id text
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_size bigint;
  v_new_used bigint;
BEGIN
  DELETE FROM cloud_projects
  WHERE user_id = p_user_id AND project_id = p_project_id
  RETURNING size_bytes INTO v_size;

  IF v_size IS NULL THEN
    RETURN NULL;  -- 존재하지 않음
  END IF;

  UPDATE cloud_quota
  SET used_bytes = GREATEST(0, used_bytes - v_size), updated_at = now()
  WHERE user_id = p_user_id
  RETURNING used_bytes INTO v_new_used;

  IF v_new_used IS NULL THEN
    v_new_used := 0;
  END IF;

  RETURN v_new_used;
END $$;

-- ── 6) 권한 — anon 은 직접 호출 차단, authenticated 만 RPC 가능 ─────────────
REVOKE ALL ON FUNCTION public.upsert_cloud_project(uuid, text, text, jsonb, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_cloud_project(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_cloud_project(uuid, text, text, jsonb, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.delete_cloud_project(uuid, text) TO service_role;
