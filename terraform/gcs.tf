# Bucket holding the reconcilers' actual-state reports ({sha,healthy,error}).
# Versioned so the deploy history is auditable.
resource "google_storage_bucket" "state" {
  name                        = "${var.project_id}-hanomi-state"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  versioning {
    enabled = true
  }
}

# Bucket holding the Windows worker's pinned source per image digest
# (Windows runs the worker as a process, not a container, so CI publishes the
# source tree here under gs://.../worker/<digest-key>/).
resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project_id}-hanomi-artifacts"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}
