# --- Internal Application (L7) Load Balancer for the backend ---
# Reachable only from inside the VPC (the frontend MIG), so the API is never
# exposed to the internet. Distributes requests across the backend MIG.

resource "google_compute_region_backend_service" "backend" {
  name                  = "hanomi-backend-bes"
  region                = var.region
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "INTERNAL_MANAGED"
  health_checks         = [google_compute_health_check.backend.id]

  backend {
    group           = google_compute_region_instance_group_manager.backend.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

resource "google_compute_region_url_map" "backend" {
  name            = "hanomi-backend-urlmap"
  region          = var.region
  default_service = google_compute_region_backend_service.backend.id
}

resource "google_compute_region_target_http_proxy" "backend" {
  name    = "hanomi-backend-proxy"
  region  = var.region
  url_map = google_compute_region_url_map.backend.id
}

# Internal LBs need a dedicated proxy-only subnet in the region.
resource "google_compute_subnetwork" "proxy_only" {
  name          = "hanomi-proxy-only"
  region        = var.region
  network       = var.network_id
  ip_cidr_range = "10.0.2.0/24"
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

resource "google_compute_forwarding_rule" "backend" {
  name                  = "hanomi-backend-fr"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.backend.id
  network               = var.network_id
  subnetwork            = var.subnetwork_id
  depends_on            = [google_compute_subnetwork.proxy_only]
}

# Allow the proxy-only subnet + health checks to reach backend instances.
resource "google_compute_firewall" "allow_lb_backend" {
  name      = "hanomi-allow-lb-backend"
  network   = var.network_id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
  source_ranges = ["10.0.2.0/24", "130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["hanomi-backend"]
}
