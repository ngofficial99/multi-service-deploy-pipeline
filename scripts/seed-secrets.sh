#!/usr/bin/env bash
# Seed the three Secret Manager secrets with their runtime env. Run AFTER
# `terraform apply` (the secret containers must exist) and after creating the
# Cloud SQL app user. Values never live in git or Terraform state.
#
# Usage: PROJECT=... REGION=... DB_PASS=... ./scripts/seed-secrets.sh
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT}"
ZONE="${ZONE:-asia-south1-a}"
DB_PASS="${DB_PASS:?set DB_PASS (Cloud SQL hanomi_app password)}"

# Cloud SQL private IP (stable — it's a managed service, not a VM).
DB_IP="$(gcloud sql instances describe hanomi-pg --project "$PROJECT" \
  --format='value(ipAddresses[0].ipAddress)')"
DB_URL="postgres://hanomi_app:${DB_PASS}@${DB_IP}:5432/hanomi?sslmode=disable"

# Backend is addressed by its STABLE GCE internal DNS name — this survives VM
# recreation, unlike the ephemeral internal IP (a real bug we hit live).
BACKEND_DNS="hanomi-backend.${ZONE}.c.${PROJECT}.internal"

printf 'DATABASE_URL=%s\nPORT=8080\n' "$DB_URL" \
  | gcloud secrets versions add hanomi-backend-env --data-file=- --project "$PROJECT"

printf 'BACKEND_URL=http://%s:8080\nPORT=3000\n' "$BACKEND_DNS" \
  | gcloud secrets versions add hanomi-frontend-env --data-file=- --project "$PROJECT"

# Worker: offline file-mode email (no SMTP_*). Add SMTP_HOST/USER/PASS here to
# send real mail (e.g. Brevo). DATABASE_URL points at the same Cloud SQL.
printf 'DATABASE_URL=%s\nWORKER_ID=worker-vm-1\nPOLL_INTERVAL=5\nOUTBOX_DIR=C:\\hanomi\\outbox\n' "$DB_URL" \
  | gcloud secrets versions add hanomi-worker-env --data-file=- --project "$PROJECT"

echo "seeded backend/frontend/worker secrets (DB_IP=$DB_IP, backend via $BACKEND_DNS)"
