-- Spike B — admin document browser.
--
-- Adds the user-side consent flag + the per-user document index
-- table that the admin browse endpoints query. The actual blob files
-- already live at /var/www/pro/storage/<user_id>/<doc_id>.pdf (from
-- #158); this table indexes them with display metadata so the admin
-- list view doesn't need to stat each file.

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS admin_doc_access_allowed boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS admin_doc_consent_at     timestamptz;

-- Index of every user's synced documents. The /api/sync/upload route
-- already writes one row here per upload (id, user_id, name, sha256,
-- size_bytes, storage_path, mtime). If your existing sync code stores
-- this metadata elsewhere — say, on disk as a sidecar JSON — adapt
-- the columns below to match. Common-case shape:

CREATE TABLE IF NOT EXISTS sync_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name          text NOT NULL,
  size_bytes    bigint NOT NULL,
  sha256        text NOT NULL,
  storage_path  text NOT NULL,
  mtime         timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sync_documents_user_mtime_idx
  ON sync_documents (user_id, mtime DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS sync_documents_sha256_idx
  ON sync_documents (sha256);

-- audit_log already exists from 001_init with columns:
--   id (bigserial), actor_id, action, target_id, body (jsonb), at.
-- Reuse it as-is rather than creating a duplicate. The Spike B
-- admin-access-log query reads back on target_id (= subject) and
-- action — index by those + at DESC so the user-side log endpoint
-- (LIMIT 100, latest first) is a single index scan.
CREATE INDEX IF NOT EXISTS audit_log_target_action_idx
  ON audit_log (target_id, action, at DESC);
