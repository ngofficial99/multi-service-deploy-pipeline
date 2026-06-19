# --- GitHub Actions auth via Workload Identity Federation (no static keys) ---
resource "google_service_account" "ci" {
  account_id   = "hanomi-ci"
  display_name = "Hanomi GitHub Actions CI"
}

resource "google_iam_workload_identity_pool" "gh" {
  workload_identity_pool_id = "hanomi-gh-pool"
  display_name              = "Hanomi GitHub pool"
}

resource "google_iam_workload_identity_pool_provider" "gh" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.gh.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  # Only tokens from our repo are accepted.
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Only this repo may impersonate the CI service account.
resource "google_service_account_iam_member" "wif_bind" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gh.name}/attribute.repository/${var.github_repo}"
}

# CI may push images.
resource "google_project_iam_member" "ci_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# CI writes the Windows worker source per digest to the artifacts bucket.
resource "google_storage_bucket_iam_member" "ci_artifacts_rw" {
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.ci.email}"
}

# CI reads actual.json from the state bucket to gate the rollout.
resource "google_storage_bucket_iam_member" "ci_state_ro" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.ci.email}"
}
