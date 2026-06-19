-- A "lead" is a demo request submitted via the "Try Hanomi" form. The Python
-- worker picks up pending leads and emails the welcome message.
CREATE TABLE leads (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    email       TEXT NOT NULL,
    company     TEXT,
    message     TEXT,
    status      TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','processing','emailed','failed')),
    error       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_leads_status ON leads (status);

CREATE TABLE worker_heartbeat (
    worker_id   TEXT PRIMARY KEY,
    last_seen   TIMESTAMPTZ NOT NULL DEFAULT now()
);
