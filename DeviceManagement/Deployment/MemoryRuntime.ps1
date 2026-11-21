# Shared by the generated entry and its isolated, interactive runspaces.
$runtimeBundle=Get-Variable -Name DeviceManagementMemoryBundle -ValueOnly -ErrorAction SilentlyContinue
if($runtimeBundle -and $runtimeBundle.Files.ContainsKey('DeviceManagement/Core/KioskClient.psm1')) {
    $clientModule=New-Module -Name DeviceManagementMemory.KioskClient -ScriptBlock ([scriptblock]::Create($runtimeBundle.Files['DeviceManagement/Core/KioskClient.psm1']))
    Import-Module -ModuleInfo $clientModule -Scope Local -Force -ErrorAction Stop
}
function Invoke-DeviceManagementMemoryScript {
    param (
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][hashtable]$Bundle,
        [Parameter(Mandatory = $true)][string]$RuntimeCode,
        [hashtable]$Parameters = @{}
    )

    $runspace = [RunspaceFactory]::CreateRunspace($Host)
    $pipeline = [PowerShell]::Create()
    try {
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('DeviceManagementMemoryBundle', $Bundle)
        $runspace.SessionStateProxy.SetVariable('DeviceManagementMemoryRuntime', $RuntimeCode)
        foreach ($preference in @('WhatIfPreference', 'ConfirmPreference', 'VerbosePreference')) {
            $runspace.SessionStateProxy.SetVariable($preference, (Get-Variable -Name $preference -ValueOnly))
        }
        $runspace.SessionStateProxy.Path.SetLocation((Get-Location).Path) | Out-Null
        $pipeline.Runspace = $runspace
        [void]$pipeline.AddScript($RuntimeCode).AddStatement().AddScript($Code).AddParameters($Parameters)
        $output = @($pipeline.Invoke())
        [pscustomobject]@{
            Output = $output
            Errors = @($pipeline.Streams.Error)
            State = [string]$pipeline.InvocationStateInfo.State
            Failure = $pipeline.InvocationStateInfo.Reason
        }
    } finally {
        $pipeline.Dispose()
        $runspace.Dispose()
    }
}
