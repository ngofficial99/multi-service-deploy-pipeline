class Db:
    def __init__(self, dsn: str) -> None:
        # Imported lazily so the worker's pure logic can be unit-tested with a
        # fake Db, without requiring the psycopg driver to be installed.
        import psycopg

        self.conn = psycopg.connect(dsn, autocommit=True)

    def claim_pending(self):
        """Atomically claim one pending lead (SKIP LOCKED avoids double-send)."""
        with self.conn.cursor() as cur:
            cur.execute(
                """
                UPDATE leads SET status='processing', updated_at=now()
                WHERE id = (
                    SELECT id FROM leads WHERE status='pending'
                    ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1
                )
                RETURNING id, first_name, email
                """
            )
            return cur.fetchone()

    def mark_emailed(self, lead_id: int) -> None:
        """Mark the lead emailed and record that the invite was sent."""
        with self.conn.cursor() as cur:
            cur.execute(
                """
                UPDATE leads
                SET status='emailed', invite_sent=true, invite_sent_at=now(),
                    error=NULL, updated_at=now()
                WHERE id=%s
                """,
                (lead_id,),
            )

    def mark_failed(self, lead_id: int, err: str) -> None:
        with self.conn.cursor() as cur:
            cur.execute(
                "UPDATE leads SET status='failed', error=%s, updated_at=now() WHERE id=%s",
                (err, lead_id),
            )

    def heartbeat(self, worker_id: str) -> None:
        with self.conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO worker_heartbeat (worker_id, last_seen)
                VALUES (%s, now())
                ON CONFLICT (worker_id) DO UPDATE SET last_seen=now()
                """,
                (worker_id,),
            )
