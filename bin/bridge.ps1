#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "[Bridge] $Message" }
function Log([string]$Message) { Write-Host "[Bridge] $Message" }
function Has-Property($Object, [string]$Name) { return $null -ne $Object.PSObject.Properties[$Name] }
function Write-Utf8NoBom([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

$ConfigFile = if ($env:BRIDGE_CONFIG_FILE) { $env:BRIDGE_CONFIG_FILE } else { Join-Path $env:ProgramData 'intqwq-bridge\config.json' }
if (-not (Test-Path -LiteralPath $ConfigFile)) { Fail "Bridge is not installed: missing $ConfigFile" }
$Config = Get-Content -Raw -LiteralPath $ConfigFile | ConvertFrom-Json
$BridgeRoot = [string]$Config.root
$StateDir = [string]$Config.stateDir
$EdgePort = [int]$Config.edgePort
$TunnelName = [string]$Config.tunnelName
$TunnelId = if (Has-Property $Config 'tunnelId') { [string]$Config.tunnelId } else { '' }
$RegistryDir = Join-Path $StateDir 'registry'
$RoutesDir = Join-Path $StateDir 'nginx\routes'
$EnvFile = Join-Path $BridgeRoot '.env'

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
  if (-not (Test-Administrator)) { Fail 'Run this command from an elevated PowerShell or Terminal.' }
}

function Invoke-Compose([string[]]$Arguments) {
  $all = @('compose', '--project-directory', $BridgeRoot, '--env-file', $EnvFile) + $Arguments
  & docker @all
  if ($LASTEXITCODE -ne 0) { Fail "docker compose failed with code $LASTEXITCODE" }
}

function Require-Runtime {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail 'docker is missing.' }
  if (-not (Test-Path -LiteralPath $EnvFile)) { Fail "Missing $EnvFile" }
  & docker info *> $null
  if ($LASTEXITCODE -ne 0) { Fail 'Docker is not reachable. Start Docker Desktop.' }
  $edge = & docker compose --project-directory $BridgeRoot --env-file $EnvFile ps -q edge
  if ($LASTEXITCODE -ne 0 -or -not $edge) { Fail 'bridge-edge is not running.' }
}

