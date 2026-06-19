# Production scaling module — MIGs + autoscaling + load balancers

This is the **production-ready** evolution of the root single-VM design. The
brief capped targets at "3 separate VMs, not K8s"; that is a single point of
failure and cannot scale, so this module replaces each named VM with the GCP
equivalent of an AWS Auto Scaling Group behind a load balancer:

| AWS | GCP (here) |
|---|---|
| Launch Template | Instance Template |
| Auto Scaling Group | **regional Managed Instance Group (MIG)** |
| ASG scaling policy | **Autoscaler** |
| ALB + Target Group | **Application (L7) Load Balancer + Backend Service** |
| Target Group health check | LB health check |

**One MIG per service, scaling independently:**

| Service | MIG | Scales on | Load balancer | Min→Max |
|---|---|---|---|---|
| frontend | regional | HTTP LB utilization | **External** L7 HTTPS | 1 → 2 |
| backend | regional | HTTP LB utilization | **Internal** L7 (frontend-only) | 1 → 2 |
| worker | regional (Windows) | **queue depth** (custom metric: pending leads) | none — pull-based | 0 → 2 |

### Cost control: `highly_available` flag (default `false` for the demo)

- **`highly_available = false` (default):** every MIG spans **one zone**
  (`var.zone`) in a **single region**, min replicas are 1 (worker 0), max 2.
  This is the cheap demo footprint — the fewest VMs that still demonstrate
  autoscaling, LBs, and self-healing.
- **`highly_available = true`:** MIGs spread across **3 zones** for real HA, with
  proactive instance redistribution. Flip this (and bump the `scaling` maxes via
  `terraform.tfvars`) for production. Nothing else changes — it is one flag.

Tune everything in `variables.tf` (or override in `terraform.tfvars`):
`scaling` (min/max/machine_type per service), `zone`, `highly_available`.

### Why each signal

- **frontend / backend** bottleneck on request load, so they scale on the load
  balancer's serving capacity (`max_rate_per_instance`). This reacts to real
  traffic, not just CPU.
- **worker** is a pull-based queue consumer using `FOR UPDATE SKIP LOCKED`, so
  running many copies is already safe. It scales on the **backlog** — a Cloud
  Monitoring custom metric publishing `COUNT(*) WHERE status='pending'` — and
  can scale to **zero** when idle. CPU would be the wrong signal (a backed-up
  queue can sit at low CPU).

### How it composes with the GitOps reconciler (the payoff)

Autoscaling required **almost no change** to the deploy model. Every new MIG
instance boots from the template, runs the same cloud-init, installs the same
reconciler, and converges to the digest declared in `deploy-state`. Instances
are cattle that self-configure — scaling out is free.

**What does change** is the rollout gate: with N instances, the single
`state/<svc>/actual.json` object is no longer "the" truth. Here the rollout
gates on **MIG health + the load balancer health check** (≥ healthy threshold)
instead of one file. Regional MIGs also give real **rolling updates**
(`max_surge` / `max_unavailable`) with health-gated instance replacement — which
eliminates the single-VM restart-blip limitation of the root design entirely.

### Horizontal vs vertical

- **Horizontal** is automatic via the autoscaler (`min`/`max` replicas per MIG).
- **Vertical** on plain VMs is not a live operation: change `machine_type` in the
  instance template and the MIG does a rolling replace. GCE provides
  right-sizing *recommendations* (from observed usage) that you apply this way.
  True live vertical autoscaling is a GKE (VPA) feature, which the brief excluded.

> This module reuses the root module's network, Cloud SQL, Secret Manager,
> Artifact Registry, GCS, and service accounts via variables — it only adds the
> scalable compute + LB layer. Run the root module first.
