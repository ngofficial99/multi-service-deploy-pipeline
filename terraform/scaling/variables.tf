variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "asia-south1"
}

variable "zone" {
  type        = string
  default     = "asia-south1-a"
  description = "Single zone used when highly_available = false (demo/cheap mode)."
}

# DEMO DEFAULT = false: zonal MIGs in ONE zone (cheap, fewer VMs, single region).
# Flip to true for production: regional MIGs spread across 3 zones (real HA).
variable "highly_available" {
  type    = bool
  default = false
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
  # DEMO defaults below (max 1-2, cheap). For production you change ONLY these
  # numbers — nothing structural. e.g. to serve 100k users:
  #   backend  = { min_replicas = 20, max_replicas = 100, machine_type = "n2-standard-4" }
  #   frontend = { min_replicas = 20, max_replicas = 100, machine_type = "n2-standard-2" }
  #   worker   = { min_replicas = 5,  max_replicas = 100, machine_type = "n2-standard-2" }
  # The autoscaler, LB capacity, and MIG honor these directly; max is a hard cap,
  # min keeps that many warm. (Quota permitting — see README scaling notes.)
  default = {
    backend  = { min_replicas = 1, max_replicas = 1, machine_type = "e2-small" }
    frontend = { min_replicas = 1, max_replicas = 1, machine_type = "e2-small" }
    # worker can scale to zero when the queue is empty.
    worker = { min_replicas = 0, max_replicas = 1, machine_type = "e2-small" }
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
