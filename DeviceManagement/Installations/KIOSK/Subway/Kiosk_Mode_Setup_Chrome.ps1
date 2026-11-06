# Compatibility launcher for shared Chrome setup.
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]param([switch]$PassThru)
& (Join-Path (Split-Path $PSScriptRoot -Parent) 'Setup-Chrome.ps1') -ClientType 'Subway' @PSBoundParameters
