locals {
  services = ["backend", "frontend", "worker"]
}

# One env secret per service. Each holds the service's runtime env (DATABASE_URL,
# and for the worker the SMTP_* credentials). The VM fetches it at deploy time.
resource "google_secret_manager_secret" "env" {
  for_each  = toset(local.services)
  secret_id = "hanomi-${each.key}-env"

  replication {
    auto {}
  }
}

# NOTE: secret *versions* (the actual values) are added out-of-band
# (e.g. `gcloud secrets versions add hanomi-backend-env --data-file=...`),
# never committed and never stored in Terraform state.

# GitHub PAT (repo scope) the worker VM uses ONCE to fetch a self-hosted-runner
# registration token. Value added out-of-band; never in code/state.
resource "google_secret_manager_secret" "runner_pat" {
  secret_id = "hanomi-runner-pat"
  replication {
    auto {}
  }
}

# The worker VM SA may read the runner PAT (to register the runner at boot).
resource "google_secret_manager_secret_iam_member" "worker_runner_pat" {
  secret_id = google_secret_manager_secret.runner_pat.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.svc["worker"].email}"
}
