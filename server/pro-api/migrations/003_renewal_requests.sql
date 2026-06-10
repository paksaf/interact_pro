-- Trial renewal requests. Filed by users whose 7-day trial has lapsed
-- (or is about to). Admin approves → user.trial_ends_at extends by N
-- days (default 30). Admin declines → request marked declined with an
-- optional reason. There can only be ONE pending request per user at a
-- time — enforced by partial unique index, not application code, so a
-- concurrent double-tap can't insert two pending rows.
--
-- Apply with:
--   sudo -u postgres psql -d interactpro -f /opt/interact/pro-api/migrations/003_renewal_requests.sql

CREATE TABLE IF NOT EXISTS renewal_requests (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    note            TEXT,
    -- 'pending' until admin acts. Terminal states are 'approved' and
    -- 'declined'; we keep history rather than deleting so the admin
    -- screen can show the audit trail and we can rate-limit abuse.
    status          TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','approved','declined')),
    requested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at    TIMESTAMPTZ,
    responded_by    UUID REFERENCES users(id),
    -- Audit: how many days were granted (approve) and admin reason
    -- (decline). Kept nullable; only the matching one is set per row.
    extend_days     INT,
    reason          TEXT
);

-- Only one PENDING row per user. Approved/declined rows accumulate as
-- history but never block a fresh request.
CREATE UNIQUE INDEX IF NOT EXISTS renewal_requests_one_pending_per_user
    ON renewal_requests(user_id)
    WHERE status = 'pending';

-- Admin queue queries ("show me pending requests sorted by oldest").
CREATE INDEX IF NOT EXISTS renewal_requests_pending_idx
    ON renewal_requests(status, requested_at)
    WHERE status = 'pending';
