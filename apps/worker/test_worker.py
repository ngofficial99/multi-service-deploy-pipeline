import email_template
import worker


class FakeDb:
    def __init__(self, rows):
        self.rows = list(rows)
        self.heartbeats = 0
        self.emailed = []
        self.failed = {}

    def heartbeat(self, worker_id):
        self.heartbeats += 1

    def claim_pending(self):
        return self.rows.pop(0) if self.rows else None

    def mark_emailed(self, lead_id):
        self.emailed.append(lead_id)

    def mark_failed(self, lead_id, err):
        self.failed[lead_id] = err


class RecordingSender:
    def __init__(self, fail=False):
        self.sent = []
        self.fail = fail

    def send(self, to_email, subject, body):
        if self.fail:
            raise RuntimeError("smtp down")
        self.sent.append((to_email, subject, body))


def test_email_template_contains_key_copy():
    body = email_template.render("Nishant")
    assert "Hello Nishant," in body
    assert "Thank you for your interest in Hanomi.ai" in body
    assert "Team Hanomi" in body
    assert email_template.SUBJECT == "Thanks for reaching out to Hanomi"


def test_run_once_sends_and_marks_emailed():
    fake = FakeDb(rows=[(1, "Nishant", "nishant@example.com")])
    sender = RecordingSender()
    worked = worker.run_once(fake, sender, "w1")
    assert worked is True
    assert fake.heartbeats == 1
    assert fake.emailed == [1]
    assert sender.sent[0][0] == "nishant@example.com"
    assert "Hello Nishant," in sender.sent[0][2]


def test_run_once_marks_failed_on_send_error():
    fake = FakeDb(rows=[(2, "Bob", "bob@example.com")])
    sender = RecordingSender(fail=True)
    worked = worker.run_once(fake, sender, "w1")
    assert worked is True
    assert fake.failed[2] == "smtp down"
    assert fake.emailed == []


def test_run_once_idle_when_no_leads():
    fake = FakeDb(rows=[])
    sender = RecordingSender()
    assert worker.run_once(fake, sender, "w1") is False
    assert fake.heartbeats == 1
