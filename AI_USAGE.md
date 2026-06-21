# AI Tools Used

Per the assignment's encouragement to use AI tools and note how, here's an
honest account.

**Tool:** Claude Code (Anthropic's agentic CLI), driven interactively.

The architecture decisions, the direction, and every judgement call were mine.
Claude was used to pressure-test ideas, run research, scaffold code, and (most
usefully) debug the live deployment against real GCP. I reviewed and approved
each step.

## My direction / ideas (what I drove)

- Chose **GCP over AWS** deliberately — the role is an AWS→GCP migration, so I
  wanted the artifact to demonstrate current GCP depth.
- Pushed back on early over-engineering: I rejected a Pub/Sub-based change
  signal as overkill, insisted the demo footprint stay **small and
  single-region** behind a flag to control cost, and pruned the scaling defaults
  to min/max of 1–2 instances.
- Steered the design questions: GitOps repo vs. object-store for desired state,
  "is there an Argo-for-VMs," whether to use Jenkins, deploy-key vs. PAT for the
  cross-repo push, and the autoscaling model (ASG-per-service behind LBs).
- Directed the product framing — making the demo a real Hanomi lead-capture flow
  (landing page → form → backend → worker emails the welcome message), the exact
  form fields, the welcome-email copy, and the `invite_sent` tracking column.
- Decided to actually deploy it live on my own GCP project and debug it end to
  end, rather than hand in untested config.

## Where Claude helped, by phase

**Design / brainstorming.** Explored tradeoffs for each decision (control-plane
vs data-plane, rollback strategy, partial-failure policy, secrets handling)
before writing anything. Produced the design spec and the implementation plan.

**Research.** Ran a multi-source, fact-checked research pass on "tools that keep
a container at a desired state on a single VM." This surfaced the key finding
that GCP's native `gce-container-declaration` / konlet path is **deprecated with
a 2026 cutoff**, and pointed to **Podman + Quadlet** as the current self-healing
reconciler. Claims were adversarially verified before I acted on them.

**Implementation.** Scaffolded the three apps (Go/Gin, Python worker, Next.js),
both Terraform modules, the Linux reconciler, the Windows worker's container +
self-hosted-runner deploy path, and the GitHub Actions workflow. I had it verify
the apps end-to-end locally with `docker compose` (form submission → lead row →
worker email) before moving on.

**Live deployment & debugging.** This was the highest-value part. We applied the
infra to a real GCP project and debugged the real failures that only appear
against live cloud — cross-repo Git push auth (switched PAT → SSH deploy key), a
missing executable bit breaking the systemd reconciler, Podman not being
authenticated to Artifact Registry (fixed via a metadata-token login), and
`gcloud` not being preinstalled on the base Debian image. Each fix was committed.

**Frontend design.** Generated the Hanomi landing page and the `/try` demo page
to match the real site (light theme, the real form fields and copy).

## What I'd want a reviewer to know

I treated Claude like a fast, knowledgeable pair-programmer: I made the calls, it
accelerated the typing, the research, and the live debugging. The interesting
engineering — the GitOps control/data-plane split, the partial-failure policy,
the private networking, the autoscaling model, and the decision to validate it
on real infrastructure — is the part I'd be happy to defend line by line in the
discussion.
