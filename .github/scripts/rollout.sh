#!/usr/bin/env bash
#
# Gated, sequential rollout. For each CHANGED service, in order
# (backend -> frontend -> worker):
#
#   1. resolve the digest-pinned image (Linux services built here; the Windows
#      worker image is built by the build-worker-windows job and passed in via
#      WORKER_IMAGE)
#   2. commit the new digest to the deploy-state repo (this IS the deploy)
#   3. gate: poll the VM's actual.json in GCS until healthy on that digest, or fail
#
# A failed gate aborts the script (set -e), so later services are never touched
# — that is the partial-rollout policy: failed service self-reverts on its VM,
# already-deployed services stay, and undeployed services are skipped.
set -euo pipefail

: "${REGISTRY:?}" "${STATE_BUCKET:?}" "${GIT_SHA:?}"
: "${STATE_REPO:?}"

# Deploy-state repo is accessed over SSH using a write-enabled DEPLOY KEY scoped
# to ONLY that repo (more tightly scoped than a PAT, and unambiguous vs the
# main-repo credential actions/checkout installs). The private key is provided
# via the STATE_REPO_DEPLOY_KEY secret; the workflow writes it to STATE_SSH_KEY.
: "${STATE_SSH_KEY:?}"
export GIT_SSH_COMMAND="ssh -i ${STATE_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
STATE_REMOTE="git@github.com:${STATE_REPO}.git"

STATE_DIR="$(mktemp -d)"
git clone "$STATE_REMOTE" "$STATE_DIR"
git -C "$STATE_DIR" config user.email "ci@hanomi.ai"
git -C "$STATE_DIR" config user.name "hanomi-ci"

build_push() { # service -> prints image@digest on stdout
  local svc="$1"
  docker build -q -t "${REGISTRY}/${svc}:${GIT_SHA}" "apps/${svc}" >/dev/null
  docker push -q "${REGISTRY}/${svc}:${GIT_SHA}" >/dev/null
  # Resolve the immutable digest reference we just pushed.
  docker inspect --format='{{index .RepoDigests 0}}' "${REGISTRY}/${svc}:${GIT_SHA}"
}

set_desired() { # service image@digest
  local svc="$1" img="$2"
  printf 'service: %s\nimage: %s\n' "$svc" "$img" >"${STATE_DIR}/state/${svc}/desired.yaml"
  git -C "$STATE_DIR" add -A
  git -C "$STATE_DIR" commit -q -m "deploy(${svc}): ${img}"
  git -C "$STATE_DIR" push -q
}

gate() { # service image@digest
  local svc="$1" img="$2" deadline=$(( SECONDS + 300 )) body=""
  # Require the VM to report healthy FOR THIS digest — not just "healthy"
  # (which could be a stale healthy from the previous version).
  local want="${img##*@}"   # sha256:...
  echo "⏳ gating ${svc} (waiting for healthy actual.json @ ${want})…"
  while (( SECONDS < deadline )); do
    body="$(gcloud storage cat "gs://${STATE_BUCKET}/state/${svc}/actual.json" 2>/dev/null || true)"
    if echo "$body" | grep -q '"healthy":true' && echo "$body" | grep -q "$want"; then
      echo "✅ ${svc} healthy on ${want}: ${body}"
      return 0
    fi
    if echo "$body" | grep -q 'degraded_rollback_failed'; then
      echo "🔥 ${svc} DEGRADED — rollback failed on the VM: ${body}" >&2
      return 1
    fi
    sleep 10
  done
  echo "❌ ${svc} did not become healthy on ${want} within timeout. Last state: ${body:-<none>}" >&2
  return 1
}

rollout() { # service flag
  local svc="$1" flag="$2"
  if [ "$flag" != "true" ]; then
    echo "⏭  ${svc} unchanged — skipping"
    return 0
  fi
  echo "▶ deploying ${svc}"
  local img; img="$(build_push "$svc")"
  echo "   built ${img}"
  set_desired "$svc" "$img"
  gate "$svc" "$img"   # non-zero return aborts (set -e); later services untouched
}

# Linux services only. backend first (API contract), then frontend (UI only
# ships once its backend is healthy). The Windows worker deploys separately via
# its self-hosted runner (see the deploy-worker job in deploy.yml).
rollout backend  "${DEPLOY_BACKEND:-false}"
rollout frontend "${DEPLOY_FRONTEND:-false}"

echo "🎉 rollout complete"
