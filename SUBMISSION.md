# Submission message (copy/paste)

**Repo:** https://github.com/ngofficial99/multi-service-deploy-pipeline
**GitOps state repo:** https://github.com/ngofficial99/hanomi-deploy-state

---

Hi team,

Here's my take-home for the Hanomi multi-service deploy pipeline:
https://github.com/ngofficial99/multi-service-deploy-pipeline

**Approach.** I built it on **GCP** (given the AWS→GCP migration focus) as a
**GitOps pipeline with a control-plane / data-plane split**: GitHub Actions
builds digest-pinned images and commits the desired version to a separate
`deploy-state` repo; each VM runs a small reconciler that pulls that state,
converges, health-checks itself, and reports back. No SSH, no inbound ports, no
static keys — CI authenticates to GCP via Workload Identity Federation.

**What's covered:** rollback (git-revert of the digest + last-good image),
per-service health checks, secrets via Secret Manager (each VM reads only its
own), and an explicit partial-failure policy (failed service self-reverts,
already-deployed services stay, later services are never touched). Private
networking throughout — no public IPs, private Cloud SQL over VPC peering.

**To make it concrete** I included three real apps — a Hanomi landing page with
a "Try Hanomi" form (Next.js), a Go/Gin backend that captures leads into Cloud
SQL, and a Python worker (Windows) that emails the welcome message — and I
**deployed the whole thing live** on my own GCP project to validate it, rather
than hand in untested config. There's also a production scaling module (one
autoscaling Managed Instance Group per service behind load balancers).

The `README.md` has the architecture, tradeoffs, the failure matrix, and the
AWS→GCP mapping. `WALKTHROUGH.md` is a plain-English tour. `AI_USAGE.md` notes
how I used Claude Code (research, scaffolding, and live debugging — direction and
decisions were mine).

Happy to walk through any of it live, including the design tradeoffs and the
real bugs I hit deploying it.

Thanks,
Nishant
