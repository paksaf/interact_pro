-- Audit trail for IAP receipts. Every successful (or attempted)
-- in-app purchase gets a row here BEFORE the user is granted Pro.
-- If validation later proves a receipt was forged or refunded, we
-- have the original payload to revoke against.
--
-- The receipt body is kept verbatim — Apple/Google may need it later
-- to call their refund-notification webhooks; truncating now would
-- mean we can't replay verification.

CREATE TABLE IF NOT EXISTS iap_purchases (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
  platform        text NOT NULL CHECK (platform IN ('ios','android')),
  product_id      text NOT NULL,
  transaction_id  text NOT NULL,
  receipt_payload text NOT NULL,
  verified        boolean NOT NULL DEFAULT false,
  verifier        text,           -- 'apple', 'google', 'sandbox', 'skipped'
  verification_error text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  verified_at     timestamptz
);

-- Dedup by (platform, transaction_id) — same purchase replayed by the
-- client (e.g., after a restorePurchases) should NOT generate a second
-- audit row. Upsert pattern: INSERT ... ON CONFLICT (platform,txn_id) DO UPDATE.
CREATE UNIQUE INDEX IF NOT EXISTS iap_purchases_txn_unique
  ON iap_purchases (platform, transaction_id);

CREATE INDEX IF NOT EXISTS iap_purchases_user_idx
  ON iap_purchases (user_id, created_at DESC);

-- Two helper columns on users so admin views can see WHICH product
-- the user bought and WHEN we granted them Pro. The original schema
-- has only `pro_active boolean` — enough to gate features, but not
-- enough to answer "is this a $4.99-tier or $19.99-tier customer".
ALTER TABLE users ADD COLUMN IF NOT EXISTS pro_product_id  text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS pro_granted_at  timestamptz;
