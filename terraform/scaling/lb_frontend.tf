# --- External Application (L7) Load Balancer for the frontend ---
# Public entry point. Distributes requests across the frontend MIG instances.

resource "google_compute_backend_service" "frontend" {
  name                  = "hanomi-frontend-bes"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_health_check.frontend.id]

  backend {
    group                 = google_compute_region_instance_group_manager.frontend.instance_group
    balancing_mode        = "RATE"
    max_rate_per_instance = 100 # feeds the LB-utilization autoscaler signal
  }
}

resource "google_compute_url_map" "frontend" {
  name            = "hanomi-frontend-urlmap"
  default_service = google_compute_backend_service.frontend.id
}

resource "google_compute_target_http_proxy" "frontend" {
  name    = "hanomi-frontend-proxy"
  url_map = google_compute_url_map.frontend.id
}

# A global address is implicitly Premium-tier, which the global external
# Application LB requires.
resource "google_compute_global_address" "frontend" {
  name = "hanomi-frontend-ip"
}

resource "google_compute_global_forwarding_rule" "frontend" {
  name                  = "hanomi-frontend-fr"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.frontend.id
  ip_address            = google_compute_global_address.frontend.id
}

# Allow the Google LB/health-check ranges to reach frontend instances.
resource "google_compute_firewall" "allow_lb_frontend" {
  name      = "hanomi-allow-lb-frontend"
  network   = var.network_id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["3000"]
  }
  # Google front-end + health-check source ranges.
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["hanomi-frontend"]
}
