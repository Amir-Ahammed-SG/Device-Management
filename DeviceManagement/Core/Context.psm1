Set-StrictMode -Version 2.0

function New-DeviceManagementContext {
    param (
        [Parameter(Mandatory = $true)][string]$ClientType,
        [Parameter(Mandatory = $true)][string]$DeviceType,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][ValidateSet('Audit', 'Apply', 'Final', 'Uninstall')][string]$Mode,
        [string]$ClientLocation,
        [string]$AgentName,
        [ValidateSet('Edge', 'Chrome')][string]$Browser = 'Edge',
        [Parameter(Mandatory = $true)][string]$RootPath,
        $SelectedPackage
    )
    [pscustomobject]@{
        SchemaVersion  = '1.0'
        ClientType     = $ClientType
        ClientLocation = $ClientLocation
        AgentName      = $AgentName
        DeviceType     = $DeviceType
        Operation      = $Operation
        Mode           = $Mode
        Browser        = $Browser
        SelectedPackage = $SelectedPackage
        RunId          = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        RootPath       = [IO.Path]::GetFullPath($RootPath)
        ReportFolder   = 'C:\Thorough Check'
    }
}

Export-ModuleMember -Function New-DeviceManagementContext
