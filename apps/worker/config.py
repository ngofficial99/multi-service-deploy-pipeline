import os


class Config:
    """Loaded from env; secrets injected by the reconciler at deploy time."""

    def __init__(self) -> None:
        self.database_url = os.environ["DATABASE_URL"]
        self.worker_id = os.environ.get("WORKER_ID", "worker-1")
        self.poll_interval = float(os.environ.get("POLL_INTERVAL", "5"))

        # Email config. If SMTP_HOST is unset, the worker uses the file/console
        # sender so the demo runs with zero external accounts. When SMTP_* are
        # provided (from Secret Manager), it sends for real.
        self.smtp_host = os.environ.get("SMTP_HOST", "")
        self.smtp_port = int(os.environ.get("SMTP_PORT", "587"))
        self.smtp_user = os.environ.get("SMTP_USER", "")
        self.smtp_pass = os.environ.get("SMTP_PASS", "")
        self.from_email = os.environ.get("FROM_EMAIL", "team@hanomi.ai")
        self.from_name = os.environ.get("FROM_NAME", "Hanomi Team")
        # Where the file sender writes rendered emails (dev/offline mode).
        self.outbox_dir = os.environ.get("OUTBOX_DIR", "./outbox")


def load() -> "Config":
    return Config()
