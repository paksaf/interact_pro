-- 007: anti-replay hardening for IAP verification (2026-06-10 audit).
--
-- Finding: the (platform, transaction_id) uniqueness only deduplicates the
-- CLIENT-SUPPLIED transaction id. A second account could replay another
-- user's valid receipt with a different transactionId string and be granted
-- Pro. Fix: store the canonical transaction id extracted from the VERIFIED
-- Apple/Google response and enforce one grant per canonical id.
--
-- Partial index (NULLs exempt) so historic rows and failed verifications
-- don't block.

ALTER TABLE iap_purchases ADD COLUMN IF NOT EXISTS canonical_txn text;

CREATE UNIQUE INDEX IF NOT EXISTS iap_purchases_canonical_txn_unique
  ON iap_purchases (platform, canonical_txn)
  WHERE canonical_txn IS NOT NULL;
