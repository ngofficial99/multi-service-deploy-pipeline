# --- Per-service VM service accounts (least privilege) ---
resource "google_service_account" "svc" {
  for_each     = toset(local.services)
  account_id   = "hanomi-${each.key}"
  display_name = "Hanomi ${each.key} VM"
}

# Each VM SA may read ONLY its own service's secret.
resource "google_secret_manager_secret_iam_member" "read_own" {
  for_each  = toset(local.services)
  secret_id = google_secret_manager_secret.env[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.svc[each.key].email}"
}

# All VM SAs may pull images and connect to Cloud SQL.
resource "google_project_iam_member" "vm_project_roles" {
  for_each = {
    for pair in setproduct(local.services, [
      "roles/artifactregistry.reader",
      "roles/cloudsql.client",
      "roles/cloudsql.instanceUser",
    ]) : "${pair[0]}-${pair[1]}" => { svc = pair[0], role = pair[1] }
  }
  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.svc[each.value.svc].email}"
}

# VM SAs write their actual.json to the state bucket and (worker) read source
# from the artifacts bucket. Scoped to the specific buckets, not project-wide.
resource "google_storage_bucket_iam_member" "state_rw" {
  for_each = toset(local.services)
  bucket   = google_storage_bucket.state.name
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${google_service_account.svc[each.key].email}"
}

resource "google_storage_bucket_iam_member" "worker_artifacts_ro" {
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.svc["worker"].email}"
}
