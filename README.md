# Hanomi Multi-Service Deploy Pipeline (GCP)

A deploy pipeline for the Hanomi stack — three services, each on its own VM
(not Kubernetes):

| Service | Stack | OS | Runs as |
|---|---|---|---|
| **backend** | Go + Gin | Linux | Podman container under a systemd unit |
| **frontend** | Next.js | Linux | Podman container under a systemd unit |
| **worker** | Python | Windows | Windows container (Docker), deployed via a self-hosted GitHub Actions runner |

They form one coherent product slice: the **frontend** is the Hanomi landing
page with a "Try Hanomi" demo form; the **backend** captures each lead into
**Cloud SQL Postgres**; the **worker** polls for new leads and emails them the
Hanomi welcome message, recording that the invite was sent.

> **The core idea:** CI never touches the VMs. It only **declares desired state
> in Git**. Each VM runs a small reconciler that converges to it, health-checks
> itself, and reports back. This is a control-plane / data-plane split — the
> same shape as a GCP provision manager — and it deletes the entire class of
> SSH-key / bastion / inbound-firewall failure modes.

---

## Architecture

```
 GitHub: parent repo + 3 submodules ── merge→main ──► GitHub Actions (control plane)
   │                                                      │ Workload Identity Federation (no static keys)
   │ build image once → push (digest-pinned)              ▼
   │ commit new digest → deploy-state repo          ┌──────────── GCP project ─────────────┐
   ▼                                                │ Artifact Registry: <svc>@sha256:…     │
 deploy-state repo (GitOps desired state)           │ Secret Manager: hanomi/<svc>/*        │
   backend/desired.yaml  → image@sha256             │ GCS: state/<svc>/actual.json (gate)   │
   frontend/desired.yaml → image@sha256             │ (worker: deployed by its self-hosted  │
        ▲ reconcilers git-pull (~60s) [Linux]       │  runner on the VM, not via deploy-state)│
        │                                           │ ┌──────── VPC (custom) ────────────┐  │
        │                                           │ │ Private Google Access + Cloud NAT │  │
        └───────────── pulled by ───────────────────┼─┤ NO external IPs on any VM         │  │
                                                     │ │  backend  VM (Linux)  Podman+Quadlet│
                                                     │ │  frontend VM (Linux)  Podman+Quadlet│
                                                     │ │  worker   VM (Windows) container+runner│
                                                     │ │  Private Services Access            │
                                                     │ │   └ Cloud SQL Postgres (PRIVATE IP) │
                                                     │ └───────────────────────────────────┘ │
                                                     └────────────────────────────────────────┘
```

### Deploy flow

1. **Merge to `main`** triggers one GitHub Actions workflow.
2. **Change detection** — only services whose code changed are built (in the
   real submodule layout this is "which submodule pointer moved").
