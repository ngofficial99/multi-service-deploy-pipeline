# Public entry point for the frontend (demo).
#
# The production answer is the autoscaling MIG + LB in terraform/scaling/. For a
# simple, low-cost public URL on the single-VM demo, this fronts the existing
# standalone frontend VM with an external HTTP Application Load Balancer via an
# unmanaged instance group. (Kept separate so it's easy to remove.)

resource "google_compute_instance_group" "frontend" {
  name      = "hanomi-frontend-ig"
  zone      = var.zone
  instances = [google_compute_instance.linux["frontend"].self_link]
  named_port {
    name = "http"
    port = 3000
  }
}

resource "google_compute_health_check" "frontend_lb" {
  name = "hanomi-frontend-lb-hc"
  http_health_check {
    port         = 3000
    request_path = "/api/health"
  }
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_backend_service" "frontend_lb" {
  name                  = "hanomi-frontend-lb-bes"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_health_check.frontend_lb.id]
  backend {
    group           = google_compute_instance_group.frontend.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

resource "google_compute_url_map" "frontend_lb" {
  name            = "hanomi-frontend-lb-urlmap"
  default_service = google_compute_backend_service.frontend_lb.id
}

resource "google_compute_target_http_proxy" "frontend_lb" {
  name    = "hanomi-frontend-lb-proxy"
  url_map = google_compute_url_map.frontend_lb.id
}

resource "google_compute_global_address" "frontend_lb" {
  name = "hanomi-frontend-lb-ip"
}

resource "google_compute_global_forwarding_rule" "frontend_lb" {
  name                  = "hanomi-frontend-lb-fr"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.frontend_lb.id
  ip_address            = google_compute_global_address.frontend_lb.id
}

# Allow Google LB + health-check ranges to reach the frontend VM on :3000.
resource "google_compute_firewall" "allow_lb_frontend" {
  name      = "hanomi-allow-lb-frontend"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["3000"]
  }
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["hanomi"]
}

output "frontend_public_ip" {
  value       = google_compute_global_address.frontend_lb.address
  description = "Public IP of the frontend load balancer (http://<ip>/)."
}
