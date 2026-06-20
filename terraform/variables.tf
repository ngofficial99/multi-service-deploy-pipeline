variable "project_id" {
  type        = string
  description = "GCP project ID to deploy into."
}

variable "region" {
  type        = string
  default     = "asia-south1"
  description = "Region for the VPC, VMs, Cloud SQL, Artifact Registry, GCS."
}

variable "zone" {
  type        = string
  default     = "asia-south1-a"
  description = "Zone for the Compute Engine VMs."
}

variable "github_repo" {
  type        = string
  description = "owner/repo of the parent repo, used to scope Workload Identity Federation."
}

variable "state_repo_url" {
  type        = string
  description = "https URL of the deploy-state repo the VM reconcilers pull."
}

variable "linux_machine_type" {
  type    = string
  default = "e2-small"
}

variable "windows_machine_type" {
  type    = string
  default = "e2-small"
  # e2-small (2GB) is enough for the Python polling worker. e2-medium (4GB)
  # only gives Windows extra headroom during the install-heavy first bootstrap;
  # bump back to e2-medium if the bootstrap is memory-starved on 2GB.
}

variable "cloudsql_tier" {
  type    = string
  default = "db-f1-micro" # cheapest shared-core for the demo; bump for production
  # production example: "db-custom-2-7680" or larger; pair with read replicas.
}

variable "cloudsql_backups" {
  type    = bool
  default = false # off for the cheap demo; true for production
}
