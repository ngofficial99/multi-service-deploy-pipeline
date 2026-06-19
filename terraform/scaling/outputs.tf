output "frontend_external_ip" {
  value       = google_compute_global_address.frontend.address
  description = "Public IP of the frontend Application Load Balancer."
}

output "backend_internal_forwarding_rule" {
  value       = google_compute_forwarding_rule.backend.ip_address
  description = "Internal VIP the frontend uses to reach the backend (set as BACKEND_URL)."
}

output "migs" {
  value = {
    backend  = google_compute_region_instance_group_manager.backend.name
    frontend = google_compute_region_instance_group_manager.frontend.name
    worker   = google_compute_region_instance_group_manager.worker.name
  }
}
