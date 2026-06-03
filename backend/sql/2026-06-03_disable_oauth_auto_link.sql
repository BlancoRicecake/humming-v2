-- ─────────────────────────────────────────────────────────────────────
-- Supabase Auth: 동일 이메일 OAuth 자동 link 차단 (v3 — block 전략)
-- ─────────────────────────────────────────────────────────────────────
-- 전략 변경: 새 user 생성 대신 *명시적 차단*.
-- Google / GitHub / 대부분 SaaS 가 채택하는 업계 표준.
--
-- 동작:
--   BEFORE INSERT ON auth.identities
--   - 같은 user_id 에 *다른 provider* identity 가 이미 존재하면
--   → EXCEPTION raise → GoTrue 가 클라이언트에 에러 전달.
--   결과: 같은 이메일의 다른 provider 로그인은 차단됨.
--
-- UX:
--   - 사용자는 dialog 로 "이미 다른 방법으로 가입된 이메일입니다" 메시지를 봄
--   - 처음 가입했던 provider 로 로그인하라고 안내
--
-- 향후 동일 user 가 두 provider 를 link 하고 싶으면:
--   1. 첫 provider 로 로그인 (인증된 세션 확보)
--   2. 앱 안에서 명시적으로 supabase.auth.linkIdentity() 호출 (Manual Linking 토글 ON 필요)
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.prevent_oauth_auto_link()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_existing_provider text;
BEGIN
  -- OAuth provider 가 아닌 경우 skip.
  IF NEW.provider IN ('email', 'phone', 'anonymous') THEN
    RETURN NEW;
  END IF;

  -- 같은 user 에 *다른 provider* identity 가 이미 있나? 그렇다면 차단.
  SELECT provider INTO v_existing_provider
  FROM auth.identities
  WHERE user_id = NEW.user_id
    AND provider != NEW.provider
  LIMIT 1;

  IF v_existing_provider IS NOT NULL THEN
    RAISE EXCEPTION 'AUTO_LINK_DENIED: email already registered with provider=%', v_existing_provider
      USING ERRCODE = 'check_violation',
            HINT = 'Use the original provider to sign in, or link this identity explicitly via auth.linkIdentity().';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_oauth_auto_link_trigger ON auth.identities;

CREATE TRIGGER prevent_oauth_auto_link_trigger
BEFORE INSERT ON auth.identities
FOR EACH ROW
EXECUTE FUNCTION public.prevent_oauth_auto_link();

-- ─────────────────────────────────────────────────────────────────────
-- 검증
-- ─────────────────────────────────────────────────────────────────────
-- SELECT tgname, tgenabled FROM pg_trigger
-- WHERE tgrelid = 'auth.identities'::regclass
--   AND tgname = 'prevent_oauth_auto_link_trigger';
