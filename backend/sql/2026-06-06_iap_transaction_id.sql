-- ─────────────────────────────────────────────────────────────────────────────
-- HumTrack — IAP transaction_id 컬럼 추가 (2026-06-06)
--
-- 적용 방법:
--   1. Supabase Dashboard → SQL Editor → New Query
--   2. 본 파일 전체 붙여넣기 → "Run"
--   3. Database → Tables → subscriptions 에서 transaction_id 컬럼 확인
--
-- 멱등 (idempotent): 여러 번 실행해도 안전.
--
-- 롤백:
--   ALTER TABLE public.subscriptions DROP COLUMN IF EXISTS transaction_id;
--   ALTER TABLE public.subscriptions DROP COLUMN IF EXISTS last_transaction_id;
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1) subscriptions 테이블에 transaction_id 컬럼 추가 ───────────────────────
-- Apple StoreKit: transactionId (numeric string)
-- Google Play: orderId
ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS transaction_id text;

-- 최신 transaction_id 를 중복 없이 빠르게 조회하기 위한 인덱스.
CREATE INDEX IF NOT EXISTS subscriptions_transaction_id_idx
  ON public.subscriptions (transaction_id)
  WHERE transaction_id IS NOT NULL;

-- ── 2) 기존 iap_notifications 에서 transaction_id 역추적 뷰 (선택) ──────────
-- iap_notifications 에는 notificationUUID / messageId 가 있으므로
-- transaction_id 와는 별도 컬럼. 뷰는 이력 조회 API 의 fallback 용.

-- 뷰가 이미 있으면 교체.
CREATE OR REPLACE VIEW public.iap_subscription_history AS
SELECT
  s.user_id,
  s.product_id,
  s.store,
  s.status,
  s.original_purchase_at                            AS started_at,
  s.expires_at,
  s.trial_ends_at,
  s.last_renewed_at,
  s.cancel_reason,
  COALESCE(s.transaction_id, n.transaction_id_hint) AS transaction_id,
  s.updated_at
FROM public.subscriptions s
LEFT JOIN LATERAL (
  -- iap_notifications 에서 가장 최근 항목의 JWS 에서 transactionId 를 추출.
  -- store = app_store 이면 payload->'data'->>'transactionId',
  -- store = play_store 이면 payload->'subscriptionNotification'->>'purchaseToken'
  SELECT
    CASE s.store
      WHEN 'app_store'   THEN (n2.payload->'data'->>'transactionId')
      WHEN 'play_store'  THEN (n2.payload->'subscriptionNotification'->>'purchaseToken')
      ELSE NULL
    END AS transaction_id_hint
  FROM public.iap_notifications n2
  WHERE n2.store = s.store
  ORDER BY n2.created_at DESC
  LIMIT 1
) n ON true;
