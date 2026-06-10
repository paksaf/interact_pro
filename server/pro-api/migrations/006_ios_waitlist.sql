-- Migration 006 — iOS waitlist for the Pro iOS landing page.
--
-- The landing page at pro.interactpak.com/ios.html collects email +
-- device + name from iPhone visitors so we can blast TestFlight invites
-- the moment the iOS build is approved. This table is the inbox.
--
-- Idempotent: re-running this migration is safe. The unique partial
-- index on lower(email) prevents duplicate signups while still
-- allowing rows where email is somehow NULL (shouldn't happen — the
-- form's `required` enforces it client-side, but defense in depth).

CREATE TABLE IF NOT EXISTS ios_waitlist (
    id           BIGSERIAL PRIMARY KEY,
    name         TEXT,
    email        TEXT NOT NULL,
    device       TEXT,
    user_agent   TEXT,
    referrer     TEXT,
    ip_hash      TEXT,                    -- sha256 of remote_addr — for rate-limiting, not for tracking
    app          TEXT NOT NULL DEFAULT 'interact-pro',
    platform     TEXT NOT NULL DEFAULT 'ios',
    invited_at   TIMESTAMPTZ,             -- set when we send the TestFlight invite blast
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Non-partial unique index — email is NOT NULL on the column already,
-- and a partial index forces ON CONFLICT to restate the WHERE predicate.
-- Simpler to drop the partial form. The IF NOT EXISTS guard below recreates
-- it if you're applying this migration to a fresh DB; the DROP first
-- handles re-applies on a DB that already has the old partial index.
DROP INDEX IF EXISTS ios_waitlist_email_app_idx;
CREATE UNIQUE INDEX IF NOT EXISTS ios_waitlist_email_app_idx
    ON ios_waitlist (lower(email), app);

CREATE INDEX IF NOT EXISTS ios_waitlist_created_idx
    ON ios_waitlist (created_at DESC);

CREATE INDEX IF NOT EXISTS ios_waitlist_uninvited_idx
    ON ios_waitlist (created_at)
    WHERE invited_at IS NULL;

COMMENT ON TABLE ios_waitlist IS
    'Captures emails from pro.interactpak.com/ios.html visitors. Used '
    'to send the first TestFlight invite blast when the iOS build ships. '
    'See web-landing/ios.html and /api/notify/ios-waitlist endpoint.';
