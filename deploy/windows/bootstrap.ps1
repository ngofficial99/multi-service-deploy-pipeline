# One-time bootstrap for the Windows worker VM (invoked by the Terraform
# windows-startup-script). Installs Python + git, clones the deploy-state repo,
# sets machine env, and registers the reconciler as a 60s Scheduled Task.
# Idempotent: safe to run on every boot.
param(
  [Parameter(Mandatory = $true)][string]$StateRepoUrl,
  [Parameter(Mandatory = $true)][string]$StateBucket,
  [Parameter(Mandatory = $true)][string]$ArtifactBucket
)

$ErrorActionPreference = "Stop"
$base = "C:\hanomi"
New-Item -ItemType Directory -Force -Path $base | Out-Null

# Python via winget (present on Windows Server 2022+).
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
  winget install -e --id Python.Python.3.12 --silent `
    --accept-package-agreements --accept-source-agreements
}
# git via winget if missing.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  winget install -e --id Git.Git --silent `
    --accept-package-agreements --accept-source-agreements
}

# Clone or update the GitOps desired-state repo.
if (-not (Test-Path "$base\deploy-state\.git")) {
  git clone $StateRepoUrl "$base\deploy-state"
} else {
  git -C "$base\deploy-state" pull --ff-only
}

# Machine-scoped env the reconciler reads.
[Environment]::SetEnvironmentVariable("STATE_BUCKET", $StateBucket, "Machine")
[Environment]::SetEnvironmentVariable("ARTIFACT_BUCKET", $ArtifactBucket, "Machine")

# Register the reconciler to run every 60s as SYSTEM.
$reconciler = "$base\deploy-state\deploy\windows\reconciler.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$reconciler`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Seconds 60)
Register-ScheduledTask -TaskName "HanomiReconcile" -Action $action -Trigger $trigger `
  -RunLevel Highest -User "SYSTEM" -Force | Out-Null

Write-Host "bootstrap complete"
