# Compatibility launcher. Implementation: KioskThoroughCheck.ps1.
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param (
    [switch]$Apply,
    [switch]$AuditOnly,
    [switch]$FinalReport,
    [ValidateSet('KIOSK', 'POS')][string]$DeviceType = 'KIOSK',
    [string]$ClientLocation,
    [string]$AgentName,
    [string]$RestaurantId,
    [string]$KioskId,
    [string]$KioskHostname,
    [Security.SecureString]$KioskPassword,
    [switch]$ArchitectureRun,
    [string]$ArchitectureResultPath
)
& (Join-Path $PSScriptRoot 'KioskThoroughCheck.ps1') -ClientType 'Subway' @PSBoundParameters
exit $LASTEXITCODE
