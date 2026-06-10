-- Interact Pro — pro.interactpak.com/api backend.
--
-- Single-tenant schema; per-user data scopes by user_id. Apply with:
--   psql -h localhost -U interactpro -d interactpro -f migrations/001_init.sql
--
-- Re-runnable in dev (every CREATE uses IF NOT EXISTS) but DROP + recreate
-- is safer if you change column types. There's no migration tool baked in
-- — we don't need one until v2.

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive email

-- ── users ───────────────────────────────────────────────────────────────
-- Either email or phone is required (one of the two — both is fine but
-- never neither). The CHECK enforces this at the DB level so a dropped
-- API validation can't corrupt the table.
CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           CITEXT UNIQUE,
    phone           TEXT UNIQUE,
    display_name    TEXT NOT NULL DEFAULT 'User',
    -- 'user' | 'admin'. Don't trust the client to send this — server
    -- decides. Promotion happens via the admin panel only.
    role            TEXT NOT NULL DEFAULT 'user'
                       CHECK (role IN ('user', 'admin')),
    -- 7 days from first verify by default. Null = no trial (Pro from
    -- day one, or trial-ended-and-not-paid users).
    trial_ends_at   TIMESTAMPTZ,
    pro_active      BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (email IS NOT NULL OR phone IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS users_pro_active_idx ON users(pro_active)
    WHERE pro_active;

-- ── otp_codes ───────────────────────────────────────────────────────────
-- One row per OTP request. We don't delete consumed/expired rows on
-- request — a janitor cron can prune nightly to keep the table bounded.
-- Indexed on (contact, consumed) so verify can find the one fresh code.
CREATE TABLE IF NOT EXISTS otp_codes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    contact         TEXT NOT NULL,                 -- email or phone string
    contact_type    TEXT NOT NULL
                       CHECK (contact_type IN ('email', 'phone')),
    code            TEXT NOT NULL,                 -- 6-digit string
    attempts        INT NOT NULL DEFAULT 0,        -- bump on bad verify
    expires_at      TIMESTAMPTZ NOT NULL,
    consumed        BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS otp_codes_contact_idx
    ON otp_codes(contact, consumed) WHERE NOT consumed;

CREATE INDEX IF NOT EXISTS otp_codes_expiry_idx
    ON otp_codes(expires_at);

-- ── documents (cloud sync metadata) ─────────────────────────────────────
-- Sync feature isn't enabled in v1 backend — table exists so a future
-- /api/sync/* implementation has somewhere to land. Per-user file blobs
-- live on disk under /var/www/pro/storage/<user_id>/<id>.pdf; this row
-- records the metadata.
CREATE TABLE IF NOT EXISTS documents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    size_bytes      BIGINT NOT NULL,
    sha256          TEXT NOT NULL,
    -- Server-side monotonic version for conflict detection. Clients
    -- send `If-Match: <version>` on upload; mismatch = 409.
    version         BIGINT NOT NULL DEFAULT 1,
    storage_path    TEXT NOT NULL,
    mtime           TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS documents_user_id_idx ON documents(user_id);

-- ── jwt_denylist (sign-out everywhere) ──────────────────────────────────
-- Each issued JWT carries a `jti` (JWT ID) claim. /api/auth/sign-out
-- inserts the jti here; the auth middleware rejects any token whose
-- jti is denylisted. Self-cleans because rows past expires_at can be
-- dropped by the same nightly janitor.
CREATE TABLE IF NOT EXISTS jwt_denylist (
    jti         UUID PRIMARY KEY,
    expires_at  TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS jwt_denylist_expiry_idx
    ON jwt_denylist(expires_at);

-- ── audit_log ───────────────────────────────────────────────────────────
-- Every admin action writes a row here. Append-only; never updated.
-- Use for "who granted Pro to whom" forensics.
CREATE TABLE IF NOT EXISTS audit_log (
    id          BIGSERIAL PRIMARY KEY,
    actor_id    UUID REFERENCES users(id),
    action      TEXT NOT NULL,
    target_id   UUID,
    body        JSONB,
    at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS audit_log_actor_idx ON audit_log(actor_id, at);
CREATE INDEX IF NOT EXISTS audit_log_target_idx ON audit_log(target_id, at);

-- ── updated_at autotrigger ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS users_updated_at ON users;
CREATE TRIGGER users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS documents_updated_at ON documents;
CREATE TRIGGER documents_updated_at
    BEFORE UPDATE ON documents
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
