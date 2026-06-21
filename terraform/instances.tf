locals {
  linux_image   = "projects/debian-cloud/global/images/family/debian-12"
  windows_image = "projects/windows-cloud/global/images/family/windows-2022"
}

# --- Linux service VMs (backend, frontend): Podman + Quadlet reconciler ---
resource "google_compute_instance" "linux" {
  for_each     = toset(["backend", "frontend"])
  name         = "hanomi-${each.key}"
  machine_type = var.linux_machine_type
  zone         = var.zone
  tags         = ["hanomi"]

  boot_disk {
    initialize_params {
      image = local.linux_image
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    # No access_config block => NO external IP.
  }

  service_account {
    email  = google_service_account.svc[each.key].email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = templatefile("${path.module}/../deploy/linux/startup.sh.tftpl", {
    service        = each.key
    state_repo_url = var.state_repo_url
    state_bucket   = google_storage_bucket.state.name
  })

  depends_on = [google_compute_router_nat.nat]
}

# --- Windows worker VM: native Windows Service reconciler ---
resource "google_compute_instance" "windows" {
  name         = "hanomi-worker"
  machine_type = var.windows_machine_type
  zone         = var.zone
  tags         = ["hanomi"]

  boot_disk {
    initialize_params {
      image = local.windows_image
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  service_account {
    email  = google_service_account.svc["worker"].email
    scopes = ["cloud-platform"]
  }

  metadata = {
    windows-startup-script-ps1 = templatefile("${path.module}/../deploy/windows/startup.ps1.tftpl", {
      github_repo   = var.github_repo
      runner_secret = google_secret_manager_secret.runner_pat.secret_id
    })
  }

  depends_on = [google_compute_router_nat.nat]
}
