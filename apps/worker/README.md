# Worker (Hanomi lead processor)

Polls the `leads` table for `pending` demo requests (submitted via the "Try
Hanomi" form on the frontend), sends each requester the Hanomi welcome email,
and marks the lead `emailed`. Writes a `worker_heartbeat` row each cycle — that
heartbeat is the worker's health signal, read by the backend `/healthz` and
surfaced in the frontend as a "worker online" indicator.

## Email sending (pluggable)

- **Default / offline:** if `SMTP_HOST` is unset, the worker uses `FileSender`,
  which writes each rendered email to `OUTBOX_DIR` (`./outbox`). The demo runs
  end-to-end with **zero external accounts**.
- **Real delivery:** set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`
  (and `FROM_EMAIL`/`FROM_NAME`). In production these come from **Secret
  Manager**, injected by the reconciler at deploy time — never committed.

## Running

- **Local/dev:** `DATABASE_URL=... python worker.py` (or via Docker —
  `apps/worker/Dockerfile`).
- **Production (Windows server):** runs as a native **Windows Service**, not a
  container — see `deploy/windows/`. systemd/Quadlet are Linux-only, so the
  Windows worker is a deliberate separate track.

## Tests

`python -m pytest` — unit tests use a fake DB and a recording sender, so they
need no database or SMTP server.
