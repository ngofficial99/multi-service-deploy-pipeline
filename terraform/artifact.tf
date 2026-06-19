# Docker image registry. CI pushes digest-pinned images here; VMs pull from it
# over Private Google Access.
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "hanomi"
  format        = "DOCKER"
  description   = "Hanomi service images (backend, frontend, worker)."
}
