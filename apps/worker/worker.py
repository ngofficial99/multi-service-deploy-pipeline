import time

import config
import db as db_module
import email_template
import sender as sender_module


def run_once(database, mail_sender, worker_id: str) -> bool:
    """One poll cycle: heartbeat, then process at most one pending lead.

    Returns True if a lead was processed (so the caller can poll again
    immediately instead of sleeping).
    """
    database.heartbeat(worker_id)
    row = database.claim_pending()
    if row is None:
        return False
    lead_id, name, email = row
    try:
        mail_sender.send(email, email_template.SUBJECT, email_template.render(name))
        database.mark_emailed(lead_id)
    except Exception as exc:  # noqa: BLE001 — record failure, keep the loop alive
        database.mark_failed(lead_id, str(exc))
    return True


def main() -> None:
    # --- ROLLBACK DRILL (temporary) — proves deploy-worker auto-rollback. ---
    # This image builds fine but crashes on startup, so the deploy health gate
    # fails and the runner must revert to the last-good image. Reverted in the
    # very next commit; must never remain on main.
    raise SystemExit("ROLLBACK DRILL: intentional startup crash to test auto-rollback")
    cfg = config.load()
    database = db_module.Db(cfg.database_url)
    mail_sender = sender_module.from_config(cfg)
    print(f"worker {cfg.worker_id} started; sender={type(mail_sender).__name__}", flush=True)
    while True:
        worked = run_once(database, mail_sender, cfg.worker_id)
        if not worked:
            time.sleep(cfg.poll_interval)


if __name__ == "__main__":
    main()
