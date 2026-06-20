#!/usr/bin/env bash
#
# Gated, sequential rollout. For each CHANGED service, in order
# (backend -> worker -> frontend):
#
#   1. build the image once and push it (digest-pinned)
#   2. [worker] also publish its source tree to the artifacts bucket per digest
#      (the Windows worker runs it as a process, not a container)
#   3. commit the new digest to the deploy-state repo (this IS the deploy)
#   4. gate: poll the VM's actual.json in GCS until healthy, or fail
#
# A failed gate aborts the script (set -e), so later services are never touched
# — that is the partial-rollout policy: failed service self-reverts on its VM,
# already-deployed services stay, and undeployed services are skipped.
set -euo pipefail

: "${REGISTRY:?}" "${STATE_BUCKET:?}" "${ARTIFACT_BUCKET:?}" "${GIT_SHA:?}"
: "${STATE_REPO:?}" "${STATE_REPO_TOKEN:?}"

STATE_DIR="$(mktemp -d)"
# Auth header for the deploy-state repo. actions/checkout configures a global
# credential header that injects the MAIN repo's GITHUB_TOKEN for all github.com
# requests — which 403s on push to the (different) deploy-state repo. We pass our
# own Authorization header inline on every git op below (via STATE_GIT), and a
# blank global extraheader to neutralise the inherited one.
AUTH_B64="$(printf 'x-access-token:%s' "${STATE_REPO_TOKEN}" | base64 | tr -d '\n')"
STATE_GIT=(git -c "http.https://github.com/.extraheader=Authorization: Basic ${AUTH_B64}")

"${STATE_GIT[@]}" clone "https://github.com/${STATE_REPO}.git" "$STATE_DIR"
git -C "$STATE_DIR" config user.email "ci@hanomi.ai"
git -C "$STATE_DIR" config user.name "hanomi-ci"

build_push() { # service -> prints image@digest on stdout
  local svc="$1"
  docker build -q -t "${REGISTRY}/${svc}:${GIT_SHA}" "apps/${svc}" >/dev/null
  docker push -q "${REGISTRY}/${svc}:${GIT_SHA}" >/dev/null
  # Resolve the immutable digest reference we just pushed.
  docker inspect --format='{{index .RepoDigests 0}}' "${REGISTRY}/${svc}:${GIT_SHA}"
}

publish_worker_source() { # image@digest
  # The Windows worker runs the pinned source as a Windows Service. Publish the
  # source under a per-digest key the reconciler's install-service.ps1 syncs.
  local img="$1"
  local key="${img##*@}"; key="${key//[:\/]/_}"
  gcloud storage rsync -r -x '(__pycache__|\.venv|outbox|\.pytest_cache).*' \
    apps/worker "gs://${ARTIFACT_BUCKET}/worker/${key}" >/dev/null
}

set_desired() { # service image@digest
  local svc="$1" img="$2"
  printf 'service: %s\nimage: %s\n' "$svc" "$img" >"${STATE_DIR}/state/${svc}/desired.yaml"
  git -C "$STATE_DIR" add -A
  git -C "$STATE_DIR" commit -q -m "deploy(${svc}): ${img}"
  "${STATE_GIT[@]}" -C "$STATE_DIR" push -q
}

gate() { # service
  local svc="$1" deadline=$(( SECONDS + 300 )) body=""
  echo "⏳ gating ${svc} (waiting for healthy actual.json)…"
  while (( SECONDS < deadline )); do
    body="$(gcloud storage cat "gs://${STATE_BUCKET}/state/${svc}/actual.json" 2>/dev/null || true)"
    if echo "$body" | grep -q '"healthy":true'; then
      echo "✅ ${svc} healthy: ${body}"
      return 0
    fi
    if echo "$body" | grep -q 'degraded_rollback_failed'; then
      echo "🔥 ${svc} DEGRADED — rollback failed on the VM: ${body}" >&2
      return 1
    fi
    sleep 10
  done
  echo "❌ ${svc} did not become healthy within timeout. Last state: ${body:-<none>}" >&2
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
  if [ "$svc" = "worker" ]; then
    publish_worker_source "$img"
  fi
  set_desired "$svc" "$img"
  gate "$svc"   # non-zero return aborts (set -e); later services untouched
}

# Sequential, fail-fast. backend -> worker -> frontend.
rollout backend  "${DEPLOY_BACKEND:-false}"
rollout worker   "${DEPLOY_WORKER:-false}"
rollout frontend "${DEPLOY_FRONTEND:-false}"

echo "🎉 rollout complete"
