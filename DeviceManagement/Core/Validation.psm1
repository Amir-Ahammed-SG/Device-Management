Set-StrictMode -Version 2.0

function Get-ClientDefinition {
    param (
        [Parameter(Mandatory = $true)]$Configuration,
        [Parameter(Mandatory = $true)][string]$ClientId
    )
    @($Configuration.Clients | Where-Object { $_.Id -eq $ClientId }) | Select-Object -First 1
}

function Test-ClientDevice {
    param (
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Device
    )
    return [bool]($Client.Devices -contains $Device)
}

function Get-DeviceOperations {
    param (
        [Parameter(Mandatory = $true)]$OperationsConfiguration,
        [Parameter(Mandatory = $true)][string]$Device,
        [string]$ClientId
    )
    @($OperationsConfiguration.Operations | Where-Object { $_.Devices -contains $Device } | ForEach-Object {
        $copy = [ordered]@{}
        foreach ($key in $_.Keys) { $copy[$key] = $_[$key] }
        $readyForDevice = @($_.ReadyDevices) -contains $Device
        $readyForSelection = $false
        if ($ClientId -and $_.ContainsKey('ReadySelections')) {
            $selectionPrefix = '{0}|{1}|' -f $ClientId, $Device
            $readyForSelection = [bool](@($_.ReadySelections) | Where-Object { $_.StartsWith($selectionPrefix, [StringComparison]::OrdinalIgnoreCase) })
        }
        $copy.ImplementationState = if ($readyForDevice -or $readyForSelection) { 'Ready' } else { 'Pending' }
        [pscustomobject]$copy
    })
}

function Test-OperationSelectionReady {
    param (
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$Mode
    )
    if (@($Operation.ReadyDevices) -contains $Device) { return $true }
    if (-not $Operation.PSObject.Properties['ReadySelections']) { return $false }
    $key = '{0}|{1}|{2}' -f $ClientId, $Device, $Mode
    return [bool](@($Operation.ReadySelections) | Where-Object { $_ -eq $key })
}

function Get-OperationModes {
    param (
        [Parameter(Mandatory = $true)]$OperationsConfiguration,
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$Device
    )
    $operationModes = if ($Operation.Id -eq 'PaymentService') {
        @($OperationsConfiguration.Modes | Where-Object Id -NE 'Final')
    } else {
        @($OperationsConfiguration.Modes | Where-Object { $_.Id -notin @('Uninstall','Final') })
    }
    @($operationModes | ForEach-Object {
        $isInstallMode = ($Operation.Id -eq 'PaymentService' -or $Operation.Id -like '*Installation') -and $_.Id -eq 'Apply'
        $description = if ($Operation.Id -in @('ThoroughCheck', 'PaymentService')) { '' } elseif ($isInstallMode) { 'Install and verify the selected components.' } else { $_.Description }
        [pscustomobject]@{
            Id                  = $_.Id
            DisplayName         = if ($isInstallMode) { 'Install' } else { $_.DisplayName }
            Description         = $description
            ImplementationState = if (Test-OperationSelectionReady $Operation $ClientId $Device $_.Id) { 'Ready' } else { 'Pending' }
        }
    })
}

function Assert-RunSelection {
    param (
        [Parameter(Mandatory = $true)]$ClientsConfiguration,
        [Parameter(Mandatory = $true)]$OperationsConfiguration,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$Mode
    )
    $client = Get-ClientDefinition $ClientsConfiguration $ClientId
    if (-not $client) { throw "Unknown client type: $ClientId" }
    if (-not (Test-ClientDevice $client $Device)) { throw "$Device is unavailable for $ClientId." }
    $operation = @(Get-DeviceOperations $OperationsConfiguration $Device $ClientId | Where-Object { $_.Id -eq $OperationId }) | Select-Object -First 1
    if (-not $operation) { throw "$OperationId is unavailable for $Device." }
    if ($OperationsConfiguration.Modes.Id -notcontains $Mode) { throw "Unknown mode: $Mode" }
    if ($Mode -eq 'Uninstall' -and $operation.Id -ne 'PaymentService') { throw 'Uninstall mode is available only for Payment Service.' }
    if ($Mode -eq 'Final' -and $operation.Id -ne 'ThoroughCheck') { throw 'Thorough Check Report mode is available only for Thorough Check.' }
    return [pscustomobject]@{ Client = $client; Operation = $operation }
}

Export-ModuleMember -Function Get-ClientDefinition, Test-ClientDevice, Get-DeviceOperations, Test-OperationSelectionReady, Get-OperationModes, Assert-RunSelection
