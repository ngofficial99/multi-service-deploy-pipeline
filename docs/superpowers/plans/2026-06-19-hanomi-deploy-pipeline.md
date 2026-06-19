# Hanomi Multi-Service Deploy Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a GitOps-driven, multi-service deploy pipeline for a 3-VM GCP stack (Go/Gin backend, Next.js frontend, Python Windows worker) with rollback, health checks, secrets handling, and defined partial-failure behaviour — plus the three runnable demo apps backed by Cloud SQL Postgres.

**Architecture:** GitHub Actions (control plane) authenticates to GCP via Workload Identity Federation, builds digest-pinned images, and commits desired image digests to a `deploy-state` GitOps repo. Each VM runs a local reconciler (Podman+Quadlet on Linux, native Windows Service on the worker) that polls desired state, converges, health-checks, and reports actual state to GCS. Cloud SQL Postgres (private IP) backs the backend.

**Tech Stack:** Go 1.22 + Gin + golang-migrate + pgx, Next.js 14 (App Router), Python 3.12 + psycopg, Terraform (google provider), Podman/Quadlet + systemd, PowerShell + Windows Service, GitHub Actions, Cloud SQL Postgres.

---

## File Structure

```
apps/
  backend/        Go/Gin API — main.go, handlers, db, migrations/, Dockerfile, go.mod
  worker/         Python worker — worker.py, db.py, config.py, requirements.txt, Dockerfile, pyproject
  frontend/       Next.js — app/, lib/api.ts, app/api/health/route.ts, Dockerfile
db/
  schema.sql      Canonical schema reference (mirrors migrations)
deploy/
  linux/          Quadlet .container units, reconciler.sh, reconcile.timer/service, cloud-init.yaml
  windows/        reconciler.ps1, install-service.ps1, bootstrap.ps1
  state/          GitOps desired-state examples: <svc>/desired.yaml
terraform/
  *.tf            network, cloudsql, instances, iam, artifact, secrets, gcs, wif, variables, outputs
.github/workflows/
  deploy.yml      orchestrator
README.md
```

---

## Phase A — Demo Apps (build & verify locally first)

> These run against a local Postgres (Docker) so they are verifiable without GCP.
> A local `docker compose` (dev-only) is provided for fast iteration.

### Task A0: Repo scaffolding & local dev Postgres

**Files:**
- Create: `.gitignore`
- Create: `dev/docker-compose.yml`
- Create: `db/schema.sql`

- [ ] **Step 1: Write `.gitignore`**

```gitignore
# Go
apps/backend/bin/
*.test
# Node
node_modules/
.next/
# Python
__pycache__/
*.pyc
.venv/
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
# Secrets / env
.env
*.env
!*.env.example
# OS
.DS_Store
```

- [ ] **Step 2: Write `dev/docker-compose.yml` (local-only Postgres for development)**

```yaml
# Dev-only. Production uses Cloud SQL (private IP). See terraform/cloudsql.tf.
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: hanomi
      POSTGRES_PASSWORD: devpassword
      POSTGRES_DB: hanomi
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
volumes:
  pgdata:
```

- [ ] **Step 3: Write `db/schema.sql` (reference; migrations are source of truth)**

```sql
-- Canonical reference of the schema produced by backend migrations.
CREATE TABLE IF NOT EXISTS tasks (
    id          BIGSERIAL PRIMARY KEY,
    payload     TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','processing','done','failed')),
    result      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks (status);

CREATE TABLE IF NOT EXISTS worker_heartbeat (
    worker_id   TEXT PRIMARY KEY,
    last_seen   TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

- [ ] **Step 4: Start dev Postgres and verify**

Run: `docker compose -f dev/docker-compose.yml up -d && sleep 3 && docker exec $(docker compose -f dev/docker-compose.yml ps -q postgres) pg_isready -U hanomi`
Expected: `accepting connections`

- [ ] **Step 5: Commit**

```bash
git add .gitignore dev/docker-compose.yml db/schema.sql
git commit -m "chore: repo scaffolding + local dev postgres"
```

---

### Task A1: Backend — Go module, config, migrations

**Files:**
- Create: `apps/backend/go.mod`
- Create: `apps/backend/internal/config/config.go`
- Create: `apps/backend/migrations/0001_init.up.sql`
- Create: `apps/backend/migrations/0001_init.down.sql`

- [ ] **Step 1: Init the Go module**

Run: `cd apps/backend && go mod init github.com/hanomi/backend && go get github.com/gin-gonic/gin@v1.10.0 github.com/jackc/pgx/v5@v5.6.0 github.com/golang-migrate/migrate/v4@v4.17.1`
Expected: `go.mod`/`go.sum` written, no errors.

- [ ] **Step 2: Write `internal/config/config.go`**

```go
package config

import (
	"fmt"
	"os"
)

// Config is loaded purely from environment so that secrets are injected by the
// reconciler at deploy time (Secret Manager -> 0600 env file), never baked in.
type Config struct {
	Port        string
	DatabaseURL string
}

