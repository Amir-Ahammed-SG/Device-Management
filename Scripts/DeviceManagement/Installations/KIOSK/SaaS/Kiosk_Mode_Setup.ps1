# Compatibility launcher for shared Edge setup.
[CmdletBinding()]param()
& (Join-Path (Split-Path $PSScriptRoot -Parent) 'Setup-Edge.ps1') -ClientType 'SaaS' @PSBoundParameters
