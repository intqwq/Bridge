#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'deploy\windows\install.ps1'
& $installer @args
exit $LASTEXITCODE
