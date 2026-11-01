-- ─────────────────────────────────────────────────────────────────────────────
-- HumTrack — Cloud Sync: clients read, only the backend writes (2026-10-13)
--
-- 2026-06-04 스키마의 RLS 정책은 FOR ALL 이라, 로그인한 사용자가 앱에 들어 있는
-- anon key 로 Supabase REST 를 직접 불러 자기 cloud_projects 행을 만들거나
-- cloud_quota.used_bytes 를 0 으로 바꿀 수 있다. 서버의 Pro 확인·용량 실측(B7)을
-- 우회하는 길이므로, 사용자에게는 읽기만 남긴다. 백엔드는 service role 이라
-- RLS 를 거치지 않으므로 영향 없음.
--
-- 적용: Supabase Dashboard → SQL Editor → 본 파일 전체 실행. 멱등.
-- 확인: Authentication → Policies 에서 두 테이블에 SELECT 정책만 남았는지.
--
-- 롤백:
--   DROP POLICY IF EXISTS "read_own_cloud_projects" ON public.cloud_projects;
--   DROP POLICY IF EXISTS "read_own_cloud_quota" ON public.cloud_quota;
--   (그다음 2026-06-04_cloud_sync_schema.sql 의 3) 절 재실행)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "own_cloud_projects" ON public.cloud_projects;
DROP POLICY IF EXISTS "read_own_cloud_projects" ON public.cloud_projects;
CREATE POLICY "read_own_cloud_projects" ON public.cloud_projects
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "own_cloud_quota" ON public.cloud_quota;
DROP POLICY IF EXISTS "read_own_cloud_quota" ON public.cloud_quota;
CREATE POLICY "read_own_cloud_quota" ON public.cloud_quota
  FOR SELECT USING (auth.uid() = user_id);
