"""Print seconds since the worker's last heartbeat (used by the reconciler's
health check). Prefers the DATABASE_URL env var (so it works inside the worker
container via `docker exec`), falling back to C:\\hanomi\\worker.env on the host.
Prints a large number if there is no heartbeat or the DB is unreachable, so the
caller treats that as unhealthy."""
import os
import sys

ENV_PATH = r"C:\hanomi\worker.env"


def database_url() -> str:
    # In-container: the DSN is an env var (passed via --env-file). On host: the
    # worker.env file. Try env first, then the file.
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    try:
        with open(ENV_PATH, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("DATABASE_URL="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    raise RuntimeError("DATABASE_URL not found in env or worker.env")


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
