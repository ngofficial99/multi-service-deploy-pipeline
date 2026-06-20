# Hanomi Deploy Pipeline — Complete Design & Build Document

Everything that was built, every decision and why, every tool, and how it works
from each perspective (developer, CI/CD, operator, security, scale). This is the
deep reference; `README.md` is the 1–2 page summary and `WALKTHROUGH.md` is the
plain-English tour.

---

## 0. The brief, restated

Design and partially implement a deploy pipeline for a 3-service "Hanomi" stack:
backend (Go, Linux), frontend (Next.js, Linux), worker (Python, **Windows**).
Trigger = merge to `main`. Each service deploys to **its own VM (not K8s)**.
Must cover: rollback, health checks, secrets, and partial-failure behaviour.
Cloud chosen: **GCP** (the hiring context is an AWS→GCP migration).

We went beyond "partially implement": the whole thing was **deployed live on a
real GCP project and debugged end-to-end**, plus a production autoscaling design.

---

## 1. The central idea (one paragraph)

CI never logs into servers. On merge to `main`, GitHub Actions builds a
**digest-pinned** container image and writes the desired version into a separate
**Git repo** (`hanomi-deploy-state`). Each VM runs a small **reconciler** that
polls that repo (~60s), converges its service to the declared digest,
health-checks itself, and reports actual state back to a GCS object. This is a
**GitOps control-plane / data-plane split** — the same shape as a cloud
provision manager. It eliminates SSH keys, bastions, and inbound ports, and
behaves identically whether there is 1 instance or 100.

---

## 2. Architecture (full)

```
 GitHub: parent repo + 3 submodules ── merge→main ──► GitHub Actions (control plane)
   │                                                      │ Workload Identity Federation (no static keys)
   │ build image once → push (digest-pinned)              ▼
   │ commit new digest → deploy-state repo          ┌──────────── GCP project ─────────────┐
   ▼                                                │ Artifact Registry: <svc>@sha256:…     │
 deploy-state repo (GitOps desired state)           │ Secret Manager: hanomi/<svc>/*        │
   backend/desired.yaml  → image@sha256             │ GCS: state/<svc>/actual.json (gate)   │
   worker/desired.yaml   → image@sha256             │ GCS: worker/<digest>/ (win source)    │
   frontend/desired.yaml → image@sha256             │                                       │
        ▲ reconcilers (~60s)                        │ ┌──────── VPC (custom) ────────────┐  │
        │                                           │ │ Private Google Access + Cloud NAT │  │
        └───────────── pulled by ───────────────────┼─┤ NO external IPs on any VM         │  │
                                                     │ │  backend  VM (Linux)  podman+systemd│
                                                     │ │  frontend VM (Linux)  podman+systemd│
                                                     │ │  worker   VM (Windows) scheduled task│
                                                     │ │  external L7 LB ─► frontend         │
                                                     │ │  Private Services Access            │
                                                     │ │   └ Cloud SQL Postgres (PRIVATE IP) │
                                                     │ └───────────────────────────────────┘ │
                                                     └────────────────────────────────────────┘
```

---

## 3. The demo apps (so every requirement is real, not hypothetical)

A faithful slice of Hanomi's product: a marketing landing page with a "Try
Hanomi" demo-request form, lead capture, and an automated welcome email.

- **frontend** (`apps/frontend`, Next.js 14 App Router): the Hanomi landing page
  (real copy: "CAD to 2D in minutes", the 3-step process, GD&T/ASME/ISO), a
  dedicated `/try` page whose form fields match the real site (first name,
  phone, email, company). The form posts to a Next.js route handler
  (`/api/leads`) which proxies to the backend — so the internal backend URL is
  never exposed to the browser. `/api/health` is the health endpoint.
- **backend** (`apps/backend`, Go + Gin): `POST /leads`, `GET /leads`,
  `GET /leads/:id`, `GET /healthz`. Persists leads to Cloud SQL. Embeds
  golang-migrate migrations (run fail-closed on startup).
- **worker** (`apps/worker`, Python): polls `leads` for `pending` rows using
  `SELECT … FOR UPDATE SKIP LOCKED` (so N workers never double-process), "sends"
  the Hanomi welcome email, sets `status='emailed', invite_sent=true,
  invite_sent_at=now()`, and writes a `worker_heartbeat` row each cycle.
- **Database** (Cloud SQL Postgres 16, private IP): tables `leads` and
  `worker_heartbeat`. The DB *is* the queue — backend and worker never call each
  other; they coordinate through Postgres. This is the standard, scalable
  DB-as-queue pattern.
- **Email**: pluggable sender. With no SMTP config it writes the rendered email
  to a local outbox (the demo runs with zero external accounts); set `SMTP_*`
  (from Secret Manager) and it sends for real (e.g. Brevo free tier).

