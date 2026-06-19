-- A "lead" is a demo request submitted via the "Try Hanomi" form
-- (fields: first name, phone, email, company). The Python worker picks up
-- pending leads and emails the welcome message, then marks the invite sent.
CREATE TABLE leads (
    id             BIGSERIAL PRIMARY KEY,
    first_name     TEXT NOT NULL,
    phone          TEXT NOT NULL,
    email          TEXT NOT NULL,
    company        TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','processing','emailed','failed')),
    -- Explicit, auditable "has this person been invited?" tracking.
    invite_sent    BOOLEAN NOT NULL DEFAULT false,
    invite_sent_at TIMESTAMPTZ,
    error          TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_leads_status ON leads (status);
CREATE INDEX idx_leads_invite_sent ON leads (invite_sent);

CREATE TABLE worker_heartbeat (
    worker_id   TEXT PRIMARY KEY,
    last_seen   TIMESTAMPTZ NOT NULL DEFAULT now()
);
