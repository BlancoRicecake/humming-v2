-- 002 — bind subscriptions to store transactions (2026-09-03)
--
-- Why: store webhooks (Apple Server Notifications V2, Google RTDN) identify a
-- subscription by originalTransactionId / purchaseToken, never by our user id.
-- Without these columns a renewal / expiry / refund notification could not be
-- mapped to a user, so subscription rows never expired. The unique indexes also
-- stop one receipt from unlocking Pro on many accounts.
--
-- Apply with: supabase db push   (or paste into the SQL editor)

alter table public.subscriptions
  add column if not exists original_transaction_id text,
  add column if not exists transaction_id          text,
  add column if not exists purchase_token          text,
  add column if not exists environment             text,   -- Apple: Sandbox|Production
  add column if not exists last_event_at           timestamptz;

create unique index if not exists subscriptions_apple_orig_tx_uidx
  on public.subscriptions (store, original_transaction_id)
  where original_transaction_id is not null;

create unique index if not exists subscriptions_google_token_uidx
  on public.subscriptions (store, purchase_token)
  where purchase_token is not null;

-- Webhook idempotency: a notification counts as handled only once processed.
-- Rows with processed_at null are retried on redelivery.
alter table public.iap_notifications
  add column if not exists processed_at timestamptz,
  add column if not exists error        text;

create index if not exists iap_notifications_received_idx
  on public.iap_notifications (received_at);
