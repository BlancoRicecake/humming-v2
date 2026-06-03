-- ─────────────────────────────────────────────────────────────────────
-- Supabase RPC: 이메일로 가입된 provider 목록 조회
-- ─────────────────────────────────────────────────────────────────────
-- 용도:
--   prevent_oauth_auto_link trigger 가 차단했을 때, 클라이언트가
--   "어느 provider 로 처음 가입했는지" 정확히 안내할 수 있도록 하는 lookup.
--
-- 보안 고려:
--   - SECURITY DEFINER 로 auth 스키마 접근 (anon role 은 직접 못 봄)
--   - email enumeration 위험은 존재. 완화책:
--     a) Supabase 의 기본 rate limit (IP 당 분당 호출 제한)
--     b) 클라이언트는 *OAuth 시도 실패 직후에만* 호출 (UX 흐름상 제약)
--     c) 미래에 captcha / 추가 인증 가능
--
-- 응답:
--   text[] — 등록된 provider 이름 배열. 예: {'apple'}, {'google','apple'}
--   해당 이메일이 없으면 NULL 또는 빈 배열.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.providers_for_email(target_email text)
RETURNS text[]
LANGUAGE sql
SECURITY DEFINER
SET search_path = auth, public
AS $$
  SELECT array_agg(DISTINCT i.provider ORDER BY i.provider)
  FROM auth.identities i
  JOIN auth.users u ON u.id = i.user_id
  WHERE lower(u.email) = lower(target_email)
    AND i.provider NOT IN ('email', 'phone', 'anonymous');
$$;

-- anon 과 authenticated 두 role 모두 호출 가능 (로그인 전 단계라 anon 필요).
REVOKE ALL ON FUNCTION public.providers_for_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.providers_for_email(text) TO anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- 검증
-- ─────────────────────────────────────────────────────────────────────
-- SELECT public.providers_for_email('heowjdals981227@gmail.com');
-- → 예상: {apple}
