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
  default = "e2-standard-2"
  # Windows Server + Docker (container host) needs real headroom — e2-small (2GB)
  # was starved and made the bootstrap crawl/hang. e2-standard-2 (2 vCPU / 8GB)
  # is the right size for a Windows container host.
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
