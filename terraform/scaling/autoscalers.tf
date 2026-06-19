# --- Per-service autoscalers (independent scaling envelopes) ---

# backend: scale on HTTP load-balancing serving utilization.
resource "google_compute_region_autoscaler" "backend" {
  name   = "hanomi-backend-as"
  region = var.region
  target = google_compute_region_instance_group_manager.backend.id

  autoscaling_policy {
    min_replicas    = var.scaling["backend"].min_replicas
    max_replicas    = var.scaling["backend"].max_replicas
    cooldown_period = 60
    load_balancing_utilization {
      target = 0.7
    }
  }
}

# frontend: scale on HTTP load-balancing serving utilization.
resource "google_compute_region_autoscaler" "frontend" {
  name   = "hanomi-frontend-as"
  region = var.region
  target = google_compute_region_instance_group_manager.frontend.id

  autoscaling_policy {
    min_replicas    = var.scaling["frontend"].min_replicas
    max_replicas    = var.scaling["frontend"].max_replicas
    cooldown_period = 60
    load_balancing_utilization {
      target = 0.7
    }
  }
}

# worker: scale on QUEUE DEPTH. A small sidecar publishes the custom metric
# custom.googleapis.com/hanomi/pending_leads (see metrics.tf). The autoscaler
# adds workers to keep the per-instance backlog near the target, and can scale
# to zero (min_replicas = 0) when the queue is empty.
resource "google_compute_region_autoscaler" "worker" {
  name   = "hanomi-worker-as"
  region = var.region
  target = google_compute_region_instance_group_manager.worker.id

  autoscaling_policy {
    min_replicas    = var.scaling["worker"].min_replicas
    max_replicas    = var.scaling["worker"].max_replicas
    cooldown_period = 60

    metric {
      name = "custom.googleapis.com/hanomi/pending_leads"
      type = "GAUGE"
      # pending_leads is a TOTAL backlog gauge, so use single_instance_assignment:
      # each worker is expected to handle ~5 pending leads, so the autoscaler
      # provisions ceil(pending_leads / 5) workers. This is the correct
      # queue-depth semantic (vs. `target`, which targets a per-instance value).
      single_instance_assignment = 5
    }
  }
}
