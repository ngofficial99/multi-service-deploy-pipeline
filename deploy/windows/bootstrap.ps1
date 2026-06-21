# One-time bootstrap for the Windows worker VM (GCE windows-startup-script).
#
# The worker deploys via a GitHub Actions SELF-HOSTED RUNNER installed here — the
# verified industry-standard push-CD path for a single Windows VM. This script:
#   1. installs Docker EE (Containers feature + Moby static binaries, dockerd as
#      a Windows service so containers survive reboot)
#   2. installs the GitHub Actions runner and registers it as a Windows service,
#      labelled [self-hosted, windows, hanomi-worker]
# Then `merge to main` runs the deploy-worker job ON this VM (docker pull/run).
# No autonomous reconciler, no deploy-state clone. Idempotent across reboots.
param(
  [Parameter(Mandatory = $true)][string]$GithubRepo,   # owner/repo (main repo)
  [Parameter(Mandatory = $true)][string]$RunnerSecret  # Secret Manager id holding a GitHub PAT
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = "C:\hanomi"; $dl = "$base\dl"; $runnerDir = "C:\actions-runner"
New-Item -ItemType Directory -Force -Path $base, $dl | Out-Null

function Add-MachinePath($p) {
  $cur = [Environment]::GetEnvironmentVariable("Path", "Machine")
  if ($cur -notlike "*$p*") { [Environment]::SetEnvironmentVariable("Path", "$cur;$p", "Machine") }
  $env:Path = "$env:Path;$p"
}
function Download-WithRetry($url, $out) {
  for ($i = 1; $i -le 5; $i++) {
    try { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 180
          if ((Get-Item $out).Length -gt 0) { return } } catch { Write-Host "dl attempt ${i}: $($_.Exception.Message)" }
    Start-Sleep -Seconds ($i * 5)
  }
  throw "failed to download $url"
}
function Resolve-Gcloud {
  $c = Get-Command gcloud -ErrorAction SilentlyContinue; if ($c) { return $c.Source }
  foreach ($p in @(
    "C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
    "C:\Program Files\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd")) { if (Test-Path $p) { return $p } }
  return "gcloud"
}

# --- Docker EE (Windows containers) ---
$feat = Get-WindowsFeature -Name Containers
if (-not $feat.Installed) {
  $r = Install-WindowsFeature -Name Containers
  if ($r.RestartNeeded -ne 'No') {
    Write-Host "Containers feature installed; rebooting (startup re-runs next boot)..."
    Restart-Computer -Force; exit 0
  }
}
if (-not (Test-Path "C:\Program Files\docker\dockerd.exe")) {
  Download-WithRetry "https://download.docker.com/win/static/stable/x86_64/docker-26.1.4.zip" "$dl\docker.zip"
  Expand-Archive "$dl\docker.zip" -DestinationPath "C:\Program Files" -Force
  & "C:\Program Files\docker\dockerd.exe" --register-service 2>$null
}
Add-MachinePath "C:\Program Files\docker"
Set-Service docker -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service docker -ErrorAction SilentlyContinue

# --- Google Cloud CLI (to read the runner-registration PAT from Secret Manager) ---
$gcloud = Resolve-Gcloud
if ($gcloud -eq "gcloud" -and -not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
  Download-WithRetry "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe" "$dl\gcloud.exe"
  Start-Process "$dl\gcloud.exe" -Wait -ArgumentList "/S /allusers /noreporting /nostartmenu /nodesktop"
  $gcloud = Resolve-Gcloud
}

# --- GitHub Actions self-hosted runner ---
# Already configured? (the .runner file exists once config.cmd has run) -> done.
if (-not (Test-Path "$runnerDir\.runner")) {
  New-Item -ItemType Directory -Force -Path $runnerDir | Out-Null
  # Latest runner release.
  $rel = Invoke-RestMethod "https://api.github.com/repos/actions/runner/releases/latest"
  $asset = ($rel.assets | Where-Object { $_.name -match 'actions-runner-win-x64-.*\.zip' }).browser_download_url
  Download-WithRetry $asset "$dl\runner.zip"
  Expand-Archive "$dl\runner.zip" -DestinationPath $runnerDir -Force

  # Fetch a short-lived REGISTRATION TOKEN from GitHub using a PAT (repo scope)
  # stored in Secret Manager — the PAT never lands on disk.
  $pat = (& $gcloud secrets versions access latest --secret=$RunnerSecret).Trim()
  $regTok = (Invoke-RestMethod -Method Post `
    -Uri "https://api.github.com/repos/$GithubRepo/actions/runners/registration-token" `
    -Headers @{ Authorization = "Bearer $pat"; "Accept" = "application/vnd.github+json" }).token

  & "$runnerDir\config.cmd" --unattended --replace `
    --url "https://github.com/$GithubRepo" --token $regTok `
    --name "hanomi-worker" --labels "hanomi-worker" `
    --runasservice
}
# Ensure the runner service is running (survives reboots).
Get-Service actions.runner.* -ErrorAction SilentlyContinue | Set-Service -StartupType Automatic
Get-Service actions.runner.* -ErrorAction SilentlyContinue | Start-Service -ErrorAction SilentlyContinue

Write-Host "bootstrap complete (docker + self-hosted runner)"
