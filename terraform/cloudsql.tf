# Cloud SQL Postgres with PRIVATE IP only — no public endpoint. Reached by the
# backend/worker VMs over Private Services Access (VPC peering).
resource "google_sql_database_instance" "pg" {
  name             = "hanomi-pg"
  database_version = "POSTGRES_16"
  region           = var.region

  # The private IP cannot be assigned until the PSA peering exists.
  depends_on = [google_service_networking_connection.psa]

  # Take-home convenience; set to true for any real environment.
  deletion_protection = false

  settings {
    tier              = "db-custom-1-3840"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled    = false # NO public IP
      private_network = google_compute_network.vpc.id
    }

    # Allow IAM database authentication (preferred over passwords).
    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    backup_configuration {
      enabled = true
    }
  }
}

resource "google_sql_database" "db" {
  name     = "hanomi"
  instance = google_sql_database_instance.pg.name
}
