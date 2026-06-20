# Installs/updates the worker to run the pinned Python source.
#
# We run it as a SCHEDULED TASK (at startup, kept alive), NOT an sc.exe service:
# a bare python.exe does not implement the Windows Service Control Protocol, so
# `sc.exe create ... python worker.py` fails to start (error 1053 — the process
# never reports "running" to the SCM). A scheduled task has no such requirement
# and is the right primitive for a long-running polling loop.
param([Parameter(Mandatory = $true)][string]$Image)
$ErrorActionPreference = "Stop"

$base = "C:\hanomi"
$src  = "$base\worker-src"
$artifactBucket = [Environment]::GetEnvironmentVariable("ARTIFACT_BUCKET", "Machine")

# Derive a filesystem-safe key from the digest (everything after '@' or ':').
$digest = ($Image -split "@")[-1]
$key    = $digest -replace "[:/]", "_"

# Sync the pinned worker source. Copy the CONTENTS of the per-digest prefix into
# $src. The dest dir must exist first, and we use the '/*' wildcard so files land
# directly in $src (NOT a nested <key> dir, and NOT rsync, which mangled names).
Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $src | Out-Null
& gcloud storage cp -r "gs://$artifactBucket/worker/$key/*" $src
if (-not (Test-Path "$src\worker.py")) {
  throw "worker source sync failed: $src\worker.py missing after cp"
}

# Install dependencies for the pinned source.
if (Test-Path "$src\requirements.txt") {
  & python -m pip install --quiet -r "$src\requirements.txt"
}

$py = (Get-Command python).Source

# A wrapper script loads the env file (DATABASE_URL etc.) into the process
# environment, then runs the worker. Keeps the task definition simple.
$wrapper = "$base\run-worker.ps1"
@"
Get-Content C:\hanomi\worker.env | ForEach-Object {
  if (`$_ -match '^\s*([^=]+)=(.*)$') {
    [Environment]::SetEnvironmentVariable(`$matches[1].Trim(), `$matches[2].Trim(), 'Process')
  }
}
& '$py' '$src\worker.py'
"@ | Set-Content -Path $wrapper -Encoding ascii

# Register/refresh the worker scheduled task: run at startup as SYSTEM, restart
# if it ever stops. Stop any existing instance first so we pick up new source.
# Wrapped so a not-yet-existing task doesn't throw under ErrorActionPreference=Stop.
try { schtasks.exe /End /TN HanomiWorker 2>$null | Out-Null } catch {}
try { Unregister-ScheduledTask -TaskName HanomiWorker -Confirm:$false -ErrorAction SilentlyContinue } catch {}

$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName HanomiWorker -Action $action -Trigger $trigger `
  -Settings $settings -RunLevel Highest -User "SYSTEM" -Force | Out-Null

# Start it now (don't wait for next boot).
Start-ScheduledTask -TaskName HanomiWorker -ErrorAction SilentlyContinue

Write-Host "worker scheduled task installed for $Image"
