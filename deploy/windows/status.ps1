#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $env:ProgramFiles 'intqwq-bridge\bridge.ps1'
if (-not (Test-Path -LiteralPath $bridge)) { throw '[Bridge] Bridge CLI is not installed.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bridge status
exit $LASTEXITCODE
