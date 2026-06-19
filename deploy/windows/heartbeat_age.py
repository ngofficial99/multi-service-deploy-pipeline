"""Print seconds since the worker's last heartbeat (used by the reconciler's
health check). Reads DATABASE_URL from C:\\hanomi\\worker.env. Prints a large
number if there is no heartbeat or the DB is unreachable, so the caller treats
that as unhealthy."""
import sys

ENV_PATH = r"C:\hanomi\worker.env"


def database_url() -> str:
    with open(ENV_PATH, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("DATABASE_URL="):
                return line.split("=", 1)[1].strip()
    raise RuntimeError("DATABASE_URL not found in worker.env")


def main() -> None:
    try:
        import psycopg

        with psycopg.connect(database_url(), autocommit=True) as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT EXTRACT(EPOCH FROM now() - max(last_seen)) FROM worker_heartbeat"
            )
            row = cur.fetchone()
            age = int(row[0]) if row and row[0] is not None else 999999
            print(age)
    except Exception as exc:  # noqa: BLE001 — unhealthy on any failure
        print(999999)
        print(f"heartbeat_age error: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
