# Compatibility entry for the current CDN delivery checks.
[CmdletBinding()]
param([string]$ReleaseId='20261022-not-verified-amber-01')
& (Join-Path $PSScriptRoot 'Test-MemoryDelivery.ps1') -ReleaseId $ReleaseId
