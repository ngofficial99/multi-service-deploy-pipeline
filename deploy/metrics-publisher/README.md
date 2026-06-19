# Queue-depth metric publisher

A tiny job that powers the **worker autoscaler**. Every 60s (via Cloud
Scheduler) it queries Cloud SQL for the pending-lead backlog and writes it to
Cloud Monitoring as `custom.googleapis.com/hanomi/pending_leads`. The worker
MIG autoscaler targets ~5 pending leads per instance, so the backlog drives how
many workers run (and lets it scale to zero when empty).

Deploy as a Cloud Run service (built/pushed out-of-band so the Terraform module
has no build step), running as the `hanomi-metric-pub` service account that
`terraform/scaling/metrics.tf` provisions. Then point the Scheduler job's
`uri` at its `/publish` endpoint.

### Reference implementation (`publish.py`)

```python
import os
import time

import psycopg
from google.cloud import monitoring_v3

PROJECT = os.environ["GCP_PROJECT"]
DSN = os.environ["DATABASE_URL"]  # from Secret Manager


def pending_count() -> int:
    with psycopg.connect(DSN, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM leads WHERE status='pending'")
        return int(cur.fetchone()[0])


def publish(value: int) -> None:
    client = monitoring_v3.MetricServiceClient()
    series = monitoring_v3.TimeSeries()
    series.metric.type = "custom.googleapis.com/hanomi/pending_leads"
    series.resource.type = "global"
    point = monitoring_v3.Point({
        "interval": {"end_time": {"seconds": int(time.time())}},
        "value": {"int64_value": value},
    })
    series.points = [point]
    client.create_time_series(name=f"projects/{PROJECT}", time_series=[series])


# Cloud Run entrypoint (Flask/functions-framework): on POST /publish ->
#   publish(pending_count())
```

This is documented rather than fully wired so the `scaling` module stays
apply-able without a build pipeline. The metric descriptor, the publisher SA +
IAM, and the 60s Scheduler trigger are all created by Terraform.
