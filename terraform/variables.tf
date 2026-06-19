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
  default = "e2-medium"
}
