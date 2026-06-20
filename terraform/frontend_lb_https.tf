# HTTPS for the frontend LB — production. Gated on var.domain: empty (demo) =>
# HTTP only on the IP; set a domain (pointed at the LB IP) => a Google-managed
# TLS cert + :443 HTTPS proxy + an HTTP->HTTPS redirect. No fake/self-signed
# certs; managed certs require a real domain, so this activates by config.

variable "domain" {
  type        = string
  default     = ""
  description = "Public domain for the frontend (e.g. app.hanomi.example). Empty = HTTP-only demo. Point its A record at output frontend_public_ip, then `terraform apply`."
}

# Google-managed cert (auto-provisions + renews once the domain resolves to the LB IP).
resource "google_compute_managed_ssl_certificate" "frontend" {
  count = var.domain == "" ? 0 : 1
  name  = "hanomi-frontend-cert"
  managed {
    domains = [var.domain]
  }
}

resource "google_compute_target_https_proxy" "frontend" {
  count            = var.domain == "" ? 0 : 1
  name             = "hanomi-frontend-https-proxy"
  url_map          = google_compute_url_map.frontend_lb.id
  ssl_certificates = [google_compute_managed_ssl_certificate.frontend[0].id]
}

resource "google_compute_global_forwarding_rule" "frontend_https" {
  count                 = var.domain == "" ? 0 : 1
  name                  = "hanomi-frontend-https-fr"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.frontend[0].id
  ip_address            = google_compute_global_address.frontend_lb.id
}

# When a domain is set, the :80 path becomes a 301 redirect to HTTPS.
resource "google_compute_url_map" "frontend_redirect" {
  count = var.domain == "" ? 0 : 1
  name  = "hanomi-frontend-redirect"
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

output "frontend_https_url" {
  value       = var.domain == "" ? "(set var.domain to enable HTTPS)" : "https://${var.domain}/"
  description = "Public HTTPS URL once the domain's A record points at frontend_public_ip."
}