`invite_sent` / `invite_sent_at` columns give an auditable "was this person
invited?" signal, separate from the processing `status`.

---

## 4. Every decision and why

| Decision | Choice | Why | Alternatives rejected |
|---|---|---|---|
| Cloud | **GCP** | Hiring context is AWS→GCP migration; demonstrate current GCP depth | AWS (the AWS↔GCP mapping is documented instead) |
| Orchestrator | **GitHub Actions** | Native merge-to-main trigger, self-contained, WIF auth | Jenkins (noted as the lift-and-shift path if their estate is Jenkins) |
| CI→cloud auth | **Workload Identity Federation** | Short-lived OIDC tokens, **zero stored keys** | Service-account JSON keys (long-lived secret, rejected) |
| Desired state | **GitOps repo** | Deploy = commit (audit trail); rollback = `git revert`; reviewable | Desired state in GCS only (loses git history/audit) |
| Change signal | **Git poll ~60s** | The GitOps invariant; self-healing (corrects drift with no push) | Pub/Sub push (rejected as over-engineering for 3 VMs) |
| Cross-repo push auth | **SSH deploy key** scoped to deploy-state | Tightly scoped to one repo; unambiguous vs the main-repo `GITHUB_TOKEN` | Fine-grained PAT (hit a 403 + scoping pitfalls live) |
| Linux container runtime | **Podman + generated systemd unit** | `Restart=always` self-heal; works on any Podman version | GCP konlet (**deprecated, 2026 cutoff**); Quadlet (needs Podman ≥4.4; Debian 12 has 4.3.1) |
| Windows worker runtime | **SYSTEM scheduled task** running Python | A bare `python.exe` can't be an `sc.exe` service (error 1053); scheduled task fits a polling loop | `sc.exe` service (failed); Windows containers (heavy) |
| Image versioning | **Immutable digest (`@sha256`)** | Deterministic rollback, no rebuild | Moving tags / `podman auto-update` (conflicts with digest pinning) |
| Actual/health state | VM writes `actual.json` to **GCS** | Git=desired, GCS=actual; no Git *write* creds on VMs | VMs committing status to Git (commit races, noisy) |
| DB | **Cloud SQL Postgres, private IP** | No public endpoint; reached over Private Services Access | Public IP + authorized networks (weaker) |
| DB connection from VM | metadata-SA token → IAM/password from Secret Manager | No creds on the wire; least privilege | Hardcoded DB creds (rejected) |
| Migrations | **golang-migrate, fail-closed, on startup** | Bad migration aborts deploy; backward-compatible keeps rollback safe | Auto-migrate races / manual migrations |
| IaC | **Terraform** | Portable, lingua franca, relevant to a migration | Deployment Manager / Config Connector |
| Backend→backend addressing | **GCE internal DNS name** | Survives VM recreation (a hardcoded IP broke live) | Hardcoded internal IP (rejected after it broke) |
| Pool sizing | **Bounded pgx pool** (`DB_MAX_CONNS`) | N instances × cap ≤ DB max_connections — makes horizontal scaling safe | Unbounded default pool (exhausts DB at scale) |
| Read scaling | **Read/write split** + Cloud SQL read replicas | Reads → replicas (round-robin), writes → primary | Single DB for everything (caps read throughput) |
| Scale unit | **Regional Managed Instance Group + autoscaler** per service | The GCP equivalent of an AWS ASG; one per service, independent | Single VM (SPOF, can't scale) — used for the literal brief, MIGs for production |
| Worker scaling signal | **queue depth** (pending leads custom metric) | A pull consumer scales on backlog, not CPU; can scale to 0 | CPU (wrong: a backed-up queue can be low-CPU) |
| HTTPS | Managed cert gated on `var.domain` | Real cert when a domain is set; no fake certs | Self-signed (browser warnings) |

---

## 5. Tools used (and their role)

- **Terraform** (hashicorp/google ~5.40) — all infra: VPC/subnet/NAT/firewall,
  Private Services Access, Cloud SQL, Compute Engine VMs, Artifact Registry,
  GCS, Secret Manager, Workload Identity Federation, IAM, the external LB, and
  the production scaling module (MIGs, autoscalers, internal LB, read replicas).
- **GitHub Actions** — the control plane (`.github/workflows/deploy.yml` +
  `.github/scripts/rollout.sh`).
- **Podman** — container runtime on the Linux VMs, run under generated systemd
  units.
- **systemd** — supervises the Linux containers (`Restart=always`) + runs the
  reconciler on a 60s timer.
- **Windows Scheduled Tasks** — run the worker + its reconciler on the Windows VM.
- **Cloud SQL Postgres 16** — the shared datastore / job queue.
- **gcloud CLI** — used on the VMs (secrets fetch, GCS read/write, registry
  auth) and for the live deploy/debug.
- **Go + Gin + pgx + golang-migrate** (backend); **Python + psycopg** (worker);
  **Next.js 14** (frontend).
- **AI: Claude Code** — architecture brainstorming, a fact-checked deep-research
  pass (which surfaced the konlet deprecation), code/config scaffolding, and the
  live end-to-end debugging. See `AI_USAGE.md`.

---

## 6. The flow, from each perspective

### 6a. Developer perspective
1. You change code in `apps/<service>` and merge to `main`.
2. That's it. You never touch a server, a key, or a deploy script. The live
   system converges to your commit (proven: a one-line hero change reached the
   public URL automatically in ~2 minutes).
3. Locally: `docker compose -f dev/docker-compose.yml up --build` runs all three
   apps + Postgres; the worker writes emails to `dev/outbox/`.

### 6b. CI/CD perspective (`rollout.sh`)
1. `changes` job (paths-filter) decides which of backend/worker/frontend changed.
2. `deploy` job authenticates to GCP via **WIF** (no keys), then for each changed
   service **in order** (backend → frontend → worker):
   a. `docker build` once, push to Artifact Registry, resolve the **immutable
      digest**.
   b. (worker only) publish the pinned Python source to a per-digest GCS prefix.
   c. Commit the digest to `deploy-state/state/<svc>/desired.yaml` (this **is**
      the deploy) — pushed over the SSH deploy key.
   d. **Gate**: poll `gs://…/state/<svc>/actual.json` until it reports
      `healthy:true` **for that exact digest** (not a stale healthy), or fail.
3. A failed gate aborts the rollout (set -e), so later services are never
   touched — the partial-failure policy.

### 6c. VM / data-plane perspective (the reconciler)
On each VM, every ~60s:
1. `git fetch/reset` the deploy-state repo → read the pinned digest.
2. If it differs from what's running: fetch the service's secret from Secret
   Manager into a `0600` env file; authenticate Podman to Artifact Registry via
   the VM's metadata SA token; `podman pull` the image; (backend) run migrations;
   generate/refresh the systemd unit (Linux) or scheduled task (Windows); restart.
3. Health-check the new version (HTTP `/healthz`/`/api/health`, or worker
   heartbeat freshness).
4. On pass: record last-good, write `actual.json{healthy:true,sha,…}` to GCS.
   On fail: roll back to last-good, re-check, write the failure/degraded state.

### 6d. Operator perspective
- **Deploy**: merge to main. **Rollback**: `git revert` the digest commit in
  deploy-state (the reconciler converges back; Podman also keeps the last-good
  image locally for instant fallback).
- **Observe**: `actual.json` per service in GCS is the source of truth for what's
  running and healthy; the backend `/healthz` reports `worker_online` from the
  heartbeat.
- **Degraded**: if a deploy and its rollback both fail, the reconciler writes a
  `degraded` state and the fleet freezes — it never silent-loops. (On Windows,
  the reconciler also dumps diagnostics to GCS — that's how the worker was
  debugged with no SSH/RDP.)

### 6e. Security perspective
- **No static keys anywhere**: CI uses WIF (short-lived OIDC); VMs use their
  attached service-account tokens.
- **Least privilege**: each VM SA can read **only its own** service's secret;
  bucket access is scoped per service.
- **No inbound**: VMs have **no external IP**; no SSH/RDP open to the internet
  (admin only via IAP). Egress via Cloud NAT; Google-API + DB traffic stays on
  Google's network via Private Google Access.
- **Private data tier**: Cloud SQL has no public IP; reached over VPC peering.
- **Secrets never in git or Terraform state**: only the empty secret containers
  are in Terraform; values are seeded out-of-band (`scripts/seed-secrets.sh`).
- **Frontend doesn't leak the backend**: the browser talks to the Next.js route
  handler, which proxies to the internal backend.

### 6f. Scale perspective (100 → 100k users)
The single-VM root module is the literal brief; `terraform/scaling/` is the
production answer and is what makes the 100k claim real:
- **One regional MIG per service** (the "ASG per service"), each with its own
  autoscaler and `min/max_replicas` — change the `scaling` var (e.g.
  `min=20, max=100`) and the fleet honors it. MIGs span 3 zones when
  `highly_available=true` (HA), with health-gated rolling updates (no restart
  blip).
- **frontend**: external L7 LB, autoscales on LB utilization.
- **backend**: internal L7 LB (never public), autoscales on LB utilization.
- **worker**: no LB; autoscales on **queue depth** (a `pending_leads` custom
  metric), and can scale to **zero** when idle.
- **Data tier**: the bounded pgx pool means the DB sees at most
  `N_instances × DB_MAX_CONNS` connections (so 100 backends × 10 = 1000, which
  you size the tier / PgBouncer for); **read replicas** (`read_replica_count`,
  e.g. 10) absorb read traffic via the read/write split. The primary handles
  writes; replicas handle `GET` reads round-robin.
- **The reconciler is unchanged at scale**: every new MIG instance boots from
  the template, installs the reconciler, and converges to the declared digest —
  scaling out is free, no orchestration change.

---

## 7. What was deployed live (and verified)

On GCP project `knock-knock-dev-499112` (region `asia-south1`):
- 42 foundational resources (VPC, Cloud SQL, buckets, secrets, SAs, WIF) + 3 VMs
  + the external LB.
- **Verified end-to-end**: a lead submitted through the **public LB URL**
  persisted in Cloud SQL, the worker emailed it, and `invite_sent` flipped to
  `true` — all three services working together on real infrastructure.
- **GitOps auto-deploy verified**: a code change merged to `main` reached the
  live public site automatically.
- (Infra was then `terraform destroy`-ed to stop cost; everything re-applies
  from code in ~15 minutes via `terraform apply` + `scripts/seed-secrets.sh`.)

---

## 8. Bugs found & fixed during the live deploy (real-world hardening)

These only surface against real infrastructure and are the strongest evidence
the system actually works:

1. **CI cross-repo push 403** — `actions/checkout` injects the main-repo token
   for all github.com; switched the deploy-state push to a scoped **SSH deploy
   key**.
2. **Reconciler `203/EXEC`** — script not executable; set the exec bit + startup
   `chmod`.
3. **Podman registry 403** — Podman doesn't use GCP creds automatically;
   authenticate via the metadata SA token before pull.
4. **gcloud missing on Debian** — base image lacks it; install in startup.
5. **No Quadlet on Podman 4.3.1** — generate a plain systemd `podman run` unit
   instead.
6. **Gate passed on stale health** — gate now matches the **deployed digest**.
7. **Hardcoded backend IP broke on VM recreate** — use **GCE internal DNS**.
8. **Windows `winget` unavailable to SYSTEM** — install Python/git/gcloud via
   direct silent installers.
9. **Empty `worker.env`** — PowerShell pipe to `Out-File` produced empty; use
   `[IO.File]::WriteAllText`.
10. **`git pull` "multiple branches"** — use `fetch` + `reset --hard`.
11. **`gcloud rsync` mangled Windows filenames** — use `cp -r .../<key>/*`.
12. **`python` not an SCM service (1053)** — run the worker as a **scheduled
    task**.
13. **SYSTEM task stale PATH** — resolve `python`/`gcloud` to **absolute paths**.
14. **Reconcile task pile-up** — `MultipleInstances IgnoreNew` + a 5-min
    execution limit.

---

## 9. Repo layout

```
apps/backend       Go/Gin API, bounded pool, read/write split, embedded migrations
apps/frontend      Next.js landing page + /try form + /api proxy + /api/health
apps/worker        Python lead-emailer (DB-queue consumer, heartbeat)
db/schema.sql      schema reference (migrations are source of truth)
dev/               docker-compose for local end-to-end
deploy/linux       reconciler.sh + systemd timer/unit + cloud-init startup
deploy/windows     bootstrap.ps1, reconciler.ps1, install-service.ps1, startup tpl
deploy/state       desired-state examples (real ones live in hanomi-deploy-state)
terraform/         base infra (VPC, Cloud SQL, VMs, secrets, WIF, external LB)
terraform/scaling  production MIGs + autoscalers + internal LB + read replicas
scripts/           seed-secrets.sh
.github/           deploy workflow + rollout.sh
README.md          1–2 page summary  ·  WALKTHROUGH.md  plain-English tour
AI_USAGE.md        how Claude Code was used
```

---

## 10. AWS → GCP migration mapping

| Concern | AWS | GCP (this build) |
|---|---|---|
| CI → cloud auth | OIDC → IAM role | Workload Identity Federation → service account |
| Artifact store | S3 / ECR | GCS / Artifact Registry |
| Secrets | Secrets Manager | Secret Manager |
| VMs | EC2 (private subnets) | Compute Engine (no external IP) |
| Autoscaling group | ASG + launch template | regional Managed Instance Group + instance template |
| Load balancer | ALB | external/internal Application LB |
| Private API access | VPC endpoints | Private Google Access + Cloud NAT |
| DB | RDS (+ read replicas) | Cloud SQL (+ read replicas), private IP |
| Agentless exec | SSM Run Command | (no 1:1) → GitOps pull reconciler |
| Admin access | SSM Session Manager | IAP tunnel |
| Orchestrator | CodePipeline / Jenkins | GitHub Actions (Jenkins path noted) |
