# Hanomi Multi-Service Deploy Pipeline — Design Spec

**Date:** 2026-06-19
**Status:** Approved
**Target cloud:** Google Cloud Platform (GCP)

## 1. Context & Goal

A take-home for a hiring firm migrating from AWS to GCP. Design and partially
implement a deploy pipeline for a hypothetical "Hanomi" stack:

- One parent repo with three git submodules: **backend** (Go service, Linux),
  **frontend** (Next.js, Linux), **worker** (Python script, Windows server).
- **Trigger:** merge to `main` of the parent repo.
- **Targets:** each service deploys to its own VM (3 separate VMs, *not* K8s).
- **Requirements:** rollback strategy, basic health checks, secrets handling,
  and a defined behaviour for a partial mid-rollout failure.

The firm is hiring specifically for GCP infra/platform expertise (the candidate
has built a GCP "provision manager" that creates resources). The design must
therefore demonstrate current, correct GCP knowledge and a clean
control-plane / data-plane separation.

## 2. Guiding Idea

> **CI declares desired state in Git. Each VM's local reconciler converges to
> it. The control plane never touches the VMs, and each VM self-heals on its own.**

This is a GitOps control plane + a real desired-state data plane — the same
control-plane / data-plane split a provision manager uses. It deletes the entire
class of SSH-key / bastion / inbound-firewall failure modes.

## 3. Architecture

```
 GitHub: parent repo + 3 submodules ── merge→main ──► GitHub Actions (control plane)
   │                                                      │ Workload Identity Federation (no static keys)
   │ CI build-once → push image (digest-pinned)           ▼
   │ CI commits new digest → deploy-state repo      ┌──────────── GCP project ─────────────┐
   ▼                                                │ Artifact Registry: <svc>@sha256:…     │
 deploy-state repo (GitOps desired state)           │ Secret Manager: hanomi/<svc>/*        │
   backend/desired.yaml  → {image@sha256}           │ GCS: state/<svc>/actual.json (gate)   │
   worker/desired.yaml   → {image@sha256}           │                                       │
   frontend/desired.yaml → {image@sha256}           │ ┌──────── VPC (custom) ────────────┐  │
        ▲ reconcilers git-pull (~60s)               │ │ Private Google Access + Cloud NAT │  │
        │                                           │ │ NO external IPs                   │  │
        └───────────── pulled by ───────────────────┼─┤  backend  VM (Linux)  Podman+Quadlet│
                                                     │ │  frontend VM (Linux)  Podman+Quadlet│
                                                     │ │  worker   VM (Windows) Win Service  │
                                                     │ │  Private Services Access            │
                                                     │ │   └ Cloud SQL Postgres (PRIVATE IP) │
                                                     │ └───────────────────────────────────┘ │
                                                     └────────────────────────────────────────┘
```

## 4. Locked Decisions (with rationale)

| Layer | Choice | Why |
|---|---|---|
| Orchestrator | GitHub Actions + **Workload Identity Federation (WIF)** | Native merge trigger; zero static keys; self-contained for the reviewer. |
| Desired state | **GitOps repo** (`deploy-state`); CI commits the new image digest | Audit + rollback come free from git history; deploys are reviewable. |
| Change signal | **Git poll ~60s** on each VM (no Pub/Sub) | The GitOps invariant + self-healing; Pub/Sub was over-engineering for a 3-VM fleet. |
| Linux data plane | **Podman + Quadlet (systemd)** | Real reconciler: `Restart=always` + healthcheck-restart. The GCP-native `gce-container-declaration`/konlet path is **deprecated** (deprecated 2025-07-21; creation stops 2026-07-31; full support ends 2027-07-31), so it is rejected. |
| Windows worker | **Native Windows Service** running the Python worker | systemd/Quadlet are Linux-only; Windows containers are heavy. Honest separate track. |
| Versioning | **Immutable digest-pinned images** in Artifact Registry | Deterministic rollback. CI drives the version change (NOT `podman auto-update`, which tracks a moving tag and conflicts with digest pinning). |
| Actual/health state | VM writes `actual.json` to **GCS**; CI gates on it | Clean split: Git = desired, GCS = actual. No Git write-credentials on the VMs. |
| Database | **Cloud SQL Postgres, private IP only** + Cloud SQL Auth Proxy / IAM DB auth | No public DB. Password fallback in Secret Manager. Showcases Private Services Access. |
| Migrations | **golang-migrate on backend deploy**, backward-compatible, fail-closed | Run before the unit swap; a failed migration fails the deploy and never swaps to a binary expecting an absent schema. Backward-compat keeps rollback safe. |
| Network | Custom VPC, **no external IPs**, Private Google Access, Cloud NAT for egress | Zero inbound; controlled egress; all Google-API + DB traffic stays on Google's network. |
| Region | `asia-south1` default, variabilized | Zeotap/India context. |

## 5. Deploy Flow (happy path)

1. **Merge to `main`** on the parent repo triggers one GitHub Actions workflow.
2. The workflow resolves the **pinned submodule SHAs** — the parent repo is the
   source of truth for which versions ship together (the coherent release).
3. **Change detection:** only services whose submodule SHA changed are built.
4. **Build once** per changed service → container image pushed to Artifact
   Registry, referenced by **immutable digest** (`@sha256:…`).
5. **Sequential gated rollout** `backend → worker → frontend`. For each stage:
   a. CI commits the new digest to `deploy-state/<svc>/desired.yaml`.
   b. The VM's reconciler (git-poll ~60s) sees the change, pulls the image,
      fetches secrets from Secret Manager, [backend only] runs golang-migrate,
      swaps the running unit to the new digest, and health-checks.
   c. The VM writes `state/<svc>/actual.json` = `{sha, healthy, error}` to GCS.
   d. CI polls `actual.json`; only on `healthy:true` does the next stage start.
