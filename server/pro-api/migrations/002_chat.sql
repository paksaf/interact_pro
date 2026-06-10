-- In-app support chat. Two tables:
--   conversations — one per (user, topic). 'topic' is optional; the
--     first message's first 60 chars become the title for admin lists.
--   messages — append-only. role in {'user','ai','admin','system'}.
--     The 'system' role is for SLA / hand-off pings ("An admin will
--     reply within 24 hours") that aren't authored by anyone.
--
-- Apply with:
--   sudo -u postgres psql -d interactpro -f /opt/interact/pro-api/migrations/002_chat.sql

CREATE TABLE IF NOT EXISTS conversations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title           TEXT,
    -- 'open' = active, awaiting next message either side; 'admin_handoff'
    -- = AI tapped out, waiting for human; 'closed' = resolved /
    -- archived. Indexed so admin queue queries are O(log n).
    status          TEXT NOT NULL DEFAULT 'open'
                       CHECK (status IN ('open','admin_handoff','closed')),
    -- bookkeeping for admin SLA — set when a user message comes in and
    -- the AI declines / fails to handle it.
    handoff_at      TIMESTAMPTZ,
    last_admin_reply_at TIMESTAMPTZ,
    last_user_message_at TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS conversations_user_idx ON conversations(user_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS conversations_status_idx ON conversations(status, updated_at DESC);

CREATE TABLE IF NOT EXISTS messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role            TEXT NOT NULL
                       CHECK (role IN ('user','ai','admin','system')),
    body            TEXT NOT NULL,
    -- Optional: the actor (admin user id) for role='admin'. Null for
    -- ai/system; for user role, the conversation already carries
    -- user_id.
    actor_id        UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS messages_conv_idx ON messages(conversation_id, created_at);

-- Auto-bump conversations.updated_at when a new message is inserted.
-- Used by the indexed status queries to surface "newest first".
CREATE OR REPLACE FUNCTION bump_conversation_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE conversations
       SET updated_at = NOW(),
           last_user_message_at  = CASE WHEN NEW.role = 'user'
                                        THEN NOW()
                                        ELSE last_user_message_at END,
           last_admin_reply_at   = CASE WHEN NEW.role = 'admin'
                                        THEN NOW()
                                        ELSE last_admin_reply_at END
     WHERE id = NEW.conversation_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS messages_bump_conversation ON messages;
CREATE TRIGGER messages_bump_conversation
    AFTER INSERT ON messages
    FOR EACH ROW EXECUTE FUNCTION bump_conversation_updated_at();
