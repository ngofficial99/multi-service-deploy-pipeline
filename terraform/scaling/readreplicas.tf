# Cloud SQL read replicas — scale read capacity independently of the primary.
#
# Count is fully configurable via var.read_replica_count (0 for the demo; set to
# 10 for production). Each replica is a real Cloud SQL instance that streams from
# the primary and serves read-only queries. The backend is given the replica
# endpoint(s) so read-heavy traffic (GET /leads, dashboards) hits replicas while
# writes (POST /leads) go to the primary — the standard read/write split that
# lets the data tier serve 100k users without overloading one primary.

variable "read_replica_count" {
  type        = number
  default     = 0 # demo = 0; production = e.g. 10
  description = "Number of Cloud SQL read replicas. 0 disables them."
}

variable "primary_instance_name" {
  type        = string
  default     = "hanomi-pg"
  description = "Name of the primary Cloud SQL instance (from the root module)."
}

variable "replica_tier" {
  type    = string
  default = "db-custom-2-7680" # replicas often sized >= primary for read load
}

resource "google_sql_database_instance" "read_replica" {
  count                = var.read_replica_count
  name                 = "hanomi-pg-replica-${count.index + 1}"
  region               = var.region
  database_version     = "POSTGRES_16"
  master_instance_name = var.primary_instance_name
  deletion_protection  = false

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = var.replica_tier
    availability_type = "ZONAL"
    ip_configuration {
      ipv4_enabled    = false # private IP only, same as primary
      private_network = var.network_id
    }
  }
}

output "read_replica_ips" {
  value       = [for r in google_sql_database_instance.read_replica : r.private_ip_address]
  description = "Private IPs of the read replicas; put these in the backend's READ_DATABASE_URLs."
}
