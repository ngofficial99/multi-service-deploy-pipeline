"""Pluggable email senders.

- FileSender (default): writes the rendered email to OUTBOX_DIR. Lets the demo
  run with no external email account, and proves the end-to-end flow.
- SmtpSender: real delivery via SMTP, used only when SMTP_* are configured
  (credentials come from Secret Manager at deploy time, never from code).
"""

import os
import smtplib
from email.message import EmailMessage
from typing import Protocol


class Sender(Protocol):
    def send(self, to_email: str, subject: str, body: str) -> None: ...


class FileSender:
    def __init__(self, outbox_dir: str, from_addr: str) -> None:
        self.outbox_dir = outbox_dir
        self.from_addr = from_addr
        os.makedirs(outbox_dir, exist_ok=True)

    def send(self, to_email: str, subject: str, body: str) -> None:
        safe = to_email.replace("@", "_at_").replace("/", "_")
        path = os.path.join(self.outbox_dir, f"{safe}.eml")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(f"From: {self.from_addr}\n")
            fh.write(f"To: {to_email}\n")
            fh.write(f"Subject: {subject}\n\n")
            fh.write(body)
        print(f"[FileSender] wrote welcome email for {to_email} -> {path}", flush=True)


class SmtpSender:
    def __init__(self, host: str, port: int, user: str, password: str, from_addr: str) -> None:
        self.host, self.port = host, port
        self.user, self.password = user, password
        self.from_addr = from_addr

    def send(self, to_email: str, subject: str, body: str) -> None:
        msg = EmailMessage()
        msg["From"] = self.from_addr
        msg["To"] = to_email
        msg["Subject"] = subject
        msg.set_content(body)
        with smtplib.SMTP(self.host, self.port, timeout=20) as smtp:
            smtp.starttls()
            if self.user:
                smtp.login(self.user, self.password)
            smtp.send_message(msg)
        print(f"[SmtpSender] sent welcome email to {to_email}", flush=True)


def from_config(cfg) -> Sender:
    """Choose the sender based on config: real SMTP if configured, else file."""
    from_addr = f"{cfg.from_name} <{cfg.from_email}>"
    if cfg.smtp_host:
        return SmtpSender(cfg.smtp_host, cfg.smtp_port, cfg.smtp_user, cfg.smtp_pass, from_addr)
    return FileSender(cfg.outbox_dir, from_addr)
