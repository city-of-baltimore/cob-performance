param(
  [int]$Port = 3841,
  [string]$HostName = "127.0.0.1",
  [int]$StartupTimeoutSeconds = 45,
  [switch]$NoWait
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RunApp = Join-Path $RepoRoot "scripts\run_app.R"

$RscriptCandidates = @(
  (Join-Path $env:LOCALAPPDATA "Programs\R\R-4.6.0\bin\x64\Rscript.exe"),
  (Get-Command Rscript -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
) | Where-Object { $_ -and (Test-Path $_) }

$RscriptCandidates = @($RscriptCandidates)

if ($RscriptCandidates.Count -lt 1) {
  throw "Could not find Rscript.exe. Install R or add Rscript to PATH."
}

$Rscript = $RscriptCandidates[0]

function Get-PortOwners {
  $owners = @()
  try {
    $owners += Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
      Select-Object -ExpandProperty OwningProcess
  } catch {
    $netstat = & netstat.exe -ano -p tcp
    $pattern = "^\s*TCP\s+\S+:$Port\s+\S+\s+LISTENING\s+(\d+)\s*$"
    foreach ($line in $netstat) {
      if ($line -match $pattern) {
        $owners += [int]$Matches[1]
      }
    }
  }
  $owners | Sort-Object -Unique
}

foreach ($processId in Get-PortOwners) {
  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if ($process -and $process.ProcessName -eq "Rscript") {
    Write-Host "Stopping Shiny process $processId on port $Port..."
    Stop-Process -Id $processId -Force
  } elseif ($process) {
    throw "Port $Port is owned by $($process.ProcessName) ($processId), not Rscript. Stop it manually before restarting."
  }
}

Start-Sleep -Seconds 1

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $Rscript
$psi.WorkingDirectory = $RepoRoot
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$escapedRunApp = '"' + $RunApp.Replace('"', '\"') + '"'
$psi.Arguments = "$escapedRunApp --host $HostName --port $Port"

$process = [System.Diagnostics.Process]::Start($psi)
Write-Host "Started Shiny process $($process.Id) on port $Port."

$url = "http://$HostName`:$Port/"

if ($NoWait) {
  Write-Host "Started without waiting. Check readiness at $url"
  exit 0
}

$deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
$attempt = 0
while ((Get-Date) -lt $deadline) {
  $attempt += 1
  Start-Sleep -Seconds 1
  if ($process.HasExited) {
    throw "Shiny process exited before $url was ready. Exit code: $($process.ExitCode)."
  }
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2
    if ($response.StatusCode -eq 200) {
      Write-Host "Ready: $url after $attempt second(s)."
      exit 0
    }
  } catch {
    Write-Host "Waiting for Shiny on $url..."
  }
}

throw "Shiny process started, but $url did not respond within $StartupTimeoutSeconds seconds."
