#!/usr/bin/env bash
#
# Linux reconciler — the data-plane agent for the backend and frontend VMs.
# Runs every ~60s via a systemd timer. It is a converging loop:
#
#   1. git-pull the deploy-state repo (desired state)
#   2. read the pinned image digest for this service
#   3. if it differs from what's running: fetch secrets, render+install the
#      Quadlet unit, pull the image, swap, restart
#   4. health-check the new version
#   5. on failure: roll back to the last-good digest and re-health-check
#   6. report actual state ({sha,healthy,error}) to GCS for the CI gate
#
# Idempotent and self-healing: if nothing changed it is a no-op; if the desired
# state is already running it does nothing. Safe to run on a timer forever.
set -euo pipefail

SERVICE="${SERVICE:?set SERVICE=backend|frontend}"
STATE_BUCKET="${STATE_BUCKET:?set STATE_BUCKET}"

STATE_REPO_DIR="/opt/hanomi/deploy-state"
QUADLET_DIR="/etc/containers/systemd"
ENVFILE="/etc/hanomi/${SERVICE}.env"
LASTGOOD="/var/lib/hanomi/${SERVICE}.lastgood"
TMPL="/opt/hanomi/deploy-state/deploy/linux/${SERVICE}.container.tmpl"
GCS_STATE="gs://${STATE_BUCKET}/state/${SERVICE}/actual.json"

case "$SERVICE" in
  backend)  HEALTH_URL="http://localhost:8080/healthz" ;;
  frontend) HEALTH_URL="http://localhost:3000/api/health" ;;
  *) echo "unknown service: $SERVICE" >&2; exit 2 ;;
esac

log() { echo "[reconciler/$SERVICE] $*"; }

report() { # healthy(true|false)  sha  error
  local tmp; tmp="$(mktemp)"
  cat >"$tmp" <<EOF
{"service":"${SERVICE}","sha":"${2}","healthy":${1},"error":"${3:-}","ts":"$(date -u +%FT%TZ)"}
EOF
  gcloud storage cp "$tmp" "$GCS_STATE" --quiet
  rm -f "$tmp"
}

deploy_image() { # image
  local img="$1"
  log "deploying $img"
  # Fetch secrets fresh into a 0600 env file owned by root (never logged).
  install -m 0600 /dev/null "$ENVFILE"
  gcloud secrets versions access latest --secret="hanomi-${SERVICE}-env" >"$ENVFILE"
  # Pull explicitly so a registry hiccup fails here, not mid-swap.
  podman pull "$img"
  # Render and install the Quadlet unit, then let systemd generate the service.
  sed -e "s#__IMAGE__#${img}#g" -e "s#__ENVFILE__#${ENVFILE}#g" \
    "$TMPL" >"${QUADLET_DIR}/${SERVICE}.container"
  systemctl daemon-reload
  systemctl restart "${SERVICE}.service"
}

healthy() {
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# 1) sync desired state
git -C "$STATE_REPO_DIR" pull --quiet --ff-only || log "git pull failed (using cached state)"
DESIRED_IMAGE="$(awk '/^image:/{print $2}' "$STATE_REPO_DIR/state/${SERVICE}/desired.yaml")"
CURRENT_IMAGE="$(cat "$LASTGOOD" 2>/dev/null || echo "")"

if [ -z "$DESIRED_IMAGE" ]; then
  log "no desired image found; nothing to do"
  exit 0
fi
if [ "$DESIRED_IMAGE" = "$CURRENT_IMAGE" ]; then
  exit 0  # converged
fi

log "desired=$DESIRED_IMAGE current=${CURRENT_IMAGE:-<none>}"

# 3) deploy desired, 4) health-check
deploy_image "$DESIRED_IMAGE"
if healthy; then
  echo "$DESIRED_IMAGE" >"$LASTGOOD"
  report true "$DESIRED_IMAGE" ""
  log "healthy on new version"
  exit 0
fi

# 5) rollback to last-good (if we have one)
log "new version unhealthy; rolling back"
if [ -n "$CURRENT_IMAGE" ]; then
  deploy_image "$CURRENT_IMAGE"
  if healthy; then
    report false "$CURRENT_IMAGE" "deploy_failed_rolled_back"
    log "rolled back to last-good and healthy"
    exit 1
  fi
fi

# 6) could not recover -> degraded; report and let the CI gate alert/freeze
report false "$DESIRED_IMAGE" "degraded_rollback_failed"
log "DEGRADED: rollback failed"
exit 1
