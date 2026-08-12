#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$StateDir = (Join-Path $env:ProgramData 'intqwq-bridge'),
  [ValidateRange(1,65535)][int]$EdgePort = 18080,
  [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$TunnelName = 'bridge',
  [switch]$SkipCloudflare
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Log([string]$Message) { Write-Host "[Bridge] $Message" }
function Fail([string]$Message) { throw "[Bridge] $Message" }
function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Administrator)) { Fail 'Run install.ps1 from an elevated PowerShell or Terminal.' }

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$EnvFile = Join-Path $ProjectRoot '.env'
$ConfigFile = Join-Path $StateDir 'config.json'
$CliDir = Join-Path $env:ProgramFiles 'intqwq-bridge'
$CliScript = Join-Path $CliDir 'bridge.ps1'
$CliWrapper = Join-Path $CliDir 'bridge.cmd'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail 'Docker CLI is missing. Install Docker Desktop 4.34 or newer first.' }
& docker info *> $null
if ($LASTEXITCODE -ne 0) { Fail 'Docker is not reachable. Start Docker Desktop, switch to Linux containers, and retry.' }

New-Item -ItemType Directory -Force -Path $StateDir, (Join-Path $StateDir 'registry'), (Join-Path $StateDir 'nginx'), (Join-Path $StateDir 'nginx\routes'), $CliDir | Out-Null
$composeState = $StateDir.Replace('\','/')
@"
EDGE_PORT=$EdgePort
BRIDGE_STATE_DIR=$composeState
BRIDGE_TUNNEL_NAME=$TunnelName
"@ | Set-Content -Encoding ASCII -LiteralPath $EnvFile

$config = [ordered]@{
  version = 1
  root = $ProjectRoot
  stateDir = $StateDir
  edgePort = $EdgePort
  tunnelName = $TunnelName
  operatorProfile = $env:USERPROFILE
}
$config | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $ConfigFile

Copy-Item -Force -LiteralPath (Join-Path $ProjectRoot 'bin\bridge.ps1') -Destination $CliScript
$wrapper = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$CliScript`" %*`r`n"
Set-Content -Encoding ASCII -LiteralPath $CliWrapper -Value $wrapper

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$parts = @($machinePath -split ';' | Where-Object { $_ })
if ($parts -notcontains $CliDir) {
  [Environment]::SetEnvironmentVariable('Path', (($parts + $CliDir) -join ';'), 'Machine')
  Log "Added $CliDir to the machine PATH. New terminals will see the bridge command."
}
$env:Path = "$CliDir;$env:Path"

Log 'Starting the loopback-only NGINX edge...'
& docker compose --project-directory $ProjectRoot --env-file $EnvFile up -d --wait --wait-timeout 90
if ($LASTEXITCODE -ne 0) {
  Fail 'Bridge edge failed to start. On Docker Desktop 4.34+, enable Settings > Resources > Network > Enable host networking, then Apply & restart.'
}

try {
  Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$EdgePort/healthz" -TimeoutSec 5 | Out-Null
} catch {
  Fail 'The edge container started but localhost health failed. Ensure Docker Desktop host networking is enabled and Enhanced Container Isolation is disabled.'
}

if (-not $SkipCloudflare) {
  $cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
  if (-not $cloudflared) { Fail 'cloudflared is missing. Install the current Cloudflare Tunnel Windows package, then rerun install.ps1 (or use -SkipCloudflare for local-only mode).' }
  & (Join-Path $PSScriptRoot 'configure-cloudflare.ps1') -StateDir $StateDir -EdgePort $EdgePort -TunnelName $TunnelName
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Log "Bridge edge ready at http://127.0.0.1:$EdgePort"
Log "State: $StateDir"
Log 'Run: bridge doctor'
Log 'Run: bridge list'