6. On success, the digest recorded in `actual.json` is the last-good.

## 6. Rollback & Partial-Failure (core requirement)

- **Rollback** = CI reverts the digest in `deploy-state` (a `git revert`); the
  reconciler pulls the previous digest and converges. Podman additionally keeps
  the last-good image locally for an instant fallback. Sub-second, deterministic,
  no rebuild.
- **Per-stage failure:** the failed service converges back to its own last-good
  digest, re-health-checks, and writes `healthy:false`. CI sees it and **fails
  the pipeline loudly** with the exact per-service SHA map.
- **Partial rollout** (backend ✅ → worker ❌): the worker reverts to its
  last-good; **backend stays on the new version, frontend is never touched**
  (the rollout stops before it). Services are independently versioned — no forced
  lockstep — so the UI is never stranded against an incompatible backend.
- **If reconcile/health keeps failing:** the reconciler writes `degraded` to
  `actual.json`, CI alerts, and the fleet freezes — it never silent-loops. A
  manual runbook is documented in the README.
- **Migration safety:** migrations are backward-compatible, so a backend rollback
  never hits a schema it cannot read.

## 7. Secrets Handling

- **No secrets in GitHub.** CI authenticates to GCP via **Workload Identity
  Federation** (short-lived tokens, no stored keys).
- **App secrets** live in **Secret Manager** under `hanomi/<svc>/*`. Each VM's
  per-service service account can read only its own service's prefix.
- Secrets are fetched **on the VM at deploy time**, written to a `0600` env file
  owned by the service user, never logged, never passed as command arguments.

## 8. The Demo Apps (dev-mindset proof)

Coherent domain: **a task / job queue**.

- **backend** (Go / Gin): `POST /tasks` (enqueue), `GET /tasks` (list),
  `GET /tasks/:id`, `GET /healthz` (checks DB connectivity + worker heartbeat
  freshness). Writes to Cloud SQL. Embeds golang-migrate migrations.
- **worker** (Python, Windows): polls the `tasks` table for `pending` rows,
  "processes" each (compute + sleep), marks `done`/`failed`, and writes a
  `worker_heartbeat` row every cycle — that row is the worker's health signal.
- **frontend** (Next.js): task list + create form + live status; shows a
  "worker online" indicator derived from heartbeat freshness; `/api/health`
  route for the reconciler's health check.
- **DB**: Cloud SQL Postgres, private IP, accessed via Cloud SQL Auth Proxy with
  IAM DB auth (password fallback from Secret Manager).

## 9. Deliverables

- `README.md` (1–2 pages): architecture, tool choices + tradeoffs, failure-mode
  matrix, AWS→GCP migration mapping (incl. a Jenkins note), the konlet-deprecation
  finding, and an "AI tools used" note.
- `terraform/`: custom VPC + subnet + Cloud NAT + firewall, Private Services
  Access + Cloud SQL, three Compute Engine VMs + per-service service accounts,
  Artifact Registry, Secret Manager, GCS state bucket, WIF pool/provider + CI SA.
- `.github/workflows/deploy.yml`: WIF auth, change detection, build-once /
  digest-pin, commit-to-state, sequential gated rollout, revert-on-failure.
- `apps/backend` (Gin), `apps/worker` (Python), `apps/frontend` (Next.js): real,
  runnable apps.
- VM config: Quadlet `.container` units + cloud-init for the Linux VMs; a Windows
  Service wrapper + bootstrap for the worker; the reconciler scripts (bash +
  PowerShell).

## 10. Tooling Tradeoffs (for the README)

- **Terraform** over Deployment Manager / Config Connector: portable, the lingua
  franca, and directly relevant to an AWS→GCP migration.
- **Pull/reconciler** over IAP-SSH push: more robust, async, no inbound; tradeoff
  is up-to-one-poll-interval deploy latency and a small local agent.
- **Podman + Quadlet** over konlet/`gce-container-declaration`: the native path is
  deprecated with a hard 2026-07-31 cutoff; Quadlet is the current,
  systemd-native, self-healing reconciler.
- **Single VM per service**: a brief in-place restart blip on deploy (no second
  instance to drain to). Minimized by fast container/unit swap; called out
  honestly rather than claiming zero-downtime.

## 11. AWS→GCP Migration Mapping (README section)

| Concern | AWS | GCP |
|---|---|---|
| CI → cloud auth | OIDC → IAM role | Workload Identity Federation → service account |
| Artifact store | S3 / ECR | GCS / Artifact Registry |
| Secrets | Secrets Manager | Secret Manager |
| VMs | EC2 (private subnets) | Compute Engine (no external IP) |
| Private API access | VPC endpoints | Private Google Access + Cloud NAT |
| DB | RDS | Cloud SQL (private IP) |
| Agentless exec | SSM Run Command | (no 1:1) → GitOps pull reconciler |
| Orchestrator | CodePipeline / Jenkins | GitHub Actions (Jenkins lift-and-shift path noted) |

## 12. Out of Scope (YAGNI)

- Kubernetes / GKE (brief says VMs, not K8s).
- Canary / blue-green across instances (only one VM per service).
- Pub/Sub event-driven reconcile acceleration (poll is sufficient; mentioned as
  a future optimization only).
- `podman auto-update` as the deploy mechanism (conflicts with digest pinning;
  mentioned only as an optional passive security-patch layer).
- Multi-region / HA.
