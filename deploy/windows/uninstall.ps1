#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$StateDir = (Join-Path $env:ProgramData 'intqwq-bridge'),
  [switch]$KeepState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Log([string]$Message) { Write-Host "[Bridge] $Message" }
function Warn([string]$Message) { Write-Warning "[Bridge] $Message" }
function Fail([string]$Message) { throw "[Bridge] $Message" }
function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Has-Property($Object, [string]$Name) {
  return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

if (-not (Test-Administrator)) { Fail 'Run uninstall.ps1 from an elevated PowerShell or Terminal.' }

$ConfigFile = Join-Path $StateDir 'config.json'
$config = $null
if (Test-Path -LiteralPath $ConfigFile) {
  try {
    $config = Get-Content -Raw -LiteralPath $ConfigFile | ConvertFrom-Json
  } catch {
    Warn "Could not parse $ConfigFile; falling back to default paths."
  }
}

$defaultProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ProjectRoot = $defaultProjectRoot
if (Has-Property $config 'root') {
  $candidateRoot = [string]$config.root
  if ($candidateRoot) { $ProjectRoot = $candidateRoot }
}
$CliDir = Join-Path $env:ProgramFiles 'intqwq-bridge'

Log 'Stopping Bridge edge...'
if ((Get-Command docker -ErrorAction SilentlyContinue) -and
    (Test-Path -LiteralPath (Join-Path $ProjectRoot 'compose.yml')) -and
    (Test-Path -LiteralPath (Join-Path $ProjectRoot '.env'))) {
  & docker compose --project-directory $ProjectRoot --env-file (Join-Path $ProjectRoot '.env') down --remove-orphans
  if ($LASTEXITCODE -ne 0) { Warn 'Docker Compose cleanup failed; continuing with local cleanup.' }
}

# Only touch the global cloudflared service when it currently points at Bridge's
# generated config. New installs record whether that service predated Bridge so
# the uninstaller can restore it instead of deleting somebody else's service.
$service = Get-Service -Name cloudflared -ErrorAction SilentlyContinue
$serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared'
$bridgeCloudflaredConfig = Join-Path $StateDir 'cloudflared\config.yml'
if (Has-Property $config 'cloudflaredConfig') {
  $configuredPath = [string]$config.cloudflaredConfig
  if ($configuredPath) { $bridgeCloudflaredConfig = $configuredPath }
}

if ($service -and (Test-Path $serviceKey)) {
  $currentImagePath = [string](Get-ItemProperty -Path $serviceKey -Name ImagePath).ImagePath
  $pointsAtBridge = $currentImagePath.IndexOf($bridgeCloudflaredConfig, [StringComparison]::OrdinalIgnoreCase) -ge 0
  if ($pointsAtBridge) {
    Stop-Service -Name cloudflared -Force -ErrorAction SilentlyContinue
    if (Has-Property $config 'cloudflaredServicePreexisting') {
      if ([bool]$config.cloudflaredServicePreexisting) {
        $previousImagePath = ''
        if (Has-Property $config 'cloudflaredPreviousImagePath') {
          $previousImagePath = [string]$config.cloudflaredPreviousImagePath
        }
        if ($previousImagePath) {
          Set-ItemProperty -Path $serviceKey -Name ImagePath -Value $previousImagePath
          if ((Has-Property $config 'cloudflaredPreviousWasRunning') -and [bool]$config.cloudflaredPreviousWasRunning) {
            Start-Service -Name cloudflared
          }
          Log 'Restored the cloudflared service configuration that existed before Bridge.'
        } else {
          Warn 'cloudflared existed before Bridge, but no previous ImagePath was recorded. It has been left installed and stopped rather than deleted.'
        }
      } else {
        $removed = $false
        $cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
        if ($cloudflared) {
          & $cloudflared.Source service uninstall
          if ($LASTEXITCODE -eq 0) { $removed = $true }
        }
        if (-not $removed) {
          & sc.exe delete cloudflared | Out-Null
          if ($LASTEXITCODE -ne 0) { Warn 'Could not remove the Bridge-created cloudflared Windows service.' }
        }
        Log 'Removed the Bridge-created cloudflared Windows service.'
      }
    } else {
      Warn 'This looks like an older Bridge install without cloudflared ownership metadata. The service has been stopped but not deleted because its previous configuration cannot be restored safely.'
    }
  } else {
    Log 'The cloudflared Windows service is not pointing at Bridge; leaving it untouched.'
  }
}

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$filteredPath = @()
if ($machinePath) {
  $cliNormalized = $CliDir.TrimEnd('\')
  $filteredPath = @($machinePath -split ';' | Where-Object {
    $_ -and -not [string]::Equals($_.TrimEnd('\'), $cliNormalized, [StringComparison]::OrdinalIgnoreCase)
  })
  [Environment]::SetEnvironmentVariable('Path', ($filteredPath -join ';'), 'Machine')
}
$env:Path = (($env:Path -split ';' | Where-Object {
  $_ -and -not [string]::Equals($_.TrimEnd('\'), $CliDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}) -join ';')

if (Test-Path -LiteralPath $CliDir) { Remove-Item -Recurse -Force -LiteralPath $CliDir }
$envFile = Join-Path $ProjectRoot '.env'
if (Test-Path -LiteralPath $envFile) { Remove-Item -Force -LiteralPath $envFile }

if ($KeepState) {
  Log "Preserved Bridge state: $StateDir"
} elseif (Test-Path -LiteralPath $StateDir) {
  Remove-Item -Recurse -Force -LiteralPath $StateDir
  Log "Removed Bridge state: $StateDir"
}

Log 'Bridge local services, CLI and generated runtime configuration are removed.'
Log 'Preserved Docker Desktop, the cloudflared executable, user Cloudflare credentials, remote tunnel and DNS records.'
Log 'If this host will never use the tunnel again, remove the remote tunnel/DNS explicitly from Cloudflare after verifying no other host depends on them.'
