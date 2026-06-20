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
$desired   = ""  # initialized so the top-level catch can always report

function Write-Log($msg) { Write-Host "[reconciler/worker] $msg" }

function Report($healthy, $sha, $err) {
  if ($err) { $err = ($err -replace '\s+', ' ').Trim() }  # single line for clean JSON
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

function Get-Python {
  $c = Get-Command python -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  if (Test-Path "C:\Python312\python.exe") { return "C:\Python312\python.exe" }
  return "python"
}

function Test-WorkerHealthy {
  # Health = the worker wrote a heartbeat row in the last 60s. The worker runs as
  # a scheduled task; a fresh heartbeat is proof it's actually processing, which
  # is a stronger signal than "the task object exists". Allow time for first run.
  $py = Get-Python
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $age = & $py "$stateRepo\deploy\windows\heartbeat_age.py"
      if ([int]$age -lt 60) { return $true }
    } catch { }
    Start-Sleep -Seconds 3
  }
  return $false
}

function Deploy-Worker($image) {
  Write-Log "deploying $image"
  # Fetch secrets fresh into the machine env file. Use [IO.File]::WriteAllText
  # (NOT `| Out-File`, which produced an EMPTY file via the PowerShell pipe on
  # Windows). Write UTF-8 no-BOM so Python reads it cleanly.
  $secret = (& gcloud secrets versions access latest --secret="hanomi-worker-env" 2>$null) -join "`n"
  [IO.File]::WriteAllText("$base\worker.env", $secret, (New-Object Text.UTF8Encoding($false)))
  # install-service.ps1 installs the scheduled task AND starts it.
  & "$stateRepo\deploy\windows\install-service.ps1" -Image $image
}

# Top-level guard: with ErrorActionPreference=Stop, ANY unhandled error would
# exit before we report — leaving actual.json stale forever. Always report the
# exception to GCS so the CI gate (and we) can see what failed.
try {

# 1) sync desired state. Use fetch + reset (NOT `pull --ff-only`, which failed
# with "Cannot fast-forward to multiple branches" on the bootstrap clone).
try {
  & git -C $stateRepo fetch --quiet origin main
  & git -C $stateRepo reset --quiet --hard origin/main
} catch { Write-Log "git sync failed (using cached state)" }
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

# 6) degraded — dump diagnostics to GCS so we can debug Windows without RDP/SSH.
try {
  $diag = @()
  $diag += "=== task info ==="
  $diag += (schtasks /Query /TN HanomiWorker /V /FO LIST 2>&1 | Out-String)
  $diag += "=== worker.env present? ==="
  $diag += (Test-Path "$base\worker.env").ToString()
  $diag += "=== worker-src listing ==="
  $diag += (Get-ChildItem "$base\worker-src" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Out-String)
  $diag += "=== python version ==="
  $diag += (& python --version 2>&1 | Out-String)
  $diag += "=== heartbeat_age ==="
  $diag += (& python "$stateRepo\deploy\windows\heartbeat_age.py" 2>&1 | Out-String)
  $diag += "=== run wrapper manually (10s) ==="
  $job = Start-Job -ScriptBlock { & powershell -NoProfile -ExecutionPolicy Bypass -File "C:\hanomi\run-worker.ps1" 2>&1 }
  Start-Sleep -Seconds 10
  $diag += ($job | Receive-Job 2>&1 | Out-String)
  $job | Stop-Job; $job | Remove-Job
  $dfile = Join-Path $env:TEMP "worker-diag.txt"
  Set-Content -Path $dfile -Value ($diag -join "`n") -Encoding ascii
  & gcloud storage cp $dfile "gs://$bucket/state/worker/diag.txt" --quiet
} catch { Write-Log "diag dump failed: $_" }

Report $false $desired "degraded_rollback_failed"
Write-Log "DEGRADED: rollback failed"
exit 1

} catch {
  # Any unhandled error in the reconcile flow lands here — report it so state is
  # never silently stale, and surface the message to the CI gate.
  $msg = ("reconcile_error: " + $_.Exception.Message) -replace '"', "'"
  try { Report $false "${desired}" $msg } catch { Write-Log "final report failed: $_" }
  Write-Log "RECONCILE ERROR: $($_.Exception.Message)"
  exit 1
}