function Test-ServiceId([string]$Value) { return $Value -match '^[a-z0-9][a-z0-9_-]{0,63}$' }
function Test-Hostname([string]$Value) {
  if ($Value -cne $Value.ToLowerInvariant() -or $Value.Length -lt 3 -or $Value.Length -gt 253 -or $Value -notmatch '\.' -or $Value -match '\.\.') { return $false }
  foreach ($label in $Value.Split('.')) {
    if ($label.Length -lt 1 -or $label.Length -gt 63 -or $label -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$') { return $false }
  }
  return $true
}
function Test-Origin([string]$Value) {
  if ($Value -notmatch '^http://127\.0\.0\.1:([0-9]{1,5})$') { return $false }
  $port = [int]$Matches[1]
  return $port -ge 1 -and $port -le 65535
}

function Read-Manifest([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { Fail "Manifest not found: $Path" }
  try { $manifest = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } catch { Fail "Manifest is not valid JSON: $($_.Exception.Message)" }
  if (-not (Has-Property $manifest 'version') -or [int]$manifest.version -ne 1) { Fail 'Manifest does not match Bridge schema version 1.' }
  if (-not (Has-Property $manifest 'service') -or -not ($manifest.service -is [string]) -or -not (Test-ServiceId ([string]$manifest.service))) { Fail 'Manifest has an invalid or missing service id.' }
  if (-not (Has-Property $manifest 'routes') -or -not $manifest.routes -or @($manifest.routes).Count -lt 1) { Fail 'Manifest requires at least one route.' }
  $seen = @{}
  foreach ($route in @($manifest.routes)) {
    if (-not (Has-Property $route 'hostname')) { Fail 'Every route requires hostname.' }
    $host = [string]$route.hostname
    if (-not (Test-Hostname $host)) { Fail "Invalid hostname: $host" }
    if ($seen.ContainsKey($host)) { Fail "Hostname is duplicated inside manifest: $host" }
    $seen[$host] = $true
    $hasOrigin = (Has-Property $route 'origin') -and -not [string]::IsNullOrWhiteSpace([string]$route.origin)
    $hasRedirect = (Has-Property $route 'redirect_to') -and -not [string]::IsNullOrWhiteSpace([string]$route.redirect_to)
    if ($hasOrigin -eq $hasRedirect) { Fail "Route $host must define exactly one of origin or redirect_to." }
    if ($hasOrigin -and -not (Test-Origin ([string]$route.origin))) { Fail "Origin must be host loopback HTTP (http://127.0.0.1:PORT): $($route.origin)" }
    if ($hasRedirect -and -not (Test-Hostname ([string]$route.redirect_to))) { Fail "Invalid redirect target: $($route.redirect_to)" }
    if (Has-Property $route 'health_path') {
      $health = [string]$route.health_path
      if (-not $health.StartsWith('/') -or $health -match '\s') { Fail "Invalid health_path for $host" }
    }
    if (Has-Property $route 'client_max_body_size') {
      if ([string]$route.client_max_body_size -notmatch '^[1-9][0-9]*[kKmMgG]?$') { Fail "Invalid client_max_body_size for $host" }
    }
    if (Has-Property $route 'proxy_read_timeout_seconds') {
      $timeout = 0
      if (-not [int]::TryParse([string]$route.proxy_read_timeout_seconds, [ref]$timeout) -or $timeout -lt 1 -or $timeout -gt 3600) { Fail "Invalid proxy_read_timeout_seconds for $host" }
    }
  }
  return $manifest
}

function Test-RegistryConflicts($Manifest) {
  New-Item -ItemType Directory -Force -Path $RegistryDir | Out-Null
  foreach ($file in Get-ChildItem -LiteralPath $RegistryDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    $existing = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
    if ($existing.service -eq $Manifest.service) { continue }
    $owned = @($existing.routes | ForEach-Object { $_.hostname })
    foreach ($route in @($Manifest.routes)) {
      if ($owned -contains $route.hostname) { Fail "Hostname $($route.hostname) is already owned by service $($existing.service)." }
    }
  }
}

function Test-OriginHealth($Manifest) {
  foreach ($route in @($Manifest.routes)) {
    $hasOrigin = (Has-Property $route 'origin') -and $route.origin
    $hasHealth = (Has-Property $route 'health_path') -and $route.health_path
    if (-not ($hasOrigin -and $hasHealth)) { continue }
    $uri = "$($route.origin)$($route.health_path)"
    try { Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 10 | Out-Null } catch { Fail "Origin health check failed for $($route.hostname): $uri" }
  }
}

function Render-Manifest($Manifest) {
  $chunks = [System.Collections.Generic.List[string]]::new()
  $chunks.Add('# Generated by Bridge. Do not edit directly.')
  $chunks.Add('')
  foreach ($route in @($Manifest.routes)) {
    $host = [string]$route.hostname
    if ((Has-Property $route 'origin') -and $route.origin) {
      $body = if (Has-Property $route 'client_max_body_size') { "    client_max_body_size $($route.client_max_body_size);`n" } else { '' }
      $timeout = if (Has-Property $route 'proxy_read_timeout_seconds') { [int]$route.proxy_read_timeout_seconds } else { 60 }
      $chunks.Add(@"
server {
    listen 127.0.0.1:$EdgePort;
    server_name $host;
    server_tokens off;
    access_log /var/log/nginx/access.log bridge;
$body
    location / {
        proxy_pass $($route.origin);
        proxy_http_version 1.1;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$bridge_client_ip;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$bridge_forwarded_proto;
        proxy_set_header X-Request-ID `$request_id;
        proxy_set_header Upgrade `$http_upgrade;
        proxy_set_header Connection `$bridge_connection_upgrade;
        proxy_connect_timeout 3s;
        proxy_send_timeout 30s;
        proxy_read_timeout ${timeout}s;
    }
}
"@)
    } else {
      $chunks.Add(@"
server {
    listen 127.0.0.1:$EdgePort;
    server_name $host;
    server_tokens off;
    return 308 https://$($route.redirect_to)`$request_uri;
}
"@)
    }
  }
  return ($chunks -join "`n")
}

function Reload-Edge {
  Invoke-Compose @('exec', '-T', 'edge', 'nginx', '-t')
  Invoke-Compose @('exec', '-T', 'edge', 'nginx', '-s', 'reload')
}

function Sync-Dns($Manifest) {
  $cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
  if (-not $cloudflared) { Fail 'cloudflared is missing.' }
  $tunnel = if ($TunnelId) { $TunnelId } else { $TunnelName }
  $failed = $false
  foreach ($route in @($Manifest.routes)) {
    & $cloudflared.Source tunnel route dns --overwrite-dns $tunnel ([string]$route.hostname)
    if ($LASTEXITCODE -ne 0) {
      [Console]::Error.WriteLine("[Bridge] ERROR: DNS route failed for $($route.hostname). Local registration remains active.")
      $failed = $true
    } else { Log "DNS route synced: $($route.hostname) -> tunnel $tunnel" }
  }
  if ($failed) { Fail 'One or more Cloudflare DNS routes failed.' }
}

function Register-Service([string]$ManifestPath, [bool]$SyncDns) {
  Assert-Administrator
  Require-Runtime
  New-Item -ItemType Directory -Force -Path $RegistryDir, $RoutesDir | Out-Null
  $manifest = Read-Manifest $ManifestPath
  Test-RegistryConflicts $manifest
  Test-OriginHealth $manifest
  $service = [string]$manifest.service
  $registryFile = Join-Path $RegistryDir "$service.json"
  $routeFile = Join-Path $RoutesDir "$service.conf"
  $oldRegistry = if (Test-Path $registryFile) { Get-Content -Raw $registryFile } else { $null }
  $oldRoute = if (Test-Path $routeFile) { Get-Content -Raw $routeFile } else { $null }
  Write-Utf8NoBom $registryFile (($manifest | ConvertTo-Json -Depth 16) + "`n")
  Write-Utf8NoBom $routeFile ((Render-Manifest $manifest) + "`n")
  try { Reload-Edge } catch {
    if ($null -ne $oldRegistry) { Write-Utf8NoBom $registryFile $oldRegistry } else { Remove-Item -Force -ErrorAction SilentlyContinue $registryFile }
    if ($null -ne $oldRoute) { Write-Utf8NoBom $routeFile $oldRoute } else { Remove-Item -Force -ErrorAction SilentlyContinue $routeFile }
    try { Reload-Edge } catch {}
    throw
  }
  Log "registered service $service"
  if ($SyncDns) { Sync-Dns $manifest }
}

function Unregister-Service([string]$Service) {
  Assert-Administrator
  Require-Runtime
  if (-not (Test-ServiceId $Service)) { Fail "Invalid service id: $Service" }
  $registryFile = Join-Path $RegistryDir "$Service.json"
  $routeFile = Join-Path $RoutesDir "$Service.conf"
  if (-not (Test-Path $registryFile) -and -not (Test-Path $routeFile)) { Fail "Service is not registered: $Service" }
  $oldRegistry = if (Test-Path $registryFile) { Get-Content -Raw $registryFile } else { $null }
  $oldRoute = if (Test-Path $routeFile) { Get-Content -Raw $routeFile } else { $null }
  Remove-Item -Force -ErrorAction SilentlyContinue $registryFile, $routeFile
  try { Reload-Edge } catch {
    if ($null -ne $oldRegistry) { Write-Utf8NoBom $registryFile $oldRegistry }
    if ($null -ne $oldRoute) { Write-Utf8NoBom $routeFile $oldRoute }
    try { Reload-Edge } catch {}
    throw
  }
  Log "unregistered service $Service; Cloudflare DNS is preserved until removed or reused."
}

function Get-ServiceRows {
  $rows = @()
  if (-not (Test-Path -LiteralPath $RegistryDir)) { return $rows }
  foreach ($file in Get-ChildItem -LiteralPath $RegistryDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    $manifest = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
    foreach ($route in @($manifest.routes)) {
      $target = if ((Has-Property $route 'origin') -and $route.origin) { [string]$route.origin } else { "redirect:https://$($route.redirect_to)" }
      $rows += [pscustomobject]@{ service = [string]$manifest.service; hostname = [string]$route.hostname; target = $target }
    }
  }
  return $rows
}

function Show-Status {
  $edgeRunning = $false
  $edgeHealth = $false
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    & docker info *> $null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $EnvFile)) {
      $id = & docker compose --project-directory $BridgeRoot --env-file $EnvFile ps -q edge
      $edgeRunning = $LASTEXITCODE -eq 0 -and [bool]$id
    }
  }
  if ($edgeRunning) { try { Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$EdgePort/healthz" -TimeoutSec 3 | Out-Null; $edgeHealth = $true } catch {} }
  $cf = Get-Service -Name cloudflared -ErrorAction SilentlyContinue
  $rows = @(Get-ServiceRows)
  [pscustomobject]@{
    platform = 'windows'
    edge_port = $EdgePort
    edge_running = $edgeRunning
    edge_healthy = $edgeHealth
    cloudflared = if ($cf) { [string]$cf.Status } else { 'not-installed' }
    registered_services = @($rows | Select-Object -ExpandProperty service -Unique).Count
    registered_routes = $rows.Count
    state_dir = $StateDir
  }
}

function Doctor {
  $checks = @()
  $isAdmin = Test-Administrator
  $docker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
  $dockerReady = $false
  if ($docker) { & docker info *> $null; $dockerReady = $LASTEXITCODE -eq 0 }
  $cf = [bool](Get-Command cloudflared -ErrorAction SilentlyContinue)
  $status = Show-Status
  $checks += [pscustomobject]@{ check='Administrator'; ok=$isAdmin; detail='Required for register/unregister and installation' }
  $checks += [pscustomobject]@{ check='Docker CLI'; ok=$docker; detail=$(if($docker){'found'}else{'install Docker Desktop'}) }
  $checks += [pscustomobject]@{ check='Docker engine'; ok=$dockerReady; detail=$(if($dockerReady){'reachable'}else{'start Docker Desktop'}) }
  $checks += [pscustomobject]@{ check='cloudflared'; ok=$cf; detail=$(if($cf){'found'}else{'install cloudflared'}) }
  $checks += [pscustomobject]@{ check='State directory'; ok=(Test-Path $StateDir); detail=$StateDir }
  $checks += [pscustomobject]@{ check='Edge container'; ok=$status.edge_running; detail=$(if($status.edge_running){'running'}else{'not running; Docker Desktop 4.34+ requires host networking enabled'}) }
  $checks += [pscustomobject]@{ check='Edge health'; ok=$status.edge_healthy; detail="http://127.0.0.1:$EdgePort/healthz" }
  $checks | Format-Table -AutoSize
  if (@($checks | Where-Object { -not $_.ok }).Count -gt 0) { exit 1 }
}

function Usage {
@'
Bridge - host-local ingress registrar

Usage:
  bridge register <manifest.json> [--no-dns]
  bridge unregister <service-id>
  bridge validate <manifest.json>
  bridge inspect <service-id>
  bridge list [--json]
  bridge status [--json]
  bridge doctor
  bridge help
'@
}

$command = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
$rest = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }
try {
  switch ($command.ToLowerInvariant()) {
    'register' {
      if ($rest.Count -lt 1 -or $rest.Count -gt 2) { Fail (Usage) }
      $sync = $true
      if ($rest.Count -eq 2) { if ($rest[1] -ne '--no-dns') { Fail (Usage) }; $sync = $false }
      Register-Service $rest[0] $sync
    }
    'unregister' { if ($rest.Count -ne 1) { Fail (Usage) }; Unregister-Service $rest[0] }
    'validate' { if ($rest.Count -ne 1) { Fail (Usage) }; $m = Read-Manifest $rest[0]; Test-RegistryConflicts $m; Log "manifest is valid for service $($m.service)" }
    'inspect' {
      if ($rest.Count -ne 1 -or -not (Test-ServiceId $rest[0])) { Fail (Usage) }
      $p = Join-Path $RegistryDir "$($rest[0]).json"; if (-not (Test-Path $p)) { Fail "Service is not registered: $($rest[0])" }; Get-Content -Raw $p
    }
    'list' {
      if ($rest.Count -gt 1 -or ($rest.Count -eq 1 -and $rest[0] -ne '--json')) { Fail (Usage) }
      $rows = @(Get-ServiceRows); if ($rest -contains '--json') { $rows | ConvertTo-Json -Depth 8 } else { $rows | Format-Table -AutoSize }
    }
    'status' {
      if ($rest.Count -gt 1 -or ($rest.Count -eq 1 -and $rest[0] -ne '--json')) { Fail (Usage) }
      $s = Show-Status; if ($rest -contains '--json') { $s | ConvertTo-Json -Depth 8 } else { $s | Format-List }
    }
    'doctor' { if ($rest.Count -ne 0) { Fail (Usage) }; Doctor }
    { $_ -in @('help','-h','--help') } { Usage }
    default { Fail (Usage) }
  }
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
