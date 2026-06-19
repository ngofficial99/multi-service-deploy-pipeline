# --- Worker queue-depth custom metric (drives the worker autoscaler) ---
#
# The worker scales on backlog, not CPU. We publish a GAUGE metric
# custom.googleapis.com/hanomi/pending_leads = COUNT(*) of pending leads.
#
# Publisher: a tiny Cloud Run job invoked by Cloud Scheduler every 60s that runs
#   SELECT count(*) FROM leads WHERE status='pending'
# against Cloud SQL (private IP) and writes the metric via the Monitoring API.
# The job's source lives in deploy/metrics-publisher/ (see that README); it is
# deployed out-of-band so this module stays free of build steps.

resource "google_monitoring_metric_descriptor" "pending_leads" {
  description  = "Number of pending Hanomi leads awaiting the worker."
  display_name = "Hanomi pending leads"
  type         = "custom.googleapis.com/hanomi/pending_leads"
  metric_kind  = "GAUGE"
  value_type   = "INT64"
}

# SA the publisher runs as: read Cloud SQL + write monitoring time series.
resource "google_service_account" "metric_publisher" {
  account_id   = "hanomi-metric-pub"
  display_name = "Hanomi queue-depth metric publisher"
}

resource "google_project_iam_member" "publisher_roles" {
  for_each = toset([
    "roles/monitoring.metricWriter",
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.metric_publisher.email}"
}

# Scheduled trigger (every 60s). The target Cloud Run job URL is wired when the
# publisher is deployed; kept as a variable-free stub here to avoid a hard dep.
resource "google_cloud_scheduler_job" "publish_queue_depth" {
  name      = "hanomi-publish-queue-depth"
  schedule  = "* * * * *" # every minute
  region    = var.region
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://REPLACED_WITH_PUBLISHER_RUN_URL/publish"
    oidc_token {
      service_account_email = google_service_account.metric_publisher.email
    }
  }

  # The publisher isn't deployed by this module; don't thrash on its URL.
  lifecycle {
    ignore_changes = [http_target[0].uri]
  }
}