3. **Build once** → push image to Artifact Registry, referenced by **immutable
   digest** (`@sha256:…`). The Windows worker image is built on a `windows-latest`
   runner (Linux runners can't build Windows images).
4. **Two deploy paths, by OS:**
   - **Linux (backend, frontend):** CI commits the digest to the `deploy-state`
     repo; each VM's reconciler (git-poll ~60s) pulls it, fetches secrets, runs
     migrations (backend), swaps the container, health-checks, and writes
     `{sha, healthy, error}` to GCS, which CI gates on.
   - **Windows (worker):** a `deploy-worker` job runs **on the VM's own
     self-hosted GitHub Actions runner** — `docker pull` + `docker run
     --restart always` — and health-gates on the container actually running.
     This is the standard single-Windows-VM push-CD pattern.

---

## Tool choices & tradeoffs

| Decision | Choice | Why / tradeoff |
|---|---|---|
| Orchestrator | **GitHub Actions** | Native merge-to-`main` trigger; self-contained in the repo; zero-key auth via WIF. (Jenkins migration path noted below.) |
| CI → GCP auth | **Workload Identity Federation** | Short-lived OIDC tokens — **no service-account JSON keys** stored in GitHub. |
| Desired state | **GitOps repo** (`deploy-state`) | A deploy is a commit; rollback is `git revert`; full audit trail. VMs need only *read* access. |
| Change signal | **Git poll (~60s)** | The GitOps invariant; also self-healing (corrects drift even with no push). Tradeoff: up-to-60s deploy latency. Considered Pub/Sub push — rejected as over-engineering for a 3-VM fleet. |
| Linux runtime | **Podman container under a generated systemd unit** | The reconciler generates a systemd unit running `podman run`, giving `Restart=always` self-heal. **Rejected the GCP-native `gce-container-declaration`/konlet path because it is deprecated** (deprecated 2025-07-21; VM-create stops 2026-07-31). Considered Quadlet but Debian 12 ships Podman 4.3.1 (Quadlet needs ≥4.4), so a generated unit is the portable choice. Google now directs users to startup-script / cloud-init, which is exactly what we use to install Podman. |
| Windows runtime | **Windows container (Nano Server) via Docker**, deployed by a **self-hosted GitHub Actions runner on the VM** | systemd/Podman are Linux-only, so the Windows worker is a deliberate second track. The verified industry-standard pattern for a single Windows VM: the worker ships as a Windows container image (Nano Server + Python, ~280MB); a self-hosted runner on the VM runs `docker pull` + `docker run --restart always` as a normal CI job on each merge. (Researched: rejected an autonomous pull-reconciler and Server Core — the runner is debuggable as a CI job and Nano Server pulls fast.) |
| Versioning | **immutable digest-pinned images** | Deterministic rollback, no rebuild. (Note: this is why we do **not** use `podman auto-update` to deploy — it tracks a moving tag and conflicts with digest pinning; CI drives the version change instead.) |
| Actual/health state | VM writes `actual.json` to **GCS** | Clean split: Git = desired, GCS = actual. Avoids VMs needing Git *write* access. |
| Database | **Cloud SQL Postgres, private IP only** | No public endpoint; reached over Private Services Access. IAM DB auth enabled; password fallback in Secret Manager. |
| Migrations | **golang-migrate on backend deploy**, fail-closed | Run before serving traffic; a bad migration aborts the deploy. Backward-compatible so a rollback never meets a schema it can't read. |
| IaC | **Terraform** | Portable, the lingua franca, and directly relevant to an AWS→GCP migration (vs. Deployment Manager / Config Connector). |
| Single VM per service | accepted | One brief in-place restart blip on deploy (no second instance to drain to). Minimized by fast container/unit swap. Called out honestly rather than claiming zero-downtime. |

---

## Rollback & partial-failure behaviour

**Every service auto-rolls-back on a failed deploy** — Linux and Windows alike —
and a failed deploy never silently leaves a service down.

**Linux services (backend, frontend).** Rollback is **a `git revert` of the
digest** in `deploy-state` (the reconciler pulls the previous digest and
converges). The reconciler also keeps a `last-good` digest on the VM: if a new
image fails its health check it **auto-reverts to last-good on that VM** and
re-health-checks, no rebuild. Podman keeps the last-good image locally for an
instant swap.

**Windows worker.** The `deploy-worker` job captures the currently-running image
as last-good *before* pulling, health-gates the new container over a ~30s window,
and **auto-reverts to last-good if the new image is unhealthy** — the same
last-good/auto-revert behaviour as Linux, implemented on the VM's self-hosted
runner. The job still goes red so a bad deploy is loud, but the live worker is
back on the previous good image.

What happens to each service when something fails:

| Failure point | backend | frontend | worker | Outcome |
|---|---|---|---|---|
| **backend deploy fails** | self-reverts to last-good, re-health-checks | **never touched** (rollout stopped at the backend gate) | independent track, unaffected | `deploy` job fails loudly |
| **frontend deploy fails** | stays on last-good | self-reverts to last-good | independent track, unaffected | `deploy` job fails at the frontend gate |
| **worker deploy fails** | unaffected | unaffected | self-reverts to last-good image, re-checks | `deploy-worker` job fails (red), worker stays on old version |
| **a rollback itself fails** | writes `degraded` to `actual.json` → CI alerts, fleet freezes | — | `deploy-worker` errors `DEGRADED: … Worker is DOWN` | never silent-loops; manual runbook below |

Linux services are **independently versioned** and the backend deploys first, so
the frontend is never stranded against an incompatible backend (if the backend
gate fails we stop *before* touching the frontend). The worker is a separate
track (Windows), so a worker failure can't block the Linux rollout and vice-versa.

### Manual rollback runbook (when you need the last stable image now)

The new image is broken and you want the previous one back. Pick by urgency:

1. **Fastest — re-run the last-good container on the VM** (no CI, ~30s). RDP/SSH
   to the worker VM (Linux: the analogous step is `git revert` below):
   ```powershell
   # list recent worker images, newest first (tags are git SHAs):
   gcloud artifacts docker images list \
     asia-south1-docker.pkg.dev/<PROJECT>/hanomi/worker \
     --include-tags --sort-by="~UPDATE_TIME" --limit=10
   docker rm -f hanomi-worker
   docker run -d --name hanomi-worker --restart always \
     --env-file C:\hanomi\worker.env \
     asia-south1-docker.pkg.dev/<PROJECT>/hanomi/worker:<PREVIOUS_GOOD_SHA>
   ```
2. **Clean / auditable — re-dispatch the pipeline at the last-good commit.** The
   `deploy` workflow has a `workflow_dispatch` with a **`force_worker`** input so
   a manual run rebuilds + redeploys the worker even though nothing "changed":
   ```bash
   gh workflow run deploy.yml --ref <PREVIOUS_GOOD_SHA> -f force_worker=true
   ```
   (Linux services redeploy from that ref automatically; tick `force_worker` so
   the Windows worker rolls back too.)
3. **Audit-correct — `git revert`.** Undo the bad commit so `main` reflects
   reality; the push re-fires the pipeline and rebuilds from the good source:
   ```bash
   git revert <bad_commit_sha> && git push origin main
   ```

**Degraded (rollback itself failed):** RDP/SSH to the VM via IAP (the only admin
path); inspect `journalctl -u <svc>` (Linux) / `docker logs hanomi-worker` +
Windows event log; the reconciler/`deploy-worker` job logged the failing digest.
Fix forward by deploying a known-good digest, or roll back the migration if the
schema is the cause.

---

## Health checks

- **backend** `GET /healthz` — 200 only if Postgres is reachable; also reports
  `worker_online` (derived from the worker's heartbeat freshness).
- **frontend** `GET /api/health` — 200 only if it can reach the backend.
- **worker** — two layers: at deploy time the `deploy-worker` job gates on the
  container staying `State.Running` over a ~30s window (and auto-rolls-back if
  not); at runtime health is a **heartbeat row** written to Postgres each cycle,
  surfaced as `worker_online` by the backend `/healthz`. `docker run --restart
  always` self-heals crashes between deploys.

---

## Secrets handling

- **Nothing secret in GitHub.** CI authenticates to GCP with WIF (short-lived
  tokens).
- **App secrets** (`DATABASE_URL`, the worker's `SMTP_*`) live in **Secret
  Manager** under `hanomi/<svc>/*`. Each VM's per-service service account can
  read **only its own** service's secret.
- Secrets are fetched **on the VM at deploy time** into a `0600` env file owned
  by the service user — never logged, never passed as command arguments, never
  committed. Secret *values* are added out-of-band; they are never in Terraform
  state.

### Email provider

The worker's email sender is pluggable: with no SMTP config it writes the
rendered email to a local outbox (so the demo runs with **zero external
accounts**); when `SMTP_*` are present (from Secret Manager) it sends for real.
A free provider such as **Brevo** (300 emails/day, SMTP) drops straight in.

---

## Networking (VPC / subnets)

- **Custom VPC**, one regional subnet `10.0.1.0/24`. No auto subnets.
- **No external IPs** on any VM. Egress (image pulls, `apt`, `gcloud`) goes
  through **Cloud NAT**; Google-API + DB traffic stays on Google's network via
  **Private Google Access**.
- **Firewall:** default-deny ingress. Allowed: intra-VPC `8080`/`3000` (frontend
  → backend), and SSH/RDP **only from the IAP range** (`35.235.240.0/20`) as
  IAM-gated break-glass — no SSH/RDP open to the internet.
- **Cloud SQL** has **no public IP**; the VMs reach it over **Private Services
  Access** (VPC peering).

---

## The demo apps

| App | Endpoints / behaviour |
|---|---|
| `apps/backend` (Gin) | `POST /leads`, `GET /leads`, `GET /leads/:id`, `GET /healthz`; embedded golang-migrate migrations |
| `apps/worker` (Python) | polls `pending` leads (`FOR UPDATE SKIP LOCKED`), emails the welcome message, sets `invite_sent`/`invite_sent_at`, writes heartbeat |
| `apps/frontend` (Next.js) | light-mode landing page; `/try` demo form (first name, phone, email, company); proxies to backend; live API/worker status |

The backend and worker share **one Cloud SQL database**; the `leads` table is
the queue (`SKIP LOCKED` makes it safe even with multiple workers). No
service-to-service calls.

### Run it locally (one command)

```bash
docker compose -f dev/docker-compose.yml up --build
# open http://localhost:3000  → click "Try Hanomi" → submit the form
# watch the lead get emailed:
curl -s localhost:8080/leads        # status pending → emailed, invite_sent → true
cat dev/outbox/*.eml                 # the rendered welcome email
```

(Local dev uses a Postgres container on host port `5433`; production uses Cloud
SQL.)

### Deploy to GCP

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in project_id, github_repo, state_repo_url
terraform init && terraform apply
# wire the outputs (ci_service_account, wif_provider, state_bucket, …) into
# the repo's GitHub Actions Variables, add STATE_REPO_TOKEN secret, then merge to main.
```

---

## Scaling & autoscaling (production module)

The root design deploys one VM per service because the brief said so — but a
single named VM per service is a single point of failure and cannot scale, so
it is not production-ready. `terraform/scaling/` is the production evolution: it
replaces each named VM with the GCP equivalent of an **AWS Auto Scaling Group
behind a load balancer** — one independently-scaling group per service.

| AWS | GCP (in `terraform/scaling/`) |
|---|---|
| Launch Template | Instance Template |
| Auto Scaling Group | regional Managed Instance Group (MIG) |
| ASG scaling policy | Autoscaler |
| ALB + Target Group | Application (L7) Load Balancer + Backend Service |

**One MIG per service, scaling independently:**

| Service | Scales horizontally on | Load balancer | Min/Max (demo) |
|---|---|---|---|
| frontend | HTTP LB utilization (0.7) | **External** L7 HTTPS | 1 → 2 |
| backend | HTTP LB utilization | **Internal** L7 (frontend-only, never public) | 1 → 2 |
| worker | **queue depth** — `single_instance_assignment` over a `pending_leads` custom metric | none (pull-based) | **0** → 2 |

Sizes are kept small and **single-region / single-zone by default** (the
`highly_available` flag, off for the demo) to keep cost minimal; flip the flag
and raise the maxes in `terraform.tfvars` for production HA.

- **Horizontal:** automatic via each MIG's autoscaler. The worker is the elegant
  case — it's a pull-based consumer (`FOR UPDATE SKIP LOCKED`), so running many
  copies is already safe; it scales on backlog (≈5 pending leads per worker) and
  **scales to zero** when idle. CPU would be the wrong signal there.
- **Vertical:** change `machine_type` in the instance template → the MIG does a
  health-gated rolling replace. (Live vertical resize of plain VMs isn't a GCE
  feature — that's GKE VPA, which the brief excluded. GCE gives right-sizing
  *recommendations* you apply this way.)
- **Resilience:** autohealing (replace unhealthy instances) + health-gated
  rolling updates (`max_surge`/`max_unavailable`) **eliminate the single-VM
  restart-blip** of the root design. The `highly_available` flag (off for the
  demo) spreads instances across 3 zones for real HA when you want it.
- **The GitOps reconciler is unchanged:** every new MIG instance boots from the
  template, installs the reconciler, and converges to the digest in
  `deploy-state`. Scaling out is free. The only rollout-gate change is gating on
  **MIG + LB health** (≥ healthy threshold) instead of a single `actual.json`.

See `terraform/scaling/README.md`.

## Repo layout & the "3 submodules"

The brief specifies one parent repo with three git submodules. This submission
is a **monorepo** (`apps/backend`, `apps/frontend`, `apps/worker`) for review
convenience; the mapping is 1:1 — each `apps/<svc>` is a submodule, "merge to
parent `main`" = "a submodule pointer moved", and the workflow's path-based
change-detection mirrors per-submodule triggering. The `deploy-state` repo
(GitOps desired state) is genuinely separate, as the architecture requires.

---

## AWS → GCP migration mapping

The firm is migrating AWS → GCP, so every choice has an AWS counterpart:

| Concern | AWS | GCP (this repo) |
|---|---|---|
| CI → cloud auth | OIDC → IAM role | Workload Identity Federation → service account |
| Artifact store | S3 / ECR | GCS / Artifact Registry |
| Secrets | Secrets Manager | Secret Manager |
| VMs | EC2 (private subnets) | Compute Engine (no external IP) |
| Private API access | VPC endpoints | Private Google Access + Cloud NAT |
| DB | RDS | Cloud SQL (private IP) |
| Agentless exec | SSM Run Command | (no 1:1) → GitOps pull reconciler |
| Admin access | SSM Session Manager | IAP tunnel |

**Jenkins note:** GitHub Actions is the right control plane for this greenfield
pipeline. If the existing AWS estate is Jenkins-based, the same control-plane /
data-plane split lifts onto Jenkins cleanly — re-point its pipelines at GCP via
WIF and keep the GitOps reconciler data plane unchanged.

---

## AI tools used

Built with **Claude (Opus 4.8)** as a pair:

- **Architecture brainstorming** — pressure-testing the control-plane/data-plane
  design, the GitOps-vs-GCS desired-state choice, and the partial-failure policy.
- **A deep-research pass on VM-local container reconcilers** — this is what
  surfaced that GCP's native `gce-container-declaration`/konlet path is
  **deprecated with a 2026-07-31 cutoff**, and pointed to Podman + Quadlet as the
  current self-healing reconciler. Findings were adversarially verified
  (24/25 claims confirmed) before being acted on.
- **Code & config scaffolding** — the apps, Terraform, reconcilers, and this
  workflow, all reviewed and tested by me (the full stack is verified end-to-end
  via `docker compose`).

Every architectural decision was made and reviewed by me; AI accelerated
research, drafting, and verification.

---

## Known limitations (YAGNI)

- Single VM per service (root module) → a brief restart blip on deploy (no
  instance to drain to). This is the literal brief answer; the production answer
  is `terraform/scaling/` (MIGs + LBs), where rolling updates remove the blip.
- Terraform uses local state for the take-home; a real setup uses a GCS backend.
- Deploy latency is bounded by the ~60s poll interval (Pub/Sub push would cut
  this but adds infra not worth it here).
- The Windows scripts are validated on the target VM; they are not exercised by
  the local `docker compose`, which covers the two Linux services + the worker
  logic.
