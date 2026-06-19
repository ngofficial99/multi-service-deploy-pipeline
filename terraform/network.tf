# --- Custom VPC: no default subnets, everything explicit ---
resource "google_compute_network" "vpc" {
  name                    = "hanomi-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "subnet" {
  name          = "hanomi-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id

  # Lets VMs with no external IP reach Google APIs (GCS, Secret Manager,
  # Artifact Registry, Cloud SQL) over Google's internal network.
  private_ip_google_access = true
}

# --- Egress for VMs with no external IP (image pulls, gcloud, apt) ---
resource "google_compute_router" "router" {
  name    = "hanomi-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "hanomi-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# --- Firewall ---
# Default is deny-all ingress (absence of an allow rule = denied). We add only
# what is strictly needed.

# Intra-VPC service ports so the frontend VM can reach the backend VM.
resource "google_compute_firewall" "allow_internal" {
  name      = "hanomi-allow-internal"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["8080", "3000"]
  }
  source_ranges = ["10.0.1.0/24"]
}

# Break-glass admin access (SSH/RDP) ONLY via Identity-Aware Proxy, which
# enforces IAM — no open SSH/RDP to the world. IAP connects from this range.
resource "google_compute_firewall" "allow_iap" {
  name      = "hanomi-allow-iap"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }
  source_ranges = ["35.235.240.0/20"] # Google IAP range
  target_tags   = ["hanomi"]
}

# --- Private Services Access: required for Cloud SQL private IP ---
resource "google_compute_global_address" "psa_range" {
  name          = "hanomi-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]
}
