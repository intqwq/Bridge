#requires -Version 5.1
& (Join-Path $PSScriptRoot 'deploy\windows\uninstall.ps1') @args
exit $LASTEXITCODE
