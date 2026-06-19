# Installs/updates the worker as a native Windows Service using only built-in
# tools (sc.exe) — no third-party service wrappers needed.
#
# The worker runs the pinned Python source for the given image digest. We record
# the digest for rollback parity even though Windows runs it as a process (the
# Linux services run the same code as a container). The pinned source is synced
# from the artifact bucket under a per-digest prefix that CI populates.
param([Parameter(Mandatory = $true)][string]$Image)
$ErrorActionPreference = "Stop"

$base = "C:\hanomi"
$src  = "$base\worker-src"
$artifactBucket = [Environment]::GetEnvironmentVariable("ARTIFACT_BUCKET", "Machine")

# Derive a filesystem-safe key from the digest (everything after '@' or ':').
$digest = ($Image -split "@")[-1]
$key    = $digest -replace "[:/]", "_"

New-Item -ItemType Directory -Force -Path $src | Out-Null
& gcloud storage rsync -r "gs://$artifactBucket/worker/$key" $src

# Ensure dependencies for the pinned source are present.
if (Test-Path "$src\requirements.txt") {
  & python -m pip install --quiet -r "$src\requirements.txt"
}

$py  = (Get-Command python).Source
$bin = "`"$py`" `"$src\worker.py`""

if (-not (Get-Service -Name "HanomiWorker" -ErrorAction SilentlyContinue)) {
  & sc.exe create HanomiWorker binPath= $bin start= auto | Out-Null
}
& sc.exe config HanomiWorker binPath= $bin | Out-Null

# Windows SCM recovery = self-heal: restart the service on failure.
& sc.exe failure HanomiWorker reset= 60 `
  actions= restart/5000/restart/5000/restart/5000 | Out-Null

Write-Host "worker service installed for $Image"