func Load() (Config, error) {
	c := Config{
		Port:        getenv("PORT", "8080"),
		DatabaseURL: os.Getenv("DATABASE_URL"),
	}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL is required")
	}
	return c, nil
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
```

- [ ] **Step 3: Write `migrations/0001_init.up.sql`**

```sql
CREATE TABLE tasks (
    id          BIGSERIAL PRIMARY KEY,
    payload     TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','processing','done','failed')),
    result      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_tasks_status ON tasks (status);

CREATE TABLE worker_heartbeat (
    worker_id   TEXT PRIMARY KEY,
    last_seen   TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

- [ ] **Step 4: Write `migrations/0001_init.down.sql`**

```sql
DROP TABLE IF EXISTS worker_heartbeat;
DROP TABLE IF EXISTS tasks;
```

- [ ] **Step 5: Commit**

```bash
git add apps/backend/go.mod apps/backend/go.sum apps/backend/internal apps/backend/migrations
git commit -m "feat(backend): go module, config, initial migration"
```

---

### Task A2: Backend — DB layer with embedded migrations

**Files:**
- Create: `apps/backend/internal/store/store.go`
- Test: `apps/backend/internal/store/store_test.go`

- [ ] **Step 1: Write the failing test (`store_test.go`)**

```go
package store

import (
	"context"
	"os"
	"testing"
)

// Requires DATABASE_URL pointing at a test Postgres (dev/docker-compose.yml).
func testDSN(t *testing.T) string {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	return dsn
}

func TestMigrateAndCreateTask(t *testing.T) {
	ctx := context.Background()
	s, err := New(ctx, testDSN(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer s.Close()
	if err := s.Migrate(); err != nil {
		t.Fatalf("Migrate: %v", err)
	}
	task, err := s.CreateTask(ctx, "hello")
	if err != nil {
		t.Fatalf("CreateTask: %v", err)
	}
	if task.ID == 0 || task.Status != "pending" {
		t.Fatalf("unexpected task: %+v", task)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/backend && go test ./internal/store/ -run TestMigrateAndCreateTask -v`
Expected: FAIL (compile error: `New` undefined) — or SKIP if no DB; set `TEST_DATABASE_URL` first: `export TEST_DATABASE_URL="postgres://hanomi:devpassword@localhost:5432/hanomi?sslmode=disable"`.

- [ ] **Step 3: Write `internal/store/store.go`**

```go
package store

import (
	"context"
	"embed"
	"time"

	"github.com/golang-migrate/migrate/v4"
	"github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"database/sql"
)

//go:embed all:../../migrations
var migrationFS embed.FS

type Task struct {
	ID        int64     `json:"id"`
	Payload   string    `json:"payload"`
	Status    string    `json:"status"`
	Result    *string   `json:"result"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type Store struct {
	pool *pgxpool.Pool
	dsn  string
}

func New(ctx context.Context, dsn string) (*Store, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, err
	}
	return &Store{pool: pool, dsn: dsn}, nil
}

func (s *Store) Close() { s.pool.Close() }

// Migrate runs embedded migrations. Called on deploy BEFORE serving traffic;
// fail-closed so a bad migration aborts the deploy.
func (s *Store) Migrate() error {
	src, err := iofs.New(migrationFS, "migrations")
	if err != nil {
		return err
	}
	sqlDB, err := sql.Open("pgx", s.dsn)
	if err != nil {
		return err
	}
	defer sqlDB.Close()
	driver, err := postgres.WithInstance(sqlDB, &postgres.Config{})
	if err != nil {
		return err
	}
	m, err := migrate.NewWithInstance("iofs", src, "postgres", driver)
	if err != nil {
		return err
	}
	if err := m.Up(); err != nil && err != migrate.ErrNoChange {
		return err
	}
	return nil
}

func (s *Store) CreateTask(ctx context.Context, payload string) (Task, error) {
	var t Task
	err := s.pool.QueryRow(ctx,
		`INSERT INTO tasks (payload) VALUES ($1)
		 RETURNING id, payload, status, result, created_at, updated_at`,
		payload).Scan(&t.ID, &t.Payload, &t.Status, &t.Result, &t.CreatedAt, &t.UpdatedAt)
	return t, err
}

func (s *Store) ListTasks(ctx context.Context) ([]Task, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, payload, status, result, created_at, updated_at
		 FROM tasks ORDER BY id DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Task
	for rows.Next() {
		var t Task
		if err := rows.Scan(&t.ID, &t.Payload, &t.Status, &t.Result, &t.CreatedAt, &t.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Store) GetTask(ctx context.Context, id int64) (Task, error) {
	var t Task
	err := s.pool.QueryRow(ctx,
		`SELECT id, payload, status, result, created_at, updated_at
		 FROM tasks WHERE id=$1`, id).
		Scan(&t.ID, &t.Payload, &t.Status, &t.Result, &t.CreatedAt, &t.UpdatedAt)
	return t, err
}

// Ping checks DB connectivity (used by /healthz).
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

// WorkerLastSeen returns the freshest worker heartbeat age, or false if none.
func (s *Store) WorkerLastSeen(ctx context.Context) (time.Time, bool, error) {
	var ts time.Time
	err := s.pool.QueryRow(ctx,
		`SELECT max(last_seen) FROM worker_heartbeat`).Scan(&ts)
	if err != nil {
		return time.Time{}, false, err
	}
	if ts.IsZero() {
		return time.Time{}, false, nil
	}
	return ts, true, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/backend && export TEST_DATABASE_URL="postgres://hanomi:devpassword@localhost:5432/hanomi?sslmode=disable" && go test ./internal/store/ -run TestMigrateAndCreateTask -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/backend/internal/store
git commit -m "feat(backend): store layer with embedded migrations + tests"
```

---

### Task A3: Backend — HTTP handlers, health, main

**Files:**
- Create: `apps/backend/internal/api/api.go`
- Create: `apps/backend/main.go`
- Test: `apps/backend/internal/api/api_test.go`

- [ ] **Step 1: Write the failing test (`api_test.go`) — health route with a fake store**

```go
package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

type fakeStore struct{ pingErr error }

func (f fakeStore) Ping(context.Context) error { return f.pingErr }
func (f fakeStore) WorkerLastSeen(context.Context) (time.Time, bool, error) {
	return time.Now(), true, nil
}

func TestHealthzOK(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	RegisterHealth(r, fakeStore{})
	w := httptest.NewRecorder()
	req, _ := http.NewRequest(http.MethodGet, "/healthz", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d body=%s", w.Code, w.Body.String())
	}
}

func TestHealthzDBDown(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	RegisterHealth(r, fakeStore{pingErr: context.DeadlineExceeded})
	w := httptest.NewRecorder()
	req, _ := http.NewRequest(http.MethodGet, "/healthz", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503, got %d", w.Code)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/backend && go test ./internal/api/ -v`
Expected: FAIL (compile error: `RegisterHealth` undefined)

- [ ] **Step 3: Write `internal/api/api.go`**

```go
package api

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/hanomi/backend/internal/store"
)

// HealthChecker is the subset of the store the health route needs.
type HealthChecker interface {
	Ping(context.Context) error
	WorkerLastSeen(context.Context) (time.Time, bool, error)
}

// RegisterHealth wires GET /healthz. 200 only if the DB is reachable.
// Worker freshness is reported but does NOT fail the backend's own health.
func RegisterHealth(r *gin.Engine, h HealthChecker) {
	r.GET("/healthz", func(c *gin.Context) {
		ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
		defer cancel()
		if err := h.Ping(ctx); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"status": "db_unavailable"})
			return
		}
		workerOnline := false
		if ts, ok, err := h.WorkerLastSeen(ctx); err == nil && ok {
			workerOnline = time.Since(ts) < 60*time.Second
		}
		c.JSON(http.StatusOK, gin.H{"status": "ok", "worker_online": workerOnline})
	})
}

// RegisterTasks wires the task CRUD endpoints.
func RegisterTasks(r *gin.Engine, s *store.Store) {
	r.POST("/tasks", func(c *gin.Context) {
		var body struct {
			Payload string `json:"payload" binding:"required"`
		}
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		t, err := s.CreateTask(c.Request.Context(), body.Payload)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusCreated, t)
	})
	r.GET("/tasks", func(c *gin.Context) {
		ts, err := s.ListTasks(c.Request.Context())
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, ts)
	})
	r.GET("/tasks/:id", func(c *gin.Context) {
		id, err := strconv.ParseInt(c.Param("id"), 10, 64)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "bad id"})
			return
		}
		t, err := s.GetTask(c.Request.Context(), id)
		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
			return
		}
		c.JSON(http.StatusOK, t)
	})
}
```

- [ ] **Step 4: Write `main.go`**

```go
package main

import (
	"context"
	"log"

	"github.com/gin-gonic/gin"
	"github.com/hanomi/backend/internal/api"
	"github.com/hanomi/backend/internal/config"
	"github.com/hanomi/backend/internal/store"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	ctx := context.Background()
	s, err := store.New(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	defer s.Close()

	// Fail-closed migrations: abort startup if they fail.
	if err := s.Migrate(); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	r := gin.New()
	r.Use(gin.Recovery())
	api.RegisterHealth(r, s)
	api.RegisterTasks(r, s)

	log.Printf("backend listening on :%s", cfg.Port)
	if err := r.Run(":" + cfg.Port); err != nil {
		log.Fatalf("run: %v", err)
	}
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd apps/backend && go test ./... -v && go build ./...`
Expected: PASS + clean build

- [ ] **Step 6: Commit**

```bash
git add apps/backend/internal/api apps/backend/main.go apps/backend/go.sum
git commit -m "feat(backend): tasks API + healthz + main"
```

---

### Task A4: Backend — Dockerfile

**Files:**
- Create: `apps/backend/Dockerfile`

- [ ] **Step 1: Write `Dockerfile` (multi-stage, distroless, non-root)**

```dockerfile
FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/backend .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/backend /backend
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/backend"]
```

- [ ] **Step 2: Build to verify**

Run: `cd apps/backend && docker build -t hanomi-backend:dev .`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/backend/Dockerfile
git commit -m "feat(backend): distroless Dockerfile"
```

---

### Task A5: Worker — Python poller + heartbeat

**Files:**
- Create: `apps/worker/requirements.txt`
- Create: `apps/worker/config.py`
- Create: `apps/worker/db.py`
- Create: `apps/worker/worker.py`
- Test: `apps/worker/test_worker.py`

- [ ] **Step 1: Write `requirements.txt`**

```text
psycopg[binary]==3.2.1
pytest==8.2.0
```

- [ ] **Step 2: Write `config.py`**

```python
import os


class Config:
    """Loaded from env; secrets injected by the reconciler at deploy time."""

    def __init__(self) -> None:
        self.database_url = os.environ["DATABASE_URL"]
        self.worker_id = os.environ.get("WORKER_ID", "worker-1")
        self.poll_interval = float(os.environ.get("POLL_INTERVAL", "5"))


def load() -> "Config":
    return Config()
```

- [ ] **Step 3: Write `db.py`**

```python
import psycopg


class Db:
    def __init__(self, dsn: str) -> None:
        self.conn = psycopg.connect(dsn, autocommit=True)

    def claim_pending(self):
        """Atomically claim one pending task (SKIP LOCKED avoids double-processing)."""
        with self.conn.cursor() as cur:
            cur.execute(
                """
                UPDATE tasks SET status='processing', updated_at=now()
                WHERE id = (
                    SELECT id FROM tasks WHERE status='pending'
                    ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1
                )
                RETURNING id, payload
                """
            )
            return cur.fetchone()

    def complete(self, task_id: int, result: str) -> None:
        with self.conn.cursor() as cur:
            cur.execute(
                "UPDATE tasks SET status='done', result=%s, updated_at=now() WHERE id=%s",
                (result, task_id),
            )

    def fail(self, task_id: int, err: str) -> None:
        with self.conn.cursor() as cur:
            cur.execute(
                "UPDATE tasks SET status='failed', result=%s, updated_at=now() WHERE id=%s",
                (err, task_id),
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
```

- [ ] **Step 4: Write `worker.py`**

```python
import time

import config
import db


def process(payload: str) -> str:
    """Stand-in 'work': uppercase the payload. Replace with real logic."""
    return payload.upper()


def run_once(database: "db.Db", worker_id: str) -> bool:
    """One poll cycle. Returns True if a task was processed."""
    database.heartbeat(worker_id)
    row = database.claim_pending()
    if row is None:
        return False
    task_id, payload = row
    try:
        database.complete(task_id, process(payload))
    except Exception as exc:  # noqa: BLE001 — record failure, keep the loop alive
        database.fail(task_id, str(exc))
    return True


def main() -> None:
    cfg = config.load()
    database = db.Db(cfg.database_url)
    while True:
        worked = run_once(database, cfg.worker_id)
        if not worked:
            time.sleep(cfg.poll_interval)


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Write `test_worker.py` (unit-test the pure logic + cycle with a fake db)**

```python
import worker


class FakeDb:
    def __init__(self, rows):
        self.rows = list(rows)
        self.heartbeats = 0
        self.completed = {}

    def heartbeat(self, worker_id):
        self.heartbeats += 1

    def claim_pending(self):
        return self.rows.pop(0) if self.rows else None

    def complete(self, task_id, result):
        self.completed[task_id] = result

    def fail(self, task_id, err):
        self.completed[task_id] = "ERR:" + err


def test_process_uppercases():
    assert worker.process("hello") == "HELLO"


def test_run_once_processes_and_heartbeats():
    fake = FakeDb(rows=[(1, "abc")])
    worked = worker.run_once(fake, "w1")
    assert worked is True
    assert fake.heartbeats == 1
    assert fake.completed[1] == "ABC"


def test_run_once_idle_when_no_tasks():
    fake = FakeDb(rows=[])
    assert worker.run_once(fake, "w1") is False
    assert fake.heartbeats == 1
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd apps/worker && python -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt && pytest -v`
Expected: 3 passed

- [ ] **Step 7: Commit**

```bash
git add apps/worker/requirements.txt apps/worker/config.py apps/worker/db.py apps/worker/worker.py apps/worker/test_worker.py
git commit -m "feat(worker): python poller with heartbeat + tests"
```

---

### Task A6: Worker — Dockerfile (for parity / dev) + Windows note

**Files:**
- Create: `apps/worker/Dockerfile`
- Create: `apps/worker/README.md`

- [ ] **Step 1: Write `Dockerfile` (used for local/dev parity; prod runs as a Windows Service — see deploy/windows)**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN useradd -m worker
USER worker
ENTRYPOINT ["python", "worker.py"]
```

- [ ] **Step 2: Write `apps/worker/README.md` (explain the prod Windows-Service path)**

```markdown
# Worker

Polls the `tasks` table for `pending` rows, processes them, and writes a
`worker_heartbeat` row each cycle (the heartbeat is the worker's health signal,
read by the backend `/healthz` and by the frontend "worker online" indicator).

- **Local/dev:** run via Docker (`apps/worker/Dockerfile`) or directly with
  `DATABASE_URL=... python worker.py`.
- **Production (Windows server):** runs as a native Windows Service, not a
  container — see `deploy/windows/`. systemd/Quadlet are Linux-only, so the
  Windows worker is a deliberate separate track.
```

- [ ] **Step 3: Build to verify**

Run: `cd apps/worker && docker build -t hanomi-worker:dev .`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add apps/worker/Dockerfile apps/worker/README.md
git commit -m "feat(worker): dockerfile + windows-service note"
```

---

### Task A7: Frontend — Next.js app

**Files:**
- Create: `apps/frontend/package.json`
- Create: `apps/frontend/next.config.mjs`
- Create: `apps/frontend/tsconfig.json`
- Create: `apps/frontend/lib/api.ts`
- Create: `apps/frontend/app/layout.tsx`
- Create: `apps/frontend/app/page.tsx`
- Create: `apps/frontend/app/api/health/route.ts`

- [ ] **Step 1: Write `package.json`**

```json
{
  "name": "hanomi-frontend",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start -p ${PORT:-3000}"
  },
  "dependencies": {
    "next": "14.2.5",
    "react": "18.3.1",
    "react-dom": "18.3.1"
  },
  "devDependencies": {
    "typescript": "5.5.4",
    "@types/react": "18.3.3",
    "@types/node": "20.14.0"
  }
}
```

- [ ] **Step 2: Write `next.config.mjs` (standalone output for slim container)**

```javascript
/** @type {import('next').NextConfig} */
const nextConfig = { output: "standalone" };
export default nextConfig;
```

- [ ] **Step 3: Write `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "lib": ["dom", "dom.iterable", "esnext"],
    "module": "esnext",
    "moduleResolution": "bundler",
    "jsx": "preserve",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "noEmit": true,
    "incremental": true,
    "plugins": [{ "name": "next" }]
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
```

- [ ] **Step 4: Write `lib/api.ts` (server-side backend base URL from env)**

```typescript
// Backend base URL is provided by the reconciler-injected env at runtime.
// Server-only (used in server components / route handlers).
export const BACKEND_URL = process.env.BACKEND_URL ?? "http://localhost:8080";

export type Task = {
  id: number;
  payload: string;
  status: string;
  result: string | null;
  created_at: string;
  updated_at: string;
};

export async function listTasks(): Promise<Task[]> {
  const res = await fetch(`${BACKEND_URL}/tasks`, { cache: "no-store" });
  if (!res.ok) throw new Error(`backend ${res.status}`);
  return res.json();
}

export async function backendHealth(): Promise<{ status: string; worker_online: boolean }> {
  const res = await fetch(`${BACKEND_URL}/healthz`, { cache: "no-store" });
  if (!res.ok) throw new Error(`backend ${res.status}`);
  return res.json();
}
```

- [ ] **Step 5: Write `app/layout.tsx`**

```tsx
export const metadata = { title: "Hanomi Tasks" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: "system-ui, sans-serif", margin: 0, padding: 24 }}>
        {children}
      </body>
    </html>
  );
}
```

- [ ] **Step 6: Write `app/page.tsx` (task list + create form + worker-online badge)**

```tsx
import { listTasks, backendHealth } from "../lib/api";

async function createTask(formData: FormData) {
  "use server";
  const payload = String(formData.get("payload") ?? "");
  const { BACKEND_URL } = await import("../lib/api");
  await fetch(`${BACKEND_URL}/tasks`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ payload }),
  });
}

export default async function Page() {
  let tasks: Awaited<ReturnType<typeof listTasks>> = [];
  let workerOnline = false;
  let err = "";
  try {
    tasks = await listTasks();
    workerOnline = (await backendHealth()).worker_online;
  } catch (e) {
    err = String(e);
  }
  return (
    <main>
      <h1>Hanomi Tasks</h1>
      <p>
        Worker:{" "}
        <strong style={{ color: workerOnline ? "green" : "crimson" }}>
          {workerOnline ? "online" : "offline"}
        </strong>
      </p>
      <form action={createTask}>
        <input name="payload" placeholder="task payload" required />
        <button type="submit">Enqueue</button>
      </form>
      {err && <p style={{ color: "crimson" }}>Error: {err}</p>}
      <ul>
        {tasks.map((t) => (
          <li key={t.id}>
            #{t.id} [{t.status}] {t.payload}
            {t.result ? ` → ${t.result}` : ""}
          </li>
        ))}
      </ul>
    </main>
  );
}
```

- [ ] **Step 7: Write `app/api/health/route.ts` (reconciler health endpoint)**

```typescript
import { NextResponse } from "next/server";
import { backendHealth } from "../../../lib/api";

// Frontend is healthy if it is up AND can reach the backend.
export async function GET() {
  try {
    await backendHealth();
    return NextResponse.json({ status: "ok" });
  } catch {
    return NextResponse.json({ status: "backend_unreachable" }, { status: 503 });
  }
}
```

- [ ] **Step 8: Install, build, verify**

Run: `cd apps/frontend && npm install && npm run build`
Expected: Next.js build succeeds, `.next/standalone` produced.

- [ ] **Step 9: Commit**

```bash
git add apps/frontend
git commit -m "feat(frontend): next.js task UI + health route"
```

---

### Task A8: Frontend — Dockerfile

**Files:**
- Create: `apps/frontend/Dockerfile`
- Create: `apps/frontend/.dockerignore`

- [ ] **Step 1: Write `.dockerignore`**

```text
node_modules
.next
```

- [ ] **Step 2: Write `Dockerfile` (standalone, non-root)**

```dockerfile
FROM node:20-slim AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install
COPY . .
RUN npm run build

FROM node:20-slim AS run
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
EXPOSE 3000
USER node
CMD ["node", "server.js"]
```

- [ ] **Step 3: Build to verify**

Run: `cd apps/frontend && docker build -t hanomi-frontend:dev .`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add apps/frontend/Dockerfile apps/frontend/.dockerignore
git commit -m "feat(frontend): standalone Dockerfile"
```

---

### Task A9: Full local end-to-end verification

**Files:**
- Modify: `dev/docker-compose.yml` (add the three apps for an integration smoke test)

- [ ] **Step 1: Extend `dev/docker-compose.yml` with the apps**

```yaml
# Dev-only. Production uses Cloud SQL (private IP). See terraform/cloudsql.tf.
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: hanomi
      POSTGRES_PASSWORD: devpassword
      POSTGRES_DB: hanomi
    ports: ["5432:5432"]
    volumes: ["pgdata:/var/lib/postgresql/data"]
  backend:
    build: ../apps/backend
    environment:
      DATABASE_URL: postgres://hanomi:devpassword@postgres:5432/hanomi?sslmode=disable
    ports: ["8080:8080"]
    depends_on: [postgres]
  worker:
    build: ../apps/worker
    environment:
      DATABASE_URL: postgres://hanomi:devpassword@postgres:5432/hanomi?sslmode=disable
    depends_on: [postgres]
  frontend:
    build: ../apps/frontend
    environment:
      BACKEND_URL: http://backend:8080
    ports: ["3000:3000"]
    depends_on: [backend]
volumes:
  pgdata:
```

- [ ] **Step 2: Bring the stack up**

Run: `docker compose -f dev/docker-compose.yml up -d --build && sleep 10`
Expected: all four services running.

- [ ] **Step 3: Verify the end-to-end flow**

Run:
```bash
curl -s localhost:8080/healthz
curl -s -X POST localhost:8080/tasks -H 'content-type: application/json' -d '{"payload":"hello"}'
sleep 6
curl -s localhost:8080/tasks
```
Expected: `/healthz` → `{"status":"ok","worker_online":true}`; the created task transitions to `status:"done"` with `result:"HELLO"` after the worker picks it up.

- [ ] **Step 4: Tear down + commit**

```bash
docker compose -f dev/docker-compose.yml down
git add dev/docker-compose.yml
git commit -m "test: full local end-to-end compose smoke test"
```

---

## Phase B — VM Data Plane (reconcilers)

### Task B1: Linux reconciler (Quadlet + git-poll)

**Files:**
- Create: `deploy/linux/reconciler.sh`
- Create: `deploy/linux/hanomi-reconcile.service`
- Create: `deploy/linux/hanomi-reconcile.timer`
- Create: `deploy/linux/backend.container.tmpl`
- Create: `deploy/linux/frontend.container.tmpl`
- Create: `deploy/state/backend/desired.yaml`
- Create: `deploy/state/frontend/desired.yaml`
- Create: `deploy/state/worker/desired.yaml`

- [ ] **Step 1: Write the desired-state examples (`deploy/state/<svc>/desired.yaml`)**

`deploy/state/backend/desired.yaml`:
```yaml
service: backend
image: REGION-docker.pkg.dev/PROJECT/hanomi/backend@sha256:REPLACED_BY_CI
```
`deploy/state/frontend/desired.yaml`:
```yaml
service: frontend
image: REGION-docker.pkg.dev/PROJECT/hanomi/frontend@sha256:REPLACED_BY_CI
```
`deploy/state/worker/desired.yaml`:
```yaml
service: worker
image: REGION-docker.pkg.dev/PROJECT/hanomi/worker@sha256:REPLACED_BY_CI
```

- [ ] **Step 2: Write the Quadlet templates (`deploy/linux/backend.container.tmpl`)**

```ini
# Rendered by reconciler.sh: __IMAGE__ and __ENVFILE__ substituted, written to
# /etc/containers/systemd/backend.container, then `systemctl daemon-reload`.
[Unit]
Description=Hanomi backend
After=network-online.target

[Container]
Image=__IMAGE__
EnvironmentFile=__ENVFILE__
PublishPort=8080:8080
# Container-level self-heal: restart when the healthcheck reports unhealthy.
HealthCmd=wget -qO- http://localhost:8080/healthz || exit 1
HealthInterval=10s
HealthOnFailure=kill

[Service]
# systemd-level self-heal: restart on crash/exit.
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

`deploy/linux/frontend.container.tmpl` (same, port 3000, health path `/api/health`):
```ini
[Unit]
Description=Hanomi frontend
After=network-online.target

[Container]
Image=__IMAGE__
EnvironmentFile=__ENVFILE__
PublishPort=3000:3000
HealthCmd=wget -qO- http://localhost:3000/api/health || exit 1
HealthInterval=10s
HealthOnFailure=kill

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

- [ ] **Step 3: Write `deploy/linux/reconciler.sh`**

```bash
#!/usr/bin/env bash
# Linux reconciler. Runs on each Linux VM via a systemd timer (~60s).
# 1) git-pull the deploy-state repo  2) read desired image digest
# 3) if changed: fetch secrets, render+install the Quadlet unit, reload, restart
# 4) health-check  5) on failure roll back to last-good  6) report actual.json -> GCS
set -euo pipefail

SERVICE="${SERVICE:?set SERVICE=backend|frontend}"
STATE_REPO_DIR="/opt/hanomi/deploy-state"
QUADLET_DIR="/etc/containers/systemd"
ENVFILE="/etc/hanomi/${SERVICE}.env"
LASTGOOD="/var/lib/hanomi/${SERVICE}.lastgood"
GCS_STATE="gs://${STATE_BUCKET:?}/state/${SERVICE}/actual.json"
TMPL="/opt/hanomi/deploy/linux/${SERVICE}.container.tmpl"
case "$SERVICE" in
  backend)  HEALTH_URL="http://localhost:8080/healthz" ;;
  frontend) HEALTH_URL="http://localhost:3000/api/health" ;;
  *) echo "unknown service"; exit 2 ;;
esac

report() { # status sha err
  cat >/tmp/actual.json <<EOF
{"service":"${SERVICE}","sha":"${2}","healthy":${1},"error":"${3:-}"}
EOF
  gcloud storage cp /tmp/actual.json "$GCS_STATE" --quiet
}

# 1) sync desired state
git -C "$STATE_REPO_DIR" pull --quiet --ff-only
DESIRED_IMAGE="$(awk '/^image:/{print $2}' "$STATE_REPO_DIR/state/${SERVICE}/desired.yaml")"
CURRENT_IMAGE="$(cat "$LASTGOOD" 2>/dev/null || echo "")"
[ "$DESIRED_IMAGE" = "$CURRENT_IMAGE" ] && exit 0   # converged, nothing to do

deploy_image() { # image
  local img="$1"
  # 2) fetch secrets fresh -> 0600 env file owned by root
  install -m 0600 /dev/null "$ENVFILE"
  gcloud secrets versions access latest \
    --secret="hanomi-${SERVICE}-env" > "$ENVFILE"
  # 3) render + install Quadlet unit
  sed -e "s#__IMAGE__#${img}#g" -e "s#__ENVFILE__#${ENVFILE}#g" \
      "$TMPL" > "${QUADLET_DIR}/${SERVICE}.container"
  systemctl daemon-reload
  systemctl restart "${SERVICE}.service"
}

healthy() {
  for _ in $(seq 1 30); do
    if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# 3) deploy desired
deploy_image "$DESIRED_IMAGE"
# 4) health-check
if healthy; then
  echo "$DESIRED_IMAGE" > "$LASTGOOD"
  report true "$DESIRED_IMAGE" ""
  exit 0
fi

# 5) rollback to last-good (if any)
if [ -n "$CURRENT_IMAGE" ]; then
  deploy_image "$CURRENT_IMAGE"
  if healthy; then
    report false "$CURRENT_IMAGE" "deploy_failed_rolled_back"
    exit 1
  fi
fi
# 6) could not recover -> degraded, freeze, alert via CI gate
report false "$DESIRED_IMAGE" "degraded_rollback_failed"
exit 1
```

- [ ] **Step 4: Write the systemd timer + service**

`deploy/linux/hanomi-reconcile.service`:
```ini
[Unit]
Description=Hanomi reconciler (one-shot)
After=network-online.target

[Service]
Type=oneshot
Environment=SERVICE=%i
EnvironmentFile=/etc/hanomi/reconcile.env
ExecStart=/opt/hanomi/deploy/linux/reconciler.sh
```

`deploy/linux/hanomi-reconcile.timer`:
```ini
[Unit]
Description=Run Hanomi reconciler every 60s

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=hanomi-reconcile@%i.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 5: Lint the bash + commit**

Run: `bash -n deploy/linux/reconciler.sh && shellcheck deploy/linux/reconciler.sh || true`
Expected: no syntax errors (shellcheck warnings acceptable).

```bash
git add deploy/linux deploy/state
git commit -m "feat(deploy): linux quadlet reconciler + desired-state"
```

---

### Task B2: Windows worker reconciler + service install

**Files:**
- Create: `deploy/windows/reconciler.ps1`
- Create: `deploy/windows/install-service.ps1`
- Create: `deploy/windows/bootstrap.ps1`

- [ ] **Step 1: Write `deploy/windows/bootstrap.ps1` (one-time VM setup)**

```powershell
# One-time bootstrap for the Windows worker VM (invoked by Terraform metadata
# startup-script / sysprep). Installs Python, clones deploy-state, registers the
# reconciler scheduled task. Idempotent.
param([string]$StateRepoUrl, [string]$StateBucket)

$ErrorActionPreference = "Stop"
$base = "C:\hanomi"
New-Item -ItemType Directory -Force -Path $base | Out-Null

# Python via winget (present on Server 2022+); fallback to choco if needed.
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
  winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
}

if (-not (Test-Path "$base\deploy-state")) {
  git clone $StateRepoUrl "$base\deploy-state"
}

[Environment]::SetEnvironmentVariable("STATE_BUCKET", $StateBucket, "Machine")

# Register the reconciler to run every 60s.
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-ExecutionPolicy Bypass -File C:\hanomi\deploy-state\deploy\windows\reconciler.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Seconds 60)
Register-ScheduledTask -TaskName "HanomiReconcile" -Action $action -Trigger $trigger `
  -RunLevel Highest -User "SYSTEM" -Force
```

- [ ] **Step 2: Write `deploy/windows/reconciler.ps1`**

```powershell
# Windows worker reconciler. Runs every 60s via Scheduled Task.
# Mirrors the Linux reconciler: pull desired state, converge the worker (run as
# a native Windows Service), self-heal/rollback, report actual.json to GCS.
$ErrorActionPreference = "Stop"
$base       = "C:\hanomi"
$stateRepo  = "$base\deploy-state"
$svcName    = "HanomiWorker"
$lastGood   = "$base\worker.lastgood"
$bucket     = [Environment]::GetEnvironmentVariable("STATE_BUCKET", "Machine")
$gcsState   = "gs://$bucket/state/worker/actual.json"

function Report($healthy, $sha, $err) {
  $obj = @{ service = "worker"; sha = $sha; healthy = $healthy; error = $err } | ConvertTo-Json -Compress
  Set-Content -Path "$env:TEMP\actual.json" -Value $obj
  & gcloud storage cp "$env:TEMP\actual.json" $gcsState --quiet
}

function Worker-Healthy {
  # Healthy if the service is Running AND wrote a heartbeat row in the last 60s.
  $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
  if ($null -eq $svc -or $svc.Status -ne "Running") { return $false }
  $age = & python "$stateRepo\deploy\windows\heartbeat_age.py"
  return ([int]$age -lt 60)
}

# 1) sync desired
& git -C $stateRepo pull --quiet --ff-only
$desired = (Select-String -Path "$stateRepo\state\worker\desired.yaml" -Pattern '^image:\s*(.+)$').Matches.Groups[1].Value.Trim()
$current = if (Test-Path $lastGood) { Get-Content $lastGood } else { "" }
if ($desired -eq $current) { exit 0 }

function Deploy-Worker($image) {
  # Fetch secrets -> machine env; (re)install + restart the Windows Service.
  & gcloud secrets versions access latest --secret="hanomi-worker-env" |
    Out-File -Encoding ascii "$base\worker.env"
  & "$stateRepo\deploy\windows\install-service.ps1" -Image $image
  Restart-Service -Name $svcName -ErrorAction SilentlyContinue
}

Deploy-Worker $desired
Start-Sleep -Seconds 8
if (Worker-Healthy) {
  Set-Content -Path $lastGood -Value $desired
  Report $true $desired ""
  exit 0
}
if ($current -ne "") {
  Deploy-Worker $current
  Start-Sleep -Seconds 8
  if (Worker-Healthy) { Report $false $current "deploy_failed_rolled_back"; exit 1 }
}
Report $false $desired "degraded_rollback_failed"
exit 1
```

- [ ] **Step 3: Write `deploy/windows/install-service.ps1` + `heartbeat_age.py`**

`deploy/windows/install-service.ps1`:
```powershell
# Installs/updates the worker as a native Windows Service.
# The worker runs the pinned Python code; the image digest is recorded for
# rollback parity even though Windows runs it as a process, not a container.
param([string]$Image)
$ErrorActionPreference = "Stop"
$base = "C:\hanomi"
$src  = "$base\worker-src"

# Pull the pinned worker source for this digest from the artifact bucket.
& gcloud storage rsync -r "gs://$($env:ARTIFACT_BUCKET)/worker/$Image" $src

$py = (Get-Command python).Source
$bin = "`"$py`" `"$src\worker.py`""
# Use sc.exe to create/update the service (built-in; no third-party tools).
if (-not (Get-Service -Name "HanomiWorker" -ErrorAction SilentlyContinue)) {
  & sc.exe create HanomiWorker binPath= $bin start= auto | Out-Null
}
& sc.exe config HanomiWorker binPath= $bin | Out-Null
# Auto-restart on failure (Windows SCM recovery = self-heal).
& sc.exe failure HanomiWorker reset= 60 actions= restart/5000/restart/5000/restart/5000 | Out-Null
```

`deploy/windows/heartbeat_age.py`:
```python
"""Print seconds since the worker's last heartbeat (used by reconciler health)."""
import os
import sys

import psycopg

dsn = open(r"C:\hanomi\worker.env").read().split("DATABASE_URL=", 1)[-1].strip()
with psycopg.connect(dsn, autocommit=True) as conn, conn.cursor() as cur:
    cur.execute("SELECT EXTRACT(EPOCH FROM now() - max(last_seen)) FROM worker_heartbeat")
    row = cur.fetchone()
    print(int(row[0]) if row and row[0] is not None else 999999)
```

- [ ] **Step 4: Syntax-check (PowerShell parse) + commit**

Run: `pwsh -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('deploy/windows/reconciler.ps1',[ref]$null,[ref]$null); 'ok'" 2>/dev/null || echo "pwsh not present — skip"`
Expected: `ok` (or skip note if pwsh absent).

```bash
git add deploy/windows
git commit -m "feat(deploy): windows worker reconciler + service install"
```

---

## Phase C — Terraform (GCP infra)

> One `google` provider. Variables for project/region. State local for the
> take-home (note in README that prod uses a GCS backend).

### Task C1: Variables, provider, network

**Files:**
- Create: `terraform/versions.tf`
- Create: `terraform/variables.tf`
- Create: `terraform/network.tf`
- Create: `terraform/terraform.tfvars.example`

- [ ] **Step 1: Write `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.40" }
  }
}
provider "google" {
  project = var.project_id
  region  = var.region
}
```

- [ ] **Step 2: Write `variables.tf`**

```hcl
variable "project_id" { type = string }
variable "region"     { type = string  default = "asia-south1" }
variable "zone"       { type = string  default = "asia-south1-a" }
variable "github_repo" {
  type        = string
  description = "owner/repo of the parent repo, for WIF subject binding"
}
variable "state_repo_url" {
  type        = string
  description = "https URL of the deploy-state repo the reconcilers pull"
}
```

- [ ] **Step 3: Write `network.tf` (VPC, subnet, NAT, firewall, PSA)**

```hcl
resource "google_compute_network" "vpc" {
  name                    = "hanomi-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "hanomi-subnet"
  ip_cidr_range            = "10.0.1.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true # VMs reach Google APIs without external IPs
}

# Egress for VMs with no external IP (image pulls, gcloud, apt).
resource "google_compute_router" "router" {
  name    = "hanomi-router"
  region  = var.region
  network = google_compute_network.vpc.id
}
resource "google_compute_router_nat" "nat" {
  name                               = "hanomi-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Default-deny inbound (no ingress rules = denied). Allow only intra-VPC + GCP health checks.
resource "google_compute_firewall" "allow_internal" {
  name      = "hanomi-allow-internal"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  allow { protocol = "tcp" ports = ["8080", "3000"] }
  source_ranges = ["10.0.1.0/24"]
}

# Private Services Access for Cloud SQL private IP.
resource "google_compute_global_address" "psa_range" {
  name          = "hanomi-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}
resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]
}
```

- [ ] **Step 4: Write `terraform.tfvars.example` + validate**

```hcl
project_id     = "your-gcp-project"
region         = "asia-south1"
zone           = "asia-south1-a"
github_repo    = "your-org/hanomi"
state_repo_url = "https://github.com/your-org/hanomi-deploy-state.git"
```

Run: `cd terraform && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add terraform/versions.tf terraform/variables.tf terraform/network.tf terraform/terraform.tfvars.example
git commit -m "feat(tf): vpc, subnet, nat, firewall, private services access"
```

---

### Task C2: Cloud SQL, Artifact Registry, GCS, Secret Manager

**Files:**
- Create: `terraform/cloudsql.tf`
- Create: `terraform/artifact.tf`
- Create: `terraform/gcs.tf`
- Create: `terraform/secrets.tf`

- [ ] **Step 1: Write `cloudsql.tf` (private IP only)**

```hcl
resource "google_sql_database_instance" "pg" {
  name                = "hanomi-pg"
  database_version    = "POSTGRES_16"
  region              = var.region
  depends_on          = [google_service_networking_connection.psa]
  deletion_protection = false
  settings {
    tier = "db-custom-1-3840"
    ip_configuration {
      ipv4_enabled    = false # NO public IP
      private_network = google_compute_network.vpc.id
    }
    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }
  }
}
resource "google_sql_database" "db" {
  name     = "hanomi"
  instance = google_sql_database_instance.pg.name
}
```

- [ ] **Step 2: Write `artifact.tf`**

```hcl
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "hanomi"
  format        = "DOCKER"
}
```

- [ ] **Step 3: Write `gcs.tf` (state bucket; versioned for audit)**

```hcl
resource "google_storage_bucket" "state" {
  name                        = "${var.project_id}-hanomi-state"
  location                    = var.region
  uniform_bucket_level_access = true
  versioning { enabled = true }
}
```

- [ ] **Step 4: Write `secrets.tf` (one env secret per service)**

```hcl
locals { services = ["backend", "frontend", "worker"] }

resource "google_secret_manager_secret" "env" {
  for_each  = toset(local.services)
  secret_id = "hanomi-${each.key}-env"
  replication { auto {} }
}
# NOTE: secret *versions* (actual values) are added out-of-band, never in TF state.
```

- [ ] **Step 5: Validate + commit**

Run: `cd terraform && terraform validate`
Expected: valid.

```bash
git add terraform/cloudsql.tf terraform/artifact.tf terraform/gcs.tf terraform/secrets.tf
git commit -m "feat(tf): cloud sql (private), artifact registry, gcs, secrets"
```

---

### Task C3: Service accounts, IAM, VMs, WIF

**Files:**
- Create: `terraform/iam.tf`
- Create: `terraform/instances.tf`
- Create: `terraform/wif.tf`
- Create: `terraform/outputs.tf`

- [ ] **Step 1: Write `iam.tf` (per-service SA, least privilege)**

```hcl
resource "google_service_account" "svc" {
  for_each     = toset(local.services)
  account_id   = "hanomi-${each.key}"
  display_name = "Hanomi ${each.key} VM"
}

# Each VM SA may read ONLY its own service's secret.
resource "google_secret_manager_secret_iam_member" "read_own" {
  for_each  = toset(local.services)
  secret_id = google_secret_manager_secret.env[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.svc[each.key].email}"
}

# All VM SAs may pull images and read/write their actual.json + Cloud SQL client.
resource "google_project_iam_member" "vm_roles" {
  for_each = {
    for pair in setproduct(local.services, [
      "roles/artifactregistry.reader",
      "roles/storage.objectAdmin",
      "roles/cloudsql.client",
      "roles/cloudsql.instanceUser",
    ]) : "${pair[0]}-${pair[1]}" => { svc = pair[0], role = pair[1] }
  }
  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.svc[each.value.svc].email}"
}
```

- [ ] **Step 2: Write `instances.tf` (3 VMs, no external IP)**

```hcl
locals {
  linux_image   = "projects/debian-cloud/global/images/family/debian-12"
  windows_image = "projects/windows-cloud/global/images/family/windows-2022"
}

resource "google_compute_instance" "linux" {
  for_each     = toset(["backend", "frontend"])
  name         = "hanomi-${each.key}"
  machine_type = "e2-small"
  zone         = var.zone
  boot_disk { initialize_params { image = local.linux_image } }
  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    # No access_config block => NO external IP.
  }
  service_account {
    email  = google_service_account.svc[each.key].email
    scopes = ["cloud-platform"]
  }
  metadata = {
    SERVICE        = each.key
    STATE_BUCKET   = google_storage_bucket.state.name
    state-repo-url = var.state_repo_url
  }
  # cloud-init installs podman+git, clones state, enables the reconcile timer.
  metadata_startup_script = templatefile("${path.module}/../deploy/linux/startup.sh.tftpl", {
    service        = each.key
    state_repo_url = var.state_repo_url
    state_bucket   = google_storage_bucket.state.name
  })
}

resource "google_compute_instance" "windows" {
  name         = "hanomi-worker"
  machine_type = "e2-medium"
  zone         = var.zone
  boot_disk { initialize_params { image = local.windows_image } }
  network_interface { subnetwork = google_compute_subnetwork.subnet.id }
  service_account {
    email  = google_service_account.svc["worker"].email
    scopes = ["cloud-platform"]
  }
  metadata = {
    windows-startup-script-ps1 = templatefile("${path.module}/../deploy/windows/startup.ps1.tftpl", {
      state_repo_url = var.state_repo_url
      state_bucket   = google_storage_bucket.state.name
    })
  }
}
```

- [ ] **Step 3: Write the startup templates referenced above**

`deploy/linux/startup.sh.tftpl`:
```bash
#!/usr/bin/env bash
set -euo pipefail
apt-get update -y && apt-get install -y podman git curl
install -d /opt/hanomi /etc/hanomi /var/lib/hanomi
git clone ${state_repo_url} /opt/hanomi/deploy-state || true
ln -sfn /opt/hanomi/deploy-state/deploy /opt/hanomi/deploy
cat >/etc/hanomi/reconcile.env <<EOF
SERVICE=${service}
STATE_BUCKET=${state_bucket}
EOF
cp /opt/hanomi/deploy/linux/hanomi-reconcile.service /etc/systemd/system/hanomi-reconcile@.service
cp /opt/hanomi/deploy/linux/hanomi-reconcile.timer  /etc/systemd/system/hanomi-reconcile@.timer
systemctl daemon-reload
systemctl enable --now hanomi-reconcile@${service}.timer
```

`deploy/windows/startup.ps1.tftpl`:
```powershell
& "C:\hanomi\deploy-state\deploy\windows\bootstrap.ps1" -StateRepoUrl "${state_repo_url}" -StateBucket "${state_bucket}"
```

- [ ] **Step 4: Write `wif.tf` (GitHub OIDC → CI service account)**

```hcl
resource "google_service_account" "ci" {
  account_id   = "hanomi-ci"
  display_name = "Hanomi GitHub Actions"
}
resource "google_iam_workload_identity_pool" "gh" {
  workload_identity_pool_id = "hanomi-gh-pool"
}
resource "google_iam_workload_identity_pool_provider" "gh" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.gh.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  attribute_condition = "assertion.repository == \"${var.github_repo}\""
  oidc { issuer_uri = "https://token.actions.githubusercontent.com" }
}
# Only this repo may impersonate the CI SA.
resource "google_service_account_iam_member" "wif_bind" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gh.name}/attribute.repository/${var.github_repo}"
}
# CI may push images + write desired state (commit happens in Git, not here) + read actual.json.
resource "google_project_iam_member" "ci_roles" {
  for_each = toset([
    "roles/artifactregistry.writer",
    "roles/storage.objectViewer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ci.email}"
}
```

- [ ] **Step 5: Write `outputs.tf`**

```hcl
output "ci_service_account" { value = google_service_account.ci.email }
output "wif_provider" {
  value = google_iam_workload_identity_pool_provider.gh.name
}
output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}"
}
output "state_bucket" { value = google_storage_bucket.state.name }
output "cloudsql_private_ip" { value = google_sql_database_instance.pg.private_ip_address }
```

- [ ] **Step 6: Validate + commit**

Run: `cd terraform && terraform validate`
Expected: valid.

```bash
git add terraform/iam.tf terraform/instances.tf terraform/wif.tf terraform/outputs.tf deploy/linux/startup.sh.tftpl deploy/windows/startup.ps1.tftpl
git commit -m "feat(tf): per-service SAs, 3 VMs (no public IP), WIF, outputs"
```

---

## Phase D — CI Workflow + README

### Task D1: GitHub Actions deploy workflow

**Files:**
- Create: `.github/workflows/deploy.yml`

- [ ] **Step 1: Write `.github/workflows/deploy.yml`**

```yaml
name: deploy
on:
  push:
    branches: [main]

permissions:
  contents: write   # to commit digests to the deploy-state repo
  id-token: write   # for Workload Identity Federation

env:
  REGION: asia-south1
  PROJECT: ${{ vars.GCP_PROJECT }}
  REGISTRY: asia-south1-docker.pkg.dev/${{ vars.GCP_PROJECT }}/hanomi
  STATE_BUCKET: ${{ vars.STATE_BUCKET }}

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      backend:  ${{ steps.f.outputs.backend }}
      worker:   ${{ steps.f.outputs.worker }}
      frontend: ${{ steps.f.outputs.frontend }}
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive, fetch-depth: 0 }
      - id: f
        uses: dorny/paths-filter@v3
        with:
          filters: |
            backend:  ['apps/backend/**']
            worker:   ['apps/worker/**']
            frontend: ['apps/frontend/**']

  deploy:
    needs: changes
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }

      - id: auth
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER }}
          service_account: ${{ vars.CI_SA }}

      - uses: google-github-actions/setup-gcloud@v2
      - run: gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet

      # Build-once + digest-pin + gated rollout, in order: backend -> worker -> frontend.
      - name: Rollout
        run: ./.github/scripts/rollout.sh
        env:
          DEPLOY_BACKEND:  ${{ needs.changes.outputs.backend }}
          DEPLOY_WORKER:   ${{ needs.changes.outputs.worker }}
          DEPLOY_FRONTEND: ${{ needs.changes.outputs.frontend }}
          STATE_REPO_TOKEN: ${{ secrets.STATE_REPO_TOKEN }}
```

- [ ] **Step 2: Write `.github/scripts/rollout.sh` (the gated orchestration)**

```bash
#!/usr/bin/env bash
# Build-once, digest-pin, commit-to-state, then gate on actual.json.
# Order enforces backend -> worker -> frontend; a failed gate stops the rollout.
set -euo pipefail

STATE_REPO_DIR="$(mktemp -d)"
git clone "https://x-access-token:${STATE_REPO_TOKEN}@github.com/${GITHUB_REPOSITORY%/*}/hanomi-deploy-state.git" "$STATE_REPO_DIR"

build_push() { # service
  local svc="$1" sha="${GITHUB_SHA}"
  docker build -t "${REGISTRY}/${svc}:${sha}" "apps/${svc}"
  docker push "${REGISTRY}/${svc}:${sha}"
  # Resolve the immutable digest we just pushed.
  docker inspect --format='{{index .RepoDigests 0}}' "${REGISTRY}/${svc}:${sha}"
}

set_desired() { # service image@digest
  local svc="$1" img="$2"
  printf 'service: %s\nimage: %s\n' "$svc" "$img" > "${STATE_REPO_DIR}/state/${svc}/desired.yaml"
  git -C "$STATE_REPO_DIR" add -A
  git -C "$STATE_REPO_DIR" -c user.email=ci@hanomi -c user.name=ci \
    commit -m "deploy(${svc}): ${img}"
  git -C "$STATE_REPO_DIR" push
}

gate() { # service  — poll actual.json until healthy or timeout
  local svc="$1" deadline=$(( SECONDS + 300 ))
  while (( SECONDS < deadline )); do
    if gcloud storage cat "gs://${STATE_BUCKET}/state/${svc}/actual.json" 2>/dev/null \
        | grep -q '"healthy":true'; then
      echo "✅ ${svc} healthy"; return 0
    fi
    sleep 10
  done
  echo "❌ ${svc} did not become healthy — rollout halted"
  gcloud storage cat "gs://${STATE_BUCKET}/state/${svc}/actual.json" || true
  return 1
}

rollout() { # service flag
  local svc="$1" flag="$2"
  [ "$flag" = "true" ] || { echo "⏭  ${svc} unchanged"; return 0; }
  echo "▶ deploying ${svc}"
  local img; img="$(build_push "$svc")"
  set_desired "$svc" "$img"
  gate "$svc"   # non-zero return aborts the script (set -e), leaving later services untouched
}

# Sequential, fail-fast. If worker fails, frontend is never touched (partial-rollout policy).
rollout backend  "${DEPLOY_BACKEND}"
rollout worker   "${DEPLOY_WORKER}"
rollout frontend "${DEPLOY_FRONTEND}"
echo "🎉 rollout complete"
```

- [ ] **Step 3: Lint workflow YAML + bash**

Run: `bash -n .github/scripts/rollout.sh && python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/deploy.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
chmod +x .github/scripts/rollout.sh
git add .github/workflows/deploy.yml .github/scripts/rollout.sh
git commit -m "feat(ci): WIF auth + build-once + gated sequential rollout"
```

---

### Task D2: README (the 1–2 page deliverable)

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`** covering, in order:
  1. **What this is** — one-paragraph summary + the control-plane/data-plane one-liner.
  2. **Architecture diagram** (the ASCII diagram from the spec).
  3. **Tool choices & tradeoffs** table (from spec §4 + §10), including the
     **konlet-deprecation finding** with the 2026-07-31 cutoff and why Quadlet
     was chosen instead.
  4. **Deploy flow** (spec §5) + **how to deploy / rollback** commands.
  5. **Rollback & partial-failure matrix** — a table with rows: backend fails /
     worker fails / frontend fails / rollback itself fails, and the resulting
     state per service.
  6. **Secrets handling** (spec §7).
  7. **Networking** — VPC/subnet/NAT/PSA, no public IPs, private Cloud SQL.
  8. **The demo apps** (spec §8) + how to run them locally
     (`docker compose -f dev/docker-compose.yml up`).
  9. **AWS→GCP migration mapping** (spec §11) + the Jenkins lift-and-shift note.
  10. **AI tools used** — note that Claude (Opus) was used for architecture
      brainstorming, the deep-research pass on VM reconcilers (which surfaced the
      konlet deprecation), and code/config scaffolding; all decisions reviewed
      and chosen by the author.
  11. **Known limitations / YAGNI** (spec §12): single-VM restart blip, local TF
      state, poll-interval latency.

- [ ] **Step 2: Verify it renders + length sanity**

Run: `wc -w README.md`
Expected: roughly 900–1400 words (≈1–2 pages).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README — architecture, tradeoffs, failure matrix, migration notes, AI usage"
```

---

## Self-Review Notes (already applied)

- **Spec coverage:** rollback (B1/B2 + D1), health checks (A3/B1/B2), secrets
  (A1 config, secrets.tf, reconciler fetch), partial failure (rollout.sh order +
  reconciler rollback + README matrix), VPC/subnets (network.tf), Cloud SQL
  private (cloudsql.tf), 3 VMs no public IP (instances.tf), WIF (wif.tf), apps
  (A1–A8), migration mapping (D2). All covered.
- **No placeholders:** all code blocks are complete; `REPLACED_BY_CI` /
  `PROJECT` / `REGION` tokens in `desired.yaml` are intentional substitution
  markers, not plan gaps.
- **Type consistency:** `Store` methods (`Migrate`, `CreateTask`, `ListTasks`,
  `GetTask`, `Ping`, `WorkerLastSeen`) are used consistently across A2/A3;
  `run_once(db, worker_id)` signature matches between `worker.py` and tests;
  reconciler `actual.json` shape `{service,sha,healthy,error}` is identical in
  B1, B2, and the D1 `gate()` grep.
```
