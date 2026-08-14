#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$StateDir = (Join-Path $env:ProgramData 'intqwq-bridge'),
  [switch]$KeepState,
  [switch]$PurgeEnv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Log([string]$Message) { Write-Host "[Bridge uninstall] $Message" }
function Warn([string]$Message) { Write-Warning "[Bridge uninstall] $Message" }
function Fail([string]$Message) { throw "[Bridge uninstall] $Message" }
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

$registryDir = Join-Path $StateDir 'registry'
if (Test-Path -LiteralPath $registryDir) {
  $registered = @(Get-ChildItem -LiteralPath $registryDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
  if ($registered.Count -gt 0) {
    Warn "$($registered.Count) registered service(s) will lose public ingress when Bridge stops. Application services themselves are not removed."
  }
}

Log 'Stopping Bridge edge'
if ((Get-Command docker -ErrorAction SilentlyContinue) -and
    (Test-Path -LiteralPath (Join-Path $ProjectRoot 'compose.yml'))) {
  $composeArgs = @('compose', '--project-directory', $ProjectRoot)
  $envFile = Join-Path $ProjectRoot '.env'
  if (Test-Path -LiteralPath $envFile) { $composeArgs += @('--env-file', $envFile) }
  $composeArgs += @('down', '--remove-orphans')
  & docker @composeArgs
  if ($LASTEXITCODE -ne 0) { Warn 'Docker Compose cleanup failed; continuing with local cleanup.' }
}

# Only modify the global cloudflared service when it currently points at the
# Bridge-generated config. New installs record whether that service predated
# Bridge so uninstall can restore it instead of deleting another app's service.
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
    if ((Has-Property $config 'cloudflaredServicePreexisting') -and [bool]$config.cloudflaredServicePreexisting) {
      $previousImagePath = if (Has-Property $config 'cloudflaredPreviousImagePath') { [string]$config.cloudflaredPreviousImagePath } else { '' }
      if ($previousImagePath) {
        Set-ItemProperty -Path $serviceKey -Name ImagePath -Value $previousImagePath
        if ((Has-Property $config 'cloudflaredPreviousWasRunning') -and [bool]$config.cloudflaredPreviousWasRunning) {
          Start-Service -Name cloudflared
        }
        Log 'Restored the cloudflared service configuration that existed before Bridge.'
      } else {
        Warn 'cloudflared existed before Bridge, but its previous ImagePath was not recorded. It was left installed and stopped rather than deleted.'
      }
    } elseif (Has-Property $config 'cloudflaredServicePreexisting') {
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
    } else {
      Warn 'Older Bridge install detected without cloudflared ownership metadata. The service was stopped but not deleted because its previous configuration cannot be restored safely.'
    }
  } else {
    Log 'The cloudflared Windows service is not pointing at Bridge; leaving it untouched.'
  }
}

Log 'Removing Bridge CLI from PATH'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath) {
  $cliNormalized = $CliDir.TrimEnd('\')
  $filtered = @($machinePath -split ';' | Where-Object {
    $_ -and -not [string]::Equals($_.TrimEnd('\'), $cliNormalized, [StringComparison]::OrdinalIgnoreCase)
  })
  [Environment]::SetEnvironmentVariable('Path', ($filtered -join ';'), 'Machine')
}
$env:Path = (($env:Path -split ';' | Where-Object {
  $_ -and -not [string]::Equals($_.TrimEnd('\'), $CliDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}) -join ';')

if (Test-Path -LiteralPath $CliDir) { Remove-Item -Recurse -Force -LiteralPath $CliDir }

$envFile = Join-Path $ProjectRoot '.env'
if ($PurgeEnv) {
  if (Test-Path -LiteralPath $envFile) { Remove-Item -Force -LiteralPath $envFile }
  Log "Removed $envFile"
} else {
  Log "Preserved $envFile"
}

if ($KeepState) {
  Log "Preserved Bridge state: $StateDir"
} elseif (Test-Path -LiteralPath $StateDir) {
  Remove-Item -Recurse -Force -LiteralPath $StateDir
  Log "Removed Bridge state: $StateDir"
}

Log 'Complete.'
Log 'Docker Desktop, cloudflared executable, user Cloudflare credentials, remote tunnel and DNS records were preserved.'
