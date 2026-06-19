variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "asia-south1"
}

# Wired from the root module's outputs / existing resources.
variable "network_id" {
  type        = string
  description = "Self-link/id of the hanomi VPC (root module: google_compute_network.vpc.id)."
}
variable "subnetwork_id" {
  type        = string
  description = "Self-link/id of the hanomi subnet."
}
variable "state_repo_url" { type = string }
variable "state_bucket" { type = string }
variable "artifact_bucket" { type = string }

variable "service_accounts" {
  type        = map(string)
  description = "Per-service VM SA emails, keyed by service (backend/frontend/worker)."
}

# --- Per-service scaling envelopes (independent) ---
variable "scaling" {
  type = map(object({
    min_replicas : number
    max_replicas : number
    machine_type : string
  }))
  default = {
    backend  = { min_replicas = 2, max_replicas = 8, machine_type = "e2-small" }
    frontend = { min_replicas = 2, max_replicas = 10, machine_type = "e2-small" }
    # worker can scale to zero when the queue is empty.
    worker = { min_replicas = 0, max_replicas = 6, machine_type = "e2-medium" }
  }
}

variable "linux_image" {
  type    = string
  default = "projects/debian-cloud/global/images/family/debian-12"
}
variable "windows_image" {
  type    = string
  default = "projects/windows-cloud/global/images/family/windows-2022"
}
