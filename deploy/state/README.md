# deploy-state (GitOps desired state)

This directory is the **desired state** the VM reconcilers converge toward. In
production it lives in its own repository (`hanomi-deploy-state`) so that:

- a deploy is a **git commit** (full audit trail: who deployed which digest, when);
- a rollback is a **`git revert`**;
- the VMs only need **read** access to it (a deploy token in Secret Manager).

Each `*/desired.yaml` pins the service to an **immutable image digest**
(`@sha256:...`). CI (GitHub Actions) is the only writer: on a merge to `main`
it builds the image, resolves the digest, and commits the new digest here. The
VMs poll this repo (~60s) and reconcile.

The `REGION` / `PROJECT` / `REPLACED_BY_CI` tokens are placeholders that CI
overwrites with real values. They are committed so the repo is self-describing.

> In this monorepo submission the files live under `deploy/state/` for review
> convenience; the README explains the 1:1 mapping to the standalone repo.
