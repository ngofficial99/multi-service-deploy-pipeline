# One-time bootstrap for the Windows worker VM (invoked by the Terraform
# windows-startup-script). Installs Python + git + gcloud, clones the
# deploy-state repo, sets machine env, and registers the reconciler as a 60s
# Scheduled Task. Idempotent: safe to run on every boot.
#
# NOTE: we deliberately avoid `winget` — it is NOT available to the SYSTEM
# account in the GCE Windows Server startup-script context. We install via
# direct silent installers instead.
param(
  [Parameter(Mandatory = $true)][string]$StateRepoUrl,
  [Parameter(Mandatory = $true)][string]$StateBucket,
  [Parameter(Mandatory = $true)][string]$ArtifactBucket
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = "C:\hanomi"
$dl = "$base\dl"
New-Item -ItemType Directory -Force -Path $base, $dl | Out-Null

function Add-MachinePath($p) {
  $cur = [Environment]::GetEnvironmentVariable("Path", "Machine")
  if ($cur -notlike "*$p*") {
    [Environment]::SetEnvironmentVariable("Path", "$cur;$p", "Machine")
  }
  $env:Path = "$env:Path;$p"
}

# Resilient download: installer downloads over Cloud NAT occasionally drop
# ("connection forcibly closed"); retry with backoff so a transient blip doesn't
# abort the whole bootstrap.
function Download-WithRetry($url, $out) {
  for ($i = 1; $i -le 5; $i++) {
    try {
      Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 120
      if ((Get-Item $out).Length -gt 0) { return }
    } catch {
      Write-Host "download attempt $i failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds ($i * 5)
  }
  throw "failed to download $url after 5 attempts"
}

# --- Python 3.12 (silent, all users) ---
if (-not (Test-Path "C:\Python312\python.exe")) {
  Download-WithRetry "https://www.python.org/ftp/python/3.12.4/python-3.12.4-amd64.exe" "$dl\python.exe"
  Start-Process "$dl\python.exe" -Wait -ArgumentList `
    "/quiet InstallAllUsers=1 PrependPath=1 TargetDir=C:\Python312 Include_launcher=0"
}
Add-MachinePath "C:\Python312"
Add-MachinePath "C:\Python312\Scripts"

# --- Git (silent) ---
if (-not (Test-Path "C:\Program Files\Git\cmd\git.exe")) {
  Download-WithRetry "https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/Git-2.45.2-64-bit.exe" "$dl\git.exe"
  Start-Process "$dl\git.exe" -Wait -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP-"
}
Add-MachinePath "C:\Program Files\Git\cmd"

# --- Google Cloud CLI (silent, all users) ---
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue) -and -not (Test-Path "C:\gcloud\google-cloud-sdk\bin\gcloud.cmd")) {
  Download-WithRetry "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe" "$dl\gcloud.exe"
  Start-Process "$dl\gcloud.exe" -Wait -ArgumentList `
    "/S /allusers /noreporting /nostartmenu /nodesktop /InstallDir=C:\gcloud"
}
Add-MachinePath "C:\gcloud\google-cloud-sdk\bin"

# --- Clone or update the GitOps desired-state repo ---
$git = "C:\Program Files\Git\cmd\git.exe"
if (-not (Test-Path "$base\deploy-state\.git")) {
  & $git clone $StateRepoUrl "$base\deploy-state"
} else {
  & $git -C "$base\deploy-state" pull --ff-only
}

# --- Machine env the reconciler reads ---
[Environment]::SetEnvironmentVariable("STATE_BUCKET", $StateBucket, "Machine")
[Environment]::SetEnvironmentVariable("ARTIFACT_BUCKET", $ArtifactBucket, "Machine")

# --- Register the reconciler to run every 60s as SYSTEM ---
$reconciler = "$base\deploy-state\deploy\windows\reconciler.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$reconciler`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Seconds 60)
# Robust scheduling: don't pile up overlapping runs (a slow reconcile must not
# block the next), and kill any run that hangs past 5 min. Without this, a stuck
# instance blocks all future cycles (the bug we hit: reconciler stopped cycling).
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "HanomiReconcile" -Action $action -Trigger $trigger `
  -Settings $settings -RunLevel Highest -User "SYSTEM" -Force | Out-Null

Write-Host "bootstrap complete"
