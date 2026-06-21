# Hanomi Deploy Pipeline — Read-Me-First Walkthrough

*A plain-English tour of what was built, why, and where things stand. Read this
first, then the `README.md` for the formal version.*

---

## 1. The one-sentence idea

> **CI never logs into the servers. It writes the desired version into a Git
> repo. Each server runs a little agent that notices the change, pulls the new
> version, health-checks itself, and reports back.**

This is called **GitOps with a control-plane / data-plane split**:
- **Control plane** = GitHub Actions. It builds the app, and its only "deploy"
  action is to *commit a new image version* to a separate Git repo.
- **Data plane** = the VMs. Each runs a "reconciler" that pulls that repo every
  ~60 seconds and makes reality match what Git says.

Why this is good: there are **no SSH keys, no open ports, no bastion host**. The
servers pull; nobody pushes into them. Fewer ways to break, fewer ways to get
hacked. It works identically whether you have 1 server or 100.

---

## 2. The three apps (the thing being deployed)

A realistic slice of Hanomi's product, so the pipeline has something real to do:

| App | Tech | What it does |
|-----|------|--------------|
| **frontend** | Next.js (Linux) | The Hanomi landing page + a "Try Hanomi" demo form (name, phone, email, company) |
| **backend** | Go + Gin (Linux) | Receives the form → saves a "lead" row in Postgres. `POST /leads`, `GET /healthz` |
| **worker** | Python (Windows) | Watches for new leads → "sends" the Hanomi welcome email → marks the lead as invited |

They share **one Cloud SQL Postgres database**. The database table *is* the queue:
the backend inserts a `pending` lead, the worker grabs it (`FOR UPDATE SKIP
LOCKED` so two workers never grab the same one), emails it, marks it `emailed`
and sets `invite_sent = true`. No app calls another app directly — the database
connects them. That's a clean, scalable pattern.

> Locally you can run all three with one command:
> `docker compose -f dev/docker-compose.yml up --build` → open localhost:3000.
> The worker writes the rendered email to `dev/outbox/` (no real email account
> needed). In production it can send real email via SMTP (e.g. Brevo, free tier).

---

## 3. How a deploy actually flows (step by step)

