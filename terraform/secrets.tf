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
