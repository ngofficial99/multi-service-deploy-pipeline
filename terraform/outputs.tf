output "ci_service_account" {
  value       = google_service_account.ci.email
  description = "Set as the CI_SA GitHub Actions variable."
}

output "wif_provider" {
  value       = google_iam_workload_identity_pool_provider.gh.name
  description = "Set as the WIF_PROVIDER GitHub Actions variable."
}

output "artifact_registry" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}"
  description = "Image registry base; matches the REGISTRY env in the workflow."
}

output "state_bucket" {
  value       = google_storage_bucket.state.name
  description = "Set as the STATE_BUCKET GitHub Actions variable."
}

output "artifacts_bucket" {
  value = google_storage_bucket.artifacts.name
}

output "cloudsql_private_ip" {
  value       = google_sql_database_instance.pg.private_ip_address
  description = "Use to build DATABASE_URL stored in Secret Manager."
}

output "cloudsql_connection_name" {
  value = google_sql_database_instance.pg.connection_name
}