1. You **merge to `main`**. GitHub Actions wakes up.
2. It figures out **which app changed** (only rebuild what's needed).
3. It **builds the container image once** and pushes it to Artifact Registry,
   tagged by an **immutable digest** (`@sha256:...` — a fingerprint that can
   never point at different bytes later). This is what makes rollback safe.
4. It **commits that digest** into the `deploy-state` repo, in order
   **backend → worker → frontend**.
5. After each commit it **waits ("gates")**: it watches a small status file the
   VM writes to a storage bucket (`actual.json`) and only moves to the next app
   once the current one reports **healthy**.
6. On each VM, the **reconciler** (a ~60-line script on a 60-second timer):
   pulls the repo → sees the new digest → logs into the registry → pulls the
   image → (backend only) runs DB migrations → swaps the running container →
   health-checks → writes `healthy: true` (or rolls back and writes the error).

---

## 4. The four requirements the assignment asked for

**Rollback.** A deploy is a Git commit of a digest. So rollback = `git revert`
that commit; the reconciler pulls the previous digest and converges. The VM also
keeps the last-good image locally for an instant fallback. No rebuild, fully
deterministic.

**Health checks.** Each service proves it's alive in its own way:
- backend `/healthz` → returns OK only if it can reach Postgres
- frontend `/api/health` → OK only if it can reach the backend
- worker → writes a "heartbeat" row to the DB every cycle; freshness = health

**Secrets.** Nothing secret is in GitHub. CI logs into GCP using **Workload
Identity Federation** (short-lived tokens, *no* stored keys). App secrets (DB
password, SMTP creds) live in **Secret Manager**; each VM can read **only its
own** service's secret, fetched at deploy time into a locked-down file. Never
logged, never committed.

**What if one service fails mid-rollout?** Because the order is
backend → worker → frontend and each step is gated on health:
- the **failed** service automatically rolls back to its own last-good version
- services that already deployed **stay** (they're versioned independently)
- services **after** the failure are **never touched** (so e.g. the frontend is
  never left pointing at a backend that didn't deploy)
- the pipeline **fails loudly** and tells you exactly which service is on which
  version. If even the rollback fails, it marks the VM "degraded", alerts, and
  freezes — it never silently loops.

---

## 5. The networking / security (the "VPC" part)

- A **custom VPC** with one subnet. **No VM has a public IP.**
- VMs reach the internet for image pulls only through **Cloud NAT** (outbound
  only). They reach Google services (storage, secrets) over **Private Google
  Access** — that traffic never leaves Google's network.
- **Cloud SQL has no public IP** either; the VMs reach it privately over **VPC
  peering (Private Services Access)**.
- Firewall is **deny-everything-inbound** by default. The only inbound allowed
  is service-to-service inside the VPC, plus admin SSH/RDP **only through
  Identity-Aware Proxy** (Google checks your identity first) — never open to the
  internet.

---

## 6. Why GCP, and the AWS → GCP angle

The role is about migrating AWS → GCP, so the README has a translation table
(S3↔GCS, ECR↔Artifact Registry, Secrets Manager↔Secret Manager, EC2↔Compute
Engine, RDS↔Cloud SQL, SSM↔the GitOps reconciler, IAM-role-OIDC↔Workload
Identity Federation). One sharp detail worth mentioning live: GCP's *native*
"run a container on a VM" feature (`gce-container-declaration` / konlet) is
**deprecated with a hard cutoff in 2026** — so this design runs containers via
**Podman under a generated systemd unit** on the Linux boxes (self-healing with
`Restart=always`), which is the current, correct way. (Considered Quadlet but
Debian 12 ships Podman 4.3.1, which predates Quadlet — found via a research
pass; see the AI-usage file.)

---

## 7. Scaling — the production answer

A single VM per service can't scale and is a single point of failure, so there's
a second Terraform module (`terraform/scaling/`) that replaces each VM with the
GCP equivalent of an **AWS Auto Scaling Group behind a load balancer**:

- **one Managed Instance Group (MIG) per service**, scaling independently
- frontend → external load balancer; backend → internal load balancer (never
  public); worker → no LB, it scales on **queue depth** (number of pending
  leads) and can scale to **zero** when idle
- a `highly_available` flag: **off = cheap single-zone for the demo**, on =
  spread across 3 zones for real HA
- the GitOps reconciler is unchanged — new instances boot and self-configure

---

## 8. Where things stand right now (as of Saturday night)

**Built & committed:** all three apps, both Terraform modules (base + scaling),
the reconcilers (Linux + Windows), the GitHub Actions workflow, the README.
Everything is on GitHub (public).

**Actually deployed live** on the real GCP project `knock-knock-dev-499112`:
- ✅ All foundational infra (VPC, Cloud SQL, buckets, secrets, service accounts,
  Workload Identity Federation) — **42 resources, applied.**
- ✅ The 3 VMs — running, no public IPs.
- ✅ The CI pipeline runs end-to-end: builds images, authenticates to GCP with
  **zero stored keys** (Workload Identity Federation), commits digest-pinned
  images to the deploy-state repo (via an SSH deploy key).
- ✅ **Backend is LIVE and healthy** — container running, `/healthz` green,
  connected to Cloud SQL.
- ✅ **Frontend is LIVE and healthy**, fronted by an external HTTP Load Balancer
  with a **public URL** — submitting the "Try Hanomi" form through that public
  URL persists a lead row in Cloud SQL (verified end-to-end).
- ✅ **Windows worker is LIVE:** a DB-queue consumer — polls `pending` leads
  (`FOR UPDATE SKIP LOCKED`), sends the welcome email, marks them
  `invite_sent = true`. It runs as a **Windows container** (Nano Server + Python)
  on the worker VM, deployed by a **self-hosted GitHub Actions runner** on that VM
  (`docker pull` + `docker run --restart always`) — a separate track from the
  Linux services, since systemd/Podman are Linux-only. Verified end-to-end:
  `worker_online: true` and a submitted lead is picked up and processed (email
  delivery goes via Brevo once the VM's NAT egress IP is allow-listed there — an
  account setting, not a system limitation). (Production note: bake the VM image
  with Packer — see `DESIGN_AND_BUILD.md`.)

**This was a genuine live deploy**, and along the way we hit and fixed ~14 real
bugs that only show up against real infrastructure — cross-repo Git auth
(switched to an SSH deploy key), a missing executable bit, Podman→Artifact
Registry authentication, gcloud not being preinstalled, Podman 4.3.1 lacking
Quadlet (so the reconciler generates a plain systemd `podman run` unit), the
rollout gate needing to match the *deployed digest*, a hardcoded backend IP that
broke on VM recreation (fixed by using GCE's stable internal DNS name), and a
string of Windows-worker issues (the VM being RAM-starved on `e2-small`, the
runner-registration PAT needing Administration scope, the Docker named-pipe being
denied to a non-SYSTEM runner, Windows path mangling in the Dockerfile, and
embeddable Python ignoring `PYTHONPATH` — all fixed). The full list is in
`DESIGN_AND_BUILD.md`.
"Debugged it against real cloud" is the strongest part of the story.

**Cost note:** Cloud SQL + 3 VMs (incl. one Windows VM) are running and billing.
When you're done, run `cd terraform && terraform destroy` to stop the cost. Tell
me and I'll do it.

---

## 9. The map of the repo

```
apps/backend      Go/Gin API + DB migrations
apps/frontend     Next.js landing page + /try form
apps/worker       Python lead-emailer
deploy/linux      Podman + generated-systemd-unit reconciler + 60s timer (Linux agent)
deploy/windows    bootstrap.ps1 (Docker + self-hosted GitHub Actions runner)
deploy/state      example desired-state files (the real ones live in the
                  separate hanomi-deploy-state repo)
terraform/        base infra (VPC, Cloud SQL, VMs, secrets, WIF)
terraform/scaling production MIG + load-balancer + autoscaling version
.github/workflows the deploy pipeline
README.md         the formal writeup (architecture, tradeoffs, failure matrix)
AI_USAGE.md       how Claude Code was used (required by the assignment)
WALKTHROUGH.md    this file
```

That's the whole thing. Sleep well — it's in good shape.
