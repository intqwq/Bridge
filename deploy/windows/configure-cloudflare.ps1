#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$StateDir,
  [Parameter(Mandatory=$true)][ValidateRange(1,65535)][int]$EdgePort,
  [Parameter(Mandatory=$true)][string]$TunnelName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Log([string]$Message) { Write-Host "[Bridge] $Message" }
function Fail([string]$Message) { throw "[Bridge] $Message" }

$cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cloudflared) { Fail 'cloudflared is missing.' }
$CloudflaredExe = $cloudflared.Source
$UserCloudflareDir = Join-Path $env:USERPROFILE '.cloudflared'
$UserCert = Join-Path $UserCloudflareDir 'cert.pem'
if (-not (Test-Path -LiteralPath $UserCert)) {
  Log 'Cloudflare authentication is required. A browser authorization flow will open.'
  & $CloudflaredExe tunnel login
  if ($LASTEXITCODE -ne 0) { Fail 'cloudflared tunnel login failed.' }
}
if (-not (Test-Path -LiteralPath $UserCert)) { Fail "Cloudflare account certificate was not created at $UserCert" }

function Get-Tunnels {
  $json = & $CloudflaredExe tunnel list --output json 2>&1
  if ($LASTEXITCODE -ne 0) { Fail "Could not list Cloudflare tunnels:`n$($json -join "`n")" }
  if (-not $json) { return @() }
  $parsed = ($json -join "`n") | ConvertFrom-Json
  return @($parsed)
}

$tunnel = @(Get-Tunnels | Where-Object { $_.name -eq $TunnelName }) | Select-Object -First 1
if (-not $tunnel) {
  Log "Cloudflare tunnel '$TunnelName' does not exist yet; creating it."
  & $CloudflaredExe tunnel create $TunnelName
  if ($LASTEXITCODE -ne 0) { Fail "Could not create Cloudflare tunnel '$TunnelName'." }
  $tunnel = @(Get-Tunnels | Where-Object { $_.name -eq $TunnelName }) | Select-Object -First 1
}
if (-not $tunnel) { Fail "Could not resolve tunnel '$TunnelName' after creation." }
$TunnelId = [string]$tunnel.id
if (-not $TunnelId) { Fail 'Cloudflare returned a tunnel without an id.' }

$CloudflareState = Join-Path $StateDir 'cloudflared'
New-Item -ItemType Directory -Force -Path $CloudflareState | Out-Null
$UserCredentials = Join-Path $UserCloudflareDir "$TunnelId.json"
if (-not (Test-Path -LiteralPath $UserCredentials)) { Fail "Tunnel credentials are missing: $UserCredentials" }
$ServiceCredentials = Join-Path $CloudflareState "$TunnelId.json"
$ServiceCert = Join-Path $CloudflareState 'cert.pem'
Copy-Item -Force -LiteralPath $UserCredentials -Destination $ServiceCredentials
Copy-Item -Force -LiteralPath $UserCert -Destination $ServiceCert

$ConfigPath = Join-Path $CloudflareState 'config.yml'
$yamlCredentials = $ServiceCredentials.Replace('\','/')
$logPath = (Join-Path $CloudflareState 'cloudflared.log').Replace('\','/')
@"
tunnel: $TunnelId
credentials-file: "$yamlCredentials"
ingress:
  - service: http://127.0.0.1:$EdgePort
logfile: "$logPath"
"@ | Set-Content -Encoding ASCII -LiteralPath $ConfigPath

& $CloudflaredExe --config $ConfigPath tunnel ingress validate
if ($LASTEXITCODE -ne 0) { Fail 'cloudflared rejected the generated ingress configuration.' }

$service = Get-Service -Name cloudflared -ErrorAction SilentlyContinue
if (-not $service) {
  Log 'Installing cloudflared as a Windows service.'
  & $CloudflaredExe service install
  if ($LASTEXITCODE -ne 0) { Fail 'cloudflared service install failed.' }
}
$serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared'
if (-not (Test-Path $serviceKey)) { Fail 'Cloudflared Windows service registry entry was not created.' }
$imagePath = "`"$CloudflaredExe`" --config=`"$ConfigPath`" tunnel run"
Set-ItemProperty -Path $serviceKey -Name ImagePath -Value $imagePath

Stop-Service -Name cloudflared -Force -ErrorAction SilentlyContinue
Start-Service -Name cloudflared
$service = Get-Service -Name cloudflared
if ($service.Status -ne 'Running') { Fail 'cloudflared service did not reach Running state.' }

$configFile = Join-Path $StateDir 'config.json'
$config = Get-Content -Raw -LiteralPath $configFile | ConvertFrom-Json
$config | Add-Member -NotePropertyName tunnelId -NotePropertyValue $TunnelId -Force
$config | Add-Member -NotePropertyName cloudflaredConfig -NotePropertyValue $ConfigPath -Force
$config | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $configFile

Log "Cloudflare tunnel ready: $TunnelName ($TunnelId)"
Log 'No application hostname is configured by Bridge itself; applications register hostnames declaratively.'
