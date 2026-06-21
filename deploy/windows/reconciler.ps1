# Windows worker reconciler — data-plane agent for the Windows worker VM.
# Runs every ~60s via a Scheduled Task. The worker runs as a WINDOWS CONTAINER
# (Docker EE), which removes the fragile per-boot Python/source install: the host
# only needs Docker + git + gcloud, and the worker itself ships as an image.
#
#   1. git fetch/reset the deploy-state repo (desired state)
#   2. read the pinned worker image digest
#   3. if changed: fetch secrets -> env file; docker pull; docker run -d the image
#   4. health-check: a fresh worker_heartbeat row (queried inside the container)
#   5. on failure: roll back to last-good image
#   6. report actual state to GCS for the CI gate
$ErrorActionPreference = "Stop"

$base      = "C:\hanomi"
$stateRepo = "$base\deploy-state"
$ctr       = "hanomi-worker"
$envFile   = "$base\worker.env"
$lastGood  = "$base\worker.lastgood"
$bucket    = [Environment]::GetEnvironmentVariable("STATE_BUCKET", "Machine")
$gcsState  = "gs://$bucket/state/worker/actual.json"
$desired   = ""

function Write-Log($m) { Write-Host "[reconciler/worker] $m" }

function Report($healthy, $sha, $err) {
  if ($err) { $err = ($err -replace '\s+', ' ').Trim() }
  $obj = [ordered]@{
    service = "worker"; sha = $sha; healthy = $healthy; error = $err
    ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  } | ConvertTo-Json -Compress
  $tmp = Join-Path $env:TEMP "actual.json"
  Set-Content -Path $tmp -Value $obj -Encoding ascii
  & gcloud storage cp $tmp $gcsState --quiet
}

function Registry-Login($image) {
  # Authenticate Docker to Artifact Registry using the VM's metadata SA token.
  $host_ = ($image -split "/")[0]
  $token = (Invoke-RestMethod -Headers @{ "Metadata-Flavor" = "Google" } `
    -Uri "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token").access_token
  $token | docker login -u oauth2accesstoken --password-stdin "https://$host_" 2>&1 | Out-Null
}

function Deploy-Worker($image) {
  Write-Log "deploying $image"
  # Secrets -> env file (UTF-8 no-BOM; passed to the container via --env-file).
  $secret = (& gcloud secrets versions access latest --secret="hanomi-worker-env" 2>$null) -join "`n"
  [IO.File]::WriteAllText($envFile, $secret, (New-Object Text.UTF8Encoding($false)))
  Registry-Login $image
  docker pull $image
  docker rm -f $ctr 2>$null | Out-Null
  docker run -d --name $ctr --restart unless-stopped --env-file $envFile $image | Out-Null
}

function Test-WorkerHealthy {
  # Health = a worker_heartbeat row written in the last 60s. The container writes
  # it each cycle; we read it from inside the container (it has psycopg + the DSN).
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $age = docker exec $ctr python heartbeat_age.py 2>$null
      if ($age -and [int]$age -lt 60) { return $true }
    } catch { }
    Start-Sleep -Seconds 3
  }
  return $false
}

try {
  try {
    & git -C $stateRepo fetch --quiet origin main
    & git -C $stateRepo reset --quiet --hard origin/main
  } catch { Write-Log "git sync failed (cached state)" }

  $line = Select-String -Path "$stateRepo\state\worker\desired.yaml" -Pattern '^image:\s*(.+)$'
  $desired = $line.Matches.Groups[1].Value.Trim()
  $current = if (Test-Path $lastGood) { (Get-Content $lastGood).Trim() } else { "" }

  if ([string]::IsNullOrEmpty($desired)) { Write-Log "no desired image"; exit 0 }
  if ($desired -eq $current) { exit 0 }  # converged

  Write-Log "desired=$desired current=$current"
  Deploy-Worker $desired
  if (Test-WorkerHealthy) {
    Set-Content -Path $lastGood -Value $desired
    Report $true $desired ""
    Write-Log "healthy on new version"; exit 0
  }

  Write-Log "unhealthy; rolling back"
  if ($current -ne "") {
    Deploy-Worker $current
    if (Test-WorkerHealthy) { Report $false $current "deploy_failed_rolled_back"; exit 1 }
  }
  Report $false $desired "degraded_rollback_failed"
  Write-Log "DEGRADED"; exit 1

} catch {
  $msg = ("reconcile_error: " + $_.Exception.Message) -replace '"', "'"
  try { Report $false "$desired" $msg } catch { Write-Log "final report failed: $_" }
  Write-Log "RECONCILE ERROR: $($_.Exception.Message)"; exit 1
}
