# Windows worker reconciler — the data-plane agent for the Windows worker VM.
# Runs every ~60s via a Scheduled Task. Mirrors the Linux reconciler's converging
# loop, but the worker runs as a native Windows Service (not a container):
#
#   1. git-pull the deploy-state repo (desired state)
#   2. read the pinned image digest for the worker
#   3. if changed: fetch secrets, install the pinned worker source, (re)install
#      + restart the Windows Service
#   4. health-check (service Running AND fresh heartbeat row)
#   5. on failure: roll back to last-good and re-health-check
#   6. report actual state to GCS for the CI gate
$ErrorActionPreference = "Stop"

$base      = "C:\hanomi"
$stateRepo = "$base\deploy-state"
$svcName   = "HanomiWorker"
$lastGood  = "$base\worker.lastgood"
$bucket    = [Environment]::GetEnvironmentVariable("STATE_BUCKET", "Machine")
$gcsState  = "gs://$bucket/state/worker/actual.json"

function Write-Log($msg) { Write-Host "[reconciler/worker] $msg" }

function Report($healthy, $sha, $err) {
  $obj = [ordered]@{
    service = "worker"; sha = $sha
    healthy = $healthy; error = $err
    ts      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  } | ConvertTo-Json -Compress
  $tmp = Join-Path $env:TEMP "actual.json"
  # -healthy is a [bool]; ConvertTo-Json emits true/false (valid JSON).
  Set-Content -Path $tmp -Value $obj -Encoding ascii
  & gcloud storage cp $tmp $gcsState --quiet
}

function Test-WorkerHealthy {
  # Health = the worker wrote a heartbeat row in the last 60s. The worker runs as
  # a scheduled task; a fresh heartbeat is proof it's actually processing, which
  # is a stronger signal than "the task object exists". Allow time for first run.
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $age = & python "$stateRepo\deploy\windows\heartbeat_age.py"
      if ([int]$age -lt 60) { return $true }
    } catch { }
    Start-Sleep -Seconds 3
  }
  return $false
}

function Deploy-Worker($image) {
  Write-Log "deploying $image"
  # Fetch secrets fresh into the machine env file (read by the worker wrapper).
  & gcloud secrets versions access latest --secret="hanomi-worker-env" |
    Out-File -Encoding ascii "$base\worker.env"
  # install-service.ps1 installs the scheduled task AND starts it.
  & "$stateRepo\deploy\windows\install-service.ps1" -Image $image
}

# 1) sync desired state
try { & git -C $stateRepo pull --quiet --ff-only } catch { Write-Log "git pull failed (cached state)" }
$desiredLine = Select-String -Path "$stateRepo\state\worker\desired.yaml" -Pattern '^image:\s*(.+)$'
$desired = $desiredLine.Matches.Groups[1].Value.Trim()
$current = if (Test-Path $lastGood) { (Get-Content $lastGood).Trim() } else { "" }

if ([string]::IsNullOrEmpty($desired)) { Write-Log "no desired image; nothing to do"; exit 0 }
if ($desired -eq $current) { exit 0 }  # converged

Write-Log "desired=$desired current=$current"

# 3) deploy desired, 4) health-check
Deploy-Worker $desired
if (Test-WorkerHealthy) {
  Set-Content -Path $lastGood -Value $desired
  Report $true $desired ""
  Write-Log "healthy on new version"
  exit 0
}

# 5) rollback to last-good
Write-Log "new version unhealthy; rolling back"
if ($current -ne "") {
  Deploy-Worker $current
  if (Test-WorkerHealthy) {
    Report $false $current "deploy_failed_rolled_back"
    Write-Log "rolled back to last-good and healthy"
    exit 1
  }
}

# 6) degraded
Report $false $desired "degraded_rollback_failed"
Write-Log "DEGRADED: rollback failed"
exit 1
