locals {
  # DEMO (highly_available=false): one zone, so a regional MIG behaves zonally
  # and costs the least. PROD (true): spread across 3 zones for real HA.
  mig_zones = var.highly_available ? [
    "${var.region}-a", "${var.region}-b", "${var.region}-c"
  ] : [var.zone]

  # max_surge_fixed must be a multiple of the spanned zone count.
  mig_surge = length(local.mig_zones)

  # Instance redistribution only applies to a multi-zone regional MIG; it must
  # be NONE when the group spans a single zone, or GCP rejects the apply.
  mig_redistribution = var.highly_available ? "PROACTIVE" : "NONE"
}

# --- Instance templates (immutable VM blueprints) ---
# Linux services (backend, frontend): boot Debian, cloud-init installs the
# reconciler which converges to the desired digest in deploy-state.
resource "google_compute_instance_template" "linux" {
  for_each     = toset(["backend", "frontend"])
  name_prefix  = "hanomi-${each.key}-"
  machine_type = var.scaling[each.key].machine_type
  tags         = ["hanomi", "hanomi-${each.key}"]

  disk {
    source_image = var.linux_image
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = var.subnetwork_id
    # No access_config => no external IP. The external LB fronts the frontend;
    # egress is via Cloud NAT.
  }

  service_account {
    email  = var.service_accounts[each.key]
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = templatefile("${path.module}/../../deploy/linux/startup.sh.tftpl", {
      service        = each.key
      state_repo_url = var.state_repo_url
      state_bucket   = var.state_bucket
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Worker (Windows): native Windows Service reconciler; scales on queue depth.
resource "google_compute_instance_template" "worker" {
  name_prefix  = "hanomi-worker-"
  machine_type = var.scaling["worker"].machine_type
  tags         = ["hanomi", "hanomi-worker"]

  disk {
    source_image = var.windows_image
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = var.subnetwork_id
  }

  service_account {
    email  = var.service_accounts["worker"]
    scopes = ["cloud-platform"]
  }

  metadata = {
    windows-startup-script-ps1 = templatefile("${path.module}/../../deploy/windows/startup.ps1.tftpl", {
      state_repo_url  = var.state_repo_url
      state_bucket    = var.state_bucket
      artifact_bucket = var.artifact_bucket
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Health checks (used by the LB + MIG autohealing) ---
resource "google_compute_health_check" "backend" {
  name = "hanomi-backend-hc"
  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_health_check" "frontend" {
  name = "hanomi-frontend-hc"
  http_health_check {
    port         = 3000
    request_path = "/api/health"
  }
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

# --- Regional MIGs (the "ASGs"), one per service. Span 1 zone (demo) or 3
#     zones (highly_available=true), controlled by distribution_policy_zones. ---
resource "google_compute_region_instance_group_manager" "backend" {
  name                      = "hanomi-backend-mig"
  region                    = var.region
  base_instance_name        = "hanomi-backend"
  distribution_policy_zones = local.mig_zones

  version {
    instance_template = google_compute_instance_template.linux["backend"].id
  }

  named_port {
    name = "http"
    port = 8080
  }

  # Replace unhealthy instances automatically (self-healing at the fleet level).
  auto_healing_policies {
    health_check      = google_compute_health_check.backend.id
    initial_delay_sec = 90
  }

  # Health-gated rolling updates: never take everything down at once.
  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = local.mig_redistribution
    minimal_action               = "REPLACE"
    max_surge_fixed              = local.mig_surge
    max_unavailable_fixed        = 0
  }
}

resource "google_compute_region_instance_group_manager" "frontend" {
  name                      = "hanomi-frontend-mig"
  region                    = var.region
  base_instance_name        = "hanomi-frontend"
  distribution_policy_zones = local.mig_zones

  version {
    instance_template = google_compute_instance_template.linux["frontend"].id
  }

  named_port {
    name = "http"
    port = 3000
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.frontend.id
    initial_delay_sec = 90
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = local.mig_redistribution
    minimal_action               = "REPLACE"
    max_surge_fixed              = local.mig_surge
    max_unavailable_fixed        = 0
  }
}

resource "google_compute_region_instance_group_manager" "worker" {
  name                      = "hanomi-worker-mig"
  region                    = var.region
  base_instance_name        = "hanomi-worker"
  distribution_policy_zones = local.mig_zones

  version {
    instance_template = google_compute_instance_template.worker.id
  }

  # No LB health check (pull-based). Rolling replace on template change.
  # max_surge_fixed must be a multiple of the spanned zone count.
  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = local.mig_redistribution
    minimal_action               = "REPLACE"
    max_surge_fixed              = local.mig_surge
    max_unavailable_fixed        = 0
  }
}
